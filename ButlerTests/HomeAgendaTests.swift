import Foundation
import XCTest
@testable import Butler

@MainActor
final class HomeAgendaTests: XCTestCase {
    private let calendar = Calendar.current
    private var now: Date { calendar.date(bySettingHour: 9, minute: 41, second: 0, of: Date(timeIntervalSince1970: 1_790_000_000))! }
    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))! }

    private func lot(_ name: String, quantity: Int = 2, package: Date? = nil, category: String? = nil, place: String? = nil) -> LotFacts {
        let product = CatalogProduct(canonicalName: name, categoryRawValue: category)
        let lot = InventoryLot(productID: product.id, quantity: quantity, unit: "瓶")
        lot.packageExpiryDate = package
        lot.storageLocation = place
        return LotFacts(lot: lot, product: product, now: now, calendar: calendar)
    }

    func testExpiredAndLowStockNeedAttentionWhileThisWeeksExpiryIsOnItsDay() {
        let expired = lot("简爱原味酸奶", package: day(-5), place: "冷藏")
        let soon = lot("红枣酸奶", package: day(3))
        let later = lot("大米", package: day(40))
        let water = lot("七鲜饮用纯净水", quantity: 1, category: "household", place: "卫生间")
        let undated = lot("面包")
        let agenda = HomeAgenda.build(lots: [expired, soon, later, water, undated], reminders: [], events: [], now: now)

        XCTAssertEqual(agenda.needsAttention.map(\.title), ["简爱原味酸奶", "七鲜饮用纯净水"])
        XCTAssertEqual(agenda.needsAttention.last?.subtitle, "只剩 1 瓶 · 卫生间")
        XCTAssertEqual(agenda.missingInfoCount, 1)
        XCTAssertEqual(agenda.entries(on: day(3)).map(\.title), ["红枣酸奶到期"])
        XCTAssertEqual(agenda.entries(on: day(3)).first?.kind, .expiring)
        XCTAssertTrue(agenda.days.allSatisfy { !agenda.entries(on: $0).contains { $0.title.hasPrefix("大米") } })
        XCTAssertEqual(agenda.dots(on: day(0)), [.expired, .lowStock])
        XCTAssertEqual(agenda.dots(on: day(3)), [.expiring])
    }

    func testRemindersLandOnTheirDaysAndDailyOnesAreShownOnce() {
        let today11 = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: now)!
        let evening = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: now)!
        let once = TimedReminder(text: "热剩饭", fireDate: today11, createdAt: now)
        let daily = TimedReminder(text: "吃药", fireDate: evening, repeats: .daily, createdAt: now)
        let weekly = TimedReminder(text: "买菜", fireDate: calendar.date(byAdding: .day, value: 2, to: evening)!, repeats: .weekly, createdAt: now)
        let agenda = HomeAgenda.build(lots: [], reminders: [once, daily, weekly], events: [], now: now)

        XCTAssertEqual(agenda.entries(on: day(0)).map(\.title), ["热剩饭", "吃药"], "sorted by time")
        XCTAssertEqual(agenda.entries(on: day(1)).map(\.title), ["吃药"])
        XCTAssertEqual(agenda.entries(on: day(2)).map(\.title), ["吃药", "买菜"])
        XCTAssertEqual(agenda.dots(on: day(1)), [], "a daily routine doesn't dot every day")
        XCTAssertEqual(agenda.dots(on: day(2)), [.reminder])
        let upcoming = agenda.upcoming(after: day(0))
        XCTAssertEqual(upcoming.filter { $0.title == "吃药" }.count, 0, "already on today's timeline")
        XCTAssertEqual(upcoming.map(\.title), ["买菜"])
    }

    func testCalendarEventsBecomeTimedOrAllDayEntries() {
        let start = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: day(4))!
        let meeting = CalendarEventInfo(id: "m", title: "产品评审会", location: "会议室 A", calendarName: "工作",
                                        start: start, end: start.addingTimeInterval(3600), isAllDay: false)
        let holiday = CalendarEventInfo(id: "h", title: "国庆", location: nil, calendarName: "节假日",
                                        start: day(4), end: day(5), isAllDay: true)
        let agenda = HomeAgenda.build(lots: [], reminders: [], events: [meeting, holiday], now: now)
        let entries = agenda.entries(on: day(4))
        XCTAssertEqual(entries.map(\.title), ["国庆", "产品评审会"], "all-day first")
        XCTAssertEqual(entries.last?.subtitle, "工作 · 会议室 A")
        XCTAssertEqual(entries.last?.start, start)
        XCTAssertTrue(agenda.entries(on: day(5)).isEmpty, "an all-day event ends at midnight")
    }

    func testPastDueTaskSurvivesAndCompletionPersistsHistory() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ReminderStore(file: file, schedules: false)
        let due = now.addingTimeInterval(-3600)
        let task = TimedReminder(text: "取快递", fireDate: due, createdAt: day(-1))
        try store.add(task)
        let agenda = HomeAgenda.build(lots: [], reminders: store.reminders, events: [], now: now)
        XCTAssertEqual(agenda.entries(on: day(0)).first?.start, due)
        XCTAssertEqual(agenda.pending(on: day(0), at: now).map(\.title), ["取快递"])
        XCTAssertTrue(ReminderSchedule.preview(task, now: now).isEmpty, "No new notification is invented")
        let candidates = BriefCandidates.make(facts: [], agenda: agenda, now: now)
        XCTAssertEqual(candidates.map(\.kind), [.dueTask])
        XCTAssertEqual(candidates.first?.target, .task(task.id))
        try store.complete(task.id)
        let reloaded = ReminderStore(file: file, schedules: false)
        XCTAssertTrue(reloaded.active.isEmpty)
        let saved = try XCTUnwrap(reloaded.reminder(id: task.id))
        XCTAssertEqual(saved.status, .completed)
        let finished = try XCTUnwrap(saved.activity.last?.date)
        let history = HomeAgenda.build(lots: [], reminders: reloaded.reminders, events: [], now: finished)
        XCTAssertEqual(history.completed(on: calendar.startOfDay(for: finished)).map(\.target), [.reminder(task.id)])
        XCTAssertTrue(history.pending(on: calendar.startOfDay(for: finished), at: finished).isEmpty)
    }

    func testUnfinishedTaskCarriesToNextDayButInactiveTasksDoNot() {
        let original = TimedReminder(text: "昨天未完成", fireDate: day(-1).addingTimeInterval(3600))
        for status in [TimedReminder.Status.active, .paused, .completed, .cancelled] {
            var task = original
            task.status = status
            let agenda = HomeAgenda.build(lots: [], reminders: [task], events: [], now: now)
            XCTAssertEqual(agenda.pending(on: day(0), at: now).count, status == .active ? 1 : 0)
            XCTAssertTrue(agenda.entries(on: day(1)).isEmpty)
        }
    }

    func testExhaustedPhasesStayVisibleAndRepeatedAlertsOnlyMakeOnePendingTask() {
        var task = TimedReminder(text: "交材料", fireDate: day(-1))
        task.phases = [ReminderPhase(startDate: day(-1), intervalMinutes: 5, maxOccurrences: 3)]
        let carried = HomeAgenda.build(lots: [], reminders: [task], events: [], now: now)
        XCTAssertEqual(carried.pending(on: day(0), at: now).count, 1)
        task.fireDate = now.addingTimeInterval(-900)
        task.phases = [ReminderPhase(startDate: task.fireDate, intervalMinutes: 5, maxOccurrences: 6)]
        let today = HomeAgenda.build(lots: [], reminders: [task], events: [], now: now)
        XCTAssertEqual(today.entries(on: day(0)).count, 6)
        XCTAssertEqual(today.pending(on: day(0), at: now).count, 1)
    }

    func testCompletedTaskKeepsOriginalTimeAndTimelineState() throws {
        let due = now.addingTimeInterval(-3600)
        let task = TimedReminder(text: "取快递", fireDate: due, status: .completed,
                                 activity: [ReminderActivity(date: now, kind: "completed", detail: "已完成")])
        let agenda = HomeAgenda.build(lots: [], reminders: [task], events: [], now: now)
        let entry = try XCTUnwrap(agenda.entries(on: day(0)).first)
        XCTAssertEqual(entry.start, due)
        XCTAssertTrue(entry.isCompleted)
        XCTAssertTrue(entry.timelineItem.isCompleted)
        XCTAssertEqual(entry.target, .reminder(task.id))
        XCTAssertTrue(agenda.pending(on: day(0), at: now).isEmpty)
        XCTAssertTrue(agenda.upcoming(after: day(0)).isEmpty)
    }

    func testCrossDayCompletionRetainsPlannedAndFinishedDays() {
        let task = TimedReminder(text: "交材料", fireDate: day(-1).addingTimeInterval(3600), status: .completed,
                                 activity: [ReminderActivity(date: now, kind: "completed", detail: "已完成")])
        let agenda = HomeAgenda.build(lots: [], reminders: [task], events: [], now: now)
        XCTAssertEqual(agenda.completed(on: day(-1)).first?.start, task.fireDate)
        XCTAssertEqual(agenda.completed(on: day(0)).first?.start, now)
        XCTAssertTrue(agenda.entries(on: day(1)).isEmpty)
    }

    func testEarlyCompletionDoesNotLeaveFuturePendingEntry() {
        let task = TimedReminder(text: "提前完成", fireDate: day(2), status: .completed,
                                 activity: [ReminderActivity(date: now, kind: "completed", detail: "已完成")])
        let agenda = HomeAgenda.build(lots: [], reminders: [task], events: [], now: now)
        XCTAssertEqual(agenda.completed(on: day(0)).count, 1)
        XCTAssertTrue(agenda.entries(on: day(2)).isEmpty)
        XCTAssertTrue(agenda.upcoming(after: day(0)).isEmpty)
    }

    func testCompletedRepeatingAndPhasedTasksHaveOneCompletionRecord() {
        for phased in [false, true] {
            var task = TimedReminder(text: "定期提醒", fireDate: day(-2), repeats: .daily, status: .completed,
                                     activity: [ReminderActivity(date: now, kind: "autoCompleted", detail: "自动完成")])
            if phased { task.phases = [ReminderPhase(startDate: day(-2), intervalMinutes: 5, maxOccurrences: 10)] }
            let agenda = HomeAgenda.build(lots: [], reminders: [task], events: [], now: now)
            XCTAssertEqual(agenda.completed(on: day(0)).count, 1)
            XCTAssertEqual(agenda.completed(on: day(0)).first?.start, now)
            XCTAssertTrue(agenda.entries(on: day(-2)).isEmpty)
            XCTAssertTrue(agenda.upcoming(after: day(0)).isEmpty)
        }
    }

    func testBrowsingPastAndFarFutureDoesNotTurnThoseDaysIntoTodayOrUpcoming() {
        let past = calendar.date(byAdding: .year, value: -2, to: day(0))!
        let future = calendar.date(byAdding: .year, value: 3, to: day(0))!
        let old = TimedReminder(text: "旧任务", fireDate: past.addingTimeInterval(3600), createdAt: past)
        let later = TimedReminder(text: "远期任务", fireDate: future.addingTimeInterval(3600))
        let event = CalendarEventInfo(id: "old", title: "历史会议", location: nil, calendarName: "日历",
                                      start: past.addingTimeInterval(7200), end: past.addingTimeInterval(10800), isAllDay: false)
        let extra = HomeAgenda.browsingDays(around: past) + HomeAgenda.browsingDays(around: future)
        let agenda = HomeAgenda.build(lots: [], reminders: [old, later], events: [event], now: now, additionalDays: extra)
        XCTAssertEqual(agenda.today, day(0))
        XCTAssertEqual(agenda.entries(on: past).map(\.title), ["旧任务", "历史会议"])
        XCTAssertEqual(agenda.entries(on: future).map(\.title), ["远期任务"])
        XCTAssertEqual(agenda.pending(on: day(0), at: now).map(\.title), ["旧任务"])
        XCTAssertTrue(agenda.upcoming(after: day(0)).isEmpty)
        XCTAssertLessThanOrEqual(extra.count, 90, "jumping years away only expands two month windows")
    }

    func testCompactWindowFollowsNowOrTheFirstEvent() {
        let items = [TimelineItem(id: "a", title: "开会", startDate: calendar.date(bySettingHour: 15, minute: 0, second: 0, of: day(2))!,
                                  endDate: calendar.date(bySettingHour: 16, minute: 0, second: 0, of: day(2))!, color: .blue)]
        XCTAssertEqual(CompactTimelineView.window(items: [], day: day(0), visibleHours: 4, now: now, calendar: calendar), 9...12)
        XCTAssertEqual(CompactTimelineView.window(items: items, day: day(2), visibleHours: 4, now: now, calendar: calendar), 15...18)
        let late = calendar.date(bySettingHour: 22, minute: 30, second: 0, of: now)!
        XCTAssertEqual(CompactTimelineView.window(items: [], day: day(0), visibleHours: 4, now: late, calendar: calendar), 20...23)
    }
}
