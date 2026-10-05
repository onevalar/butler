import Foundation
import XCTest
@testable import Butler

@MainActor
final class AgendaOverviewTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        value.firstWeekday = 1 // The UI deliberately uses Monday, regardless of region settings.
        return value
    }

    private func date(_ day: Int, _ hour: Int = 0) -> Date {
        date(2026, 10, day, hour)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0,
                      calendar: Calendar? = nil) -> Date {
        (calendar ?? self.calendar).date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func reminder(_ text: String, _ day: Int, repeat cadence: TimedReminder.Repeat = .none) -> TimedReminder {
        TimedReminder(text: text, fireDate: date(day, 14), repeats: cadence, timeZoneIdentifier: "Asia/Shanghai")
    }

    private func event(_ id: String, start: Date, end: Date, allDay: Bool = false) -> CalendarEventInfo {
        CalendarEventInfo(id: id, title: id, location: nil, calendarName: "测试日历", start: start, end: end, isAllDay: allDay)
    }

    func testWednesdaySummaryIncludesTodayAndSundayButNotNextMonday() async {
        let tasks = [reminder("今天", 7), reminder("周日", 11), reminder("下周一", 12), reminder("每日", 7, repeat: .daily)]
        let agenda = HomeAgenda.build(lots: [], reminders: tasks, events: [], now: date(7, 9), dayCount: 30, calendar: calendar)
        let week = AgendaOverview.remainingWeek(agenda: agenda, calendar: calendar)
        XCTAssertEqual(week.days.flatMap(\.entries).map(\.title), ["今天", "周日"])
        XCTAssertEqual(week.count, 2)
        XCTAssertEqual(week.routines.map(\.title), ["每日"])
        XCTAssertEqual(AgendaOverview.homeSubtitle(agenda: agenda, calendar: calendar), "本周还有 2 项 · 另有 1 项每日提醒")
    }

    func testSundayAndRoutineOnlyAreNotRollingSevenDaySummaries() async {
        let agenda = HomeAgenda.build(lots: [], reminders: [reminder("每日", 11, repeat: .daily), reminder("周一", 12)],
                                      events: [], now: date(11, 9), calendar: calendar)
        XCTAssertEqual(AgendaOverview.homeSubtitle(agenda: agenda, calendar: calendar), "本周只有每日提醒")
        let nextWeekRoutine = HomeAgenda.build(lots: [], reminders: [reminder("下周才开始", 12, repeat: .daily)],
                                               events: [], now: date(11, 9), calendar: calendar)
        XCTAssertEqual(AgendaOverview.homeSubtitle(agenda: nextWeekRoutine, calendar: calendar), "本周剩余时间暂无安排")
    }

    func testWeekSummaryCrossesYearAndUsesMonday() async {
        XCTAssertEqual(AgendaWindow.week(containing: date(2026, 1, 1), calendar: calendar),
                       DateInterval(start: date(2025, 12, 29), end: date(2026, 1, 5)))
    }

    func testLocateKeepsSurroundingDaysAndClearsOnlyExplicitFilter() async {
        var window = AgendaWindow(today: date(7, 16), calendar: calendar)
        XCTAssertEqual(window.anchor, date(7))
        XCTAssertEqual(window.interval, DateInterval(start: date(2026, 9, 7), end: date(2027, 1, 6)))
        let loaded = window.interval
        window.locate(date(2, 11), calendar: calendar)
        XCTAssertNil(window.selection)
        XCTAssertEqual(window.interval, loaded, "choosing one day locates it, not a one-day filter")
        XCTAssertEqual(window.anchor, date(2))
        window.select(from: date(2), through: date(4), calendar: calendar)
        XCTAssertEqual(window.interval, DateInterval(start: date(2), end: date(5)))
        window.extend(earlier: true, keeping: date(2), calendar: calendar)
        XCTAssertEqual(window.interval, DateInterval(start: date(2), end: date(5)), "explicit ranges do not grow on scroll")
        window.locate(date(3), calendar: calendar)
        XCTAssertNil(window.selection)
        XCTAssertEqual(window.interval, loaded)
        window.locate(date(2028, 2, 29, 18), calendar: calendar)
        XCTAssertEqual(window.anchor, date(2028, 2, 29))
        XCTAssertEqual(window.interval, DateInterval(start: date(2028, 1, 30), end: date(2028, 5, 30)))
    }

    func testDateRangeIsInclusiveAcrossDST() async {
        var la = calendar
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = date(2026, 3, 7, calendar: la), end = date(2026, 3, 9, calendar: la)
        var window = AgendaWindow(today: start, calendar: la)
        window.select(from: start, through: end, calendar: la)
        let range = window.interval
        XCTAssertEqual(AgendaWindow.days(in: range, calendar: la), [start, date(2026, 3, 8, calendar: la), end])
        XCTAssertEqual(range.duration, 71 * 3600)
        window.select(from: end, through: start, calendar: la)
        XCTAssertEqual(window.interval, range, "invalid selections leave the current range unchanged")
    }

    func testContinuousLoadingMovesBothWaysAndKeepsAtMost366Days() async {
        for earlier in [true, false] {
            var window = AgendaWindow(today: date(7), calendar: calendar)
            for _ in 0..<20 {
                let old = window.interval
                let visible = earlier ? old.start : calendar.date(byAdding: .day, value: -1, to: old.end)!
                window.extend(earlier: earlier, keeping: visible, calendar: calendar)
                if earlier {
                    XCTAssertEqual(calendar.dateComponents([.day], from: window.interval.start, to: old.start).day, 30)
                } else {
                    XCTAssertEqual(calendar.dateComponents([.day], from: old.end, to: window.interval.end).day, 30)
                }
                XCTAssertTrue(window.interval.start <= visible && visible < window.interval.end)
                XCTAssertTrue(window.interval.start <= window.anchor && window.anchor < window.interval.end)
                XCTAssertLessThanOrEqual(AgendaWindow.days(in: window.interval, calendar: calendar).count, 366)
            }
        }
    }

    func testRangeValidationIncludesOneDayAnd366ButRejectsReversedAnd367() async {
        let start = date(7)
        XCTAssertTrue(AgendaWindow.validSelection(from: start, through: start, calendar: calendar))
        XCTAssertTrue(AgendaWindow.validSelection(from: start, through: calendar.date(byAdding: .day, value: 365, to: start)!, calendar: calendar))
        XCTAssertFalse(AgendaWindow.validSelection(from: start, through: calendar.date(byAdding: .day, value: 366, to: start)!, calendar: calendar))
        XCTAssertFalse(AgendaWindow.validSelection(from: start, through: date(6), calendar: calendar))
    }

    func testMultidayEventsAppearOnceWithoutMergingSeparateRepeats() async {
        let events = [event("series", start: date(6, 16), end: date(9)),
                      event("series", start: date(10, 10), end: date(10, 11)),
                      event("at-end", start: date(12), end: date(12, 1))]
        let agenda = HomeAgenda.build(lots: [], reminders: [], events: events, now: date(7, 9), calendar: calendar)
        let value = AgendaOverview.remainingWeek(agenda: agenda, calendar: calendar)
        XCTAssertEqual(value.days.map(\.date), [date(7), date(10)])
        XCTAssertEqual(value.count, 2, "one row per occurrence, not one per day or one per series")
        XCTAssertEqual(value.days.first?.entries.first?.calendarSpan?.start, date(6, 16))
        XCTAssertTrue(agenda.entries(on: date(9)).isEmpty, "ending at midnight does not occupy the next day")
        let justThursday = AgendaOverview(agenda: agenda, interval: DateInterval(start: date(8), end: date(9)), calendar: calendar)
        XCTAssertEqual(justThursday.count, 1, "a range starting mid-event still includes it")
    }

    func testSingleDayIncludesItsLastHourAndExcludesFollowingMidnight() async {
        let tasks = [TimedReminder(text: "晚间", fireDate: date(8, 23)), TimedReminder(text: "次日", fireDate: date(9))]
        let agenda = HomeAgenda.build(lots: [], reminders: tasks, events: [], now: date(7, 9), calendar: calendar)
        var window = AgendaWindow(today: date(8), calendar: calendar)
        window.select(from: date(8), through: date(8), calendar: calendar)
        let value = AgendaOverview(agenda: agenda, interval: window.interval, calendar: calendar)
        XCTAssertEqual(value.days.flatMap(\.entries).map(\.title), ["晚间"])
    }

    func testCalendarSlicesKeepDailyViewsAndSameDayOccurrencesDistinct() async {
        let events = [event("全天出行", start: date(7), end: date(9), allDay: true),
                      event("series", start: date(8, 9), end: date(8, 10)),
                      event("series", start: date(8, 15), end: date(8, 16)),
                      event("瞬时", start: date(9), end: date(9))]
        let agenda = HomeAgenda.build(lots: [], reminders: [], events: events, now: date(7), calendar: calendar)
        XCTAssertEqual(agenda.entries(on: date(7)).map(\.title), ["全天出行"])
        let thursday = agenda.entries(on: date(8))
        XCTAssertEqual(thursday.map(\.title), ["全天出行", "series", "series"])
        XCTAssertEqual(Set(thursday.map(\.id)).count, 3, "repeat instances must not share SwiftUI row identity")
        XCTAssertEqual(thursday.map(\.start), [nil, date(8, 9), date(8, 15)])
        XCTAssertEqual(agenda.entries(on: date(9)).map(\.title), ["瞬时"])
        let value = AgendaOverview.remainingWeek(agenda: agenda, calendar: calendar)
        XCTAssertEqual(value.count, 4)
        XCTAssertEqual(value.days.flatMap(\.entries).map(\.title), ["全天出行", "series", "series", "瞬时"])
    }

    func testCompletedRowsStayVisibleButDoNotInflateHomepageCount() async {
        var done = reminder("已完成", 7)
        done.status = .completed
        done.activity = [ReminderActivity(date: date(7, 15), kind: "completed", detail: "完成")]
        let agenda = HomeAgenda.build(lots: [], reminders: [done, reminder("仍待办", 8)], events: [], now: date(7, 16), calendar: calendar)
        let value = AgendaOverview.remainingWeek(agenda: agenda, calendar: calendar)
        XCTAssertEqual(value.count, 1)
        XCTAssertEqual(value.days.flatMap(\.entries).map(\.title), ["已完成", "仍待办"])
        XCTAssertEqual(value.days.first?.entries.first?.isCompleted, true)
    }

    func testDailyStartsAndStopsInsideRangeWithoutRepeatingEveryDayInList() async {
        var daily = reminder("每日提醒", 9, repeat: .daily)
        daily.endDate = date(11, 23)
        let agenda = HomeAgenda.build(lots: [], reminders: [daily], events: [], now: date(7), calendar: calendar)
        let value = AgendaOverview(agenda: agenda, interval: DateInterval(start: date(7), end: date(14)), calendar: calendar)
        XCTAssertEqual(value.routines.count, 1)
        XCTAssertEqual(value.routines.first?.day, date(9))
        XCTAssertEqual(value.count, 0)
        let after = AgendaOverview(agenda: agenda, interval: DateInterval(start: date(12), end: date(14)), calendar: calendar)
        XCTAssertTrue(after.routines.isEmpty)
    }

    func testExplicitRangeBuildsFarFutureAndHistoryWithoutChangingToday() async {
        for year in [2023, 2029] {
            let start = date(year, 12, 28), end = date(year + 1, 1, 4)
            let range = DateInterval(start: start, end: end)
            let task = TimedReminder(text: "范围内提醒", fireDate: date(year + 1, 1, 2, 10))
            let events = [event("跨年日历", start: date(year, 12, 31, 23), end: date(year + 1, 1, 1, 1))]
            let agenda = HomeAgenda.build(lots: [], reminders: [task], events: events, now: date(7), calendar: calendar,
                                          additionalDays: AgendaWindow.days(in: range, calendar: calendar))
            let value = AgendaOverview(agenda: agenda, interval: range, calendar: calendar)
            XCTAssertEqual(value.days.flatMap(\.entries).map(\.title), ["跨年日历", "范围内提醒"])
            XCTAssertEqual(agenda.today, date(7))
            XCTAssertEqual(agenda.days.first, date(7))
        }
    }

    func testFocusedListKeepsPastFutureAndPlacesOngoingEventAtDestinationOnce() async {
        let range = DateInterval(start: date(2), end: date(15))
        let events = [event("旅行", start: date(5, 16), end: date(9)),
                      event("过去", start: date(3, 9), end: date(3, 10)),
                      event("之后", start: date(12, 9), end: date(12, 10))]
        let agenda = HomeAgenda.build(lots: [], reminders: [], events: events, now: date(7), calendar: calendar,
                                     additionalDays: AgendaWindow.days(in: range, calendar: calendar))
        let value = AgendaOverview(agenda: agenda, interval: range, calendar: calendar, focusedDay: date(7))
        XCTAssertEqual(value.days.map(\.date), [date(3), date(7), date(12)])
        XCTAssertEqual(value.days.flatMap(\.entries).map(\.title), ["过去", "旅行", "之后"])
        XCTAssertEqual(value.days[1].entries.first?.calendarSpan, DateInterval(start: date(5, 16), end: date(9)))
        let emptyDay = AgendaOverview(agenda: agenda, interval: range, calendar: calendar, focusedDay: date(10))
        XCTAssertEqual(emptyDay.days.map(\.date), [date(3), date(5), date(10), date(12)])
        XCTAssertTrue(emptyDay.days[2].entries.isEmpty)
    }

    func testFocusedListGroupsDailyRemindersOnlyOnApplicableDates() async {
        var daily = reminder("每日提醒", 9, repeat: .daily)
        daily.endDate = date(11, 23)
        let agenda = HomeAgenda.build(lots: [], reminders: [daily], events: [], now: date(7), calendar: calendar)
        let value = AgendaOverview(agenda: agenda, interval: DateInterval(start: date(7), end: date(14)),
                                   calendar: calendar, focusedDay: date(7))
        XCTAssertEqual(value.days.map(\.date), [date(7), date(9), date(10), date(11)])
        XCTAssertEqual(value.days.map { $0.routines.map(\.title) }, [[], ["每日提醒"], ["每日提醒"], ["每日提醒"]])
        XCTAssertEqual(value.count, 0)
        XCTAssertEqual(value.routines.count, 1, "homepage deduplication is unchanged")
    }
}
