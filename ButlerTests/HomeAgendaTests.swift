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

    func testCompactWindowFollowsNowOrTheFirstEvent() {
        let items = [TimelineItem(id: "a", title: "开会", startDate: calendar.date(bySettingHour: 15, minute: 0, second: 0, of: day(2))!,
                                  endDate: calendar.date(bySettingHour: 16, minute: 0, second: 0, of: day(2))!, color: .blue)]
        XCTAssertEqual(CompactTimelineView.window(items: [], day: day(0), visibleHours: 4, now: now, calendar: calendar), 9...12)
        XCTAssertEqual(CompactTimelineView.window(items: items, day: day(2), visibleHours: 4, now: now, calendar: calendar), 15...18)
        let late = calendar.date(bySettingHour: 22, minute: 30, second: 0, of: now)!
        XCTAssertEqual(CompactTimelineView.window(items: [], day: day(0), visibleHours: 4, now: late, calendar: calendar), 20...23)
    }
}
