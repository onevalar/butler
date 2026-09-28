import Foundation
import XCTest
@testable import Butler

@MainActor
final class DailyBriefTests: XCTestCase {
    private let calendar = Calendar.current
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date(timeIntervalSince1970: 1_790_000_000))!
    }
    private func day(_ offset: Int, from now: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    private func lot(_ name: String, quantity: Int = 2, package: Date? = nil, category: String? = nil, now: Date) -> LotFacts {
        let product = CatalogProduct(canonicalName: name, categoryRawValue: category)
        let lot = InventoryLot(productID: product.id, quantity: quantity, unit: "瓶")
        lot.packageExpiryDate = package
        return LotFacts(lot: lot, product: product, now: now, calendar: calendar)
    }

    func testMorningBriefSaysWhatNeedsHandlingWhatIsAheadAndWhatIsDueSoon() {
        let now = at(8, 30)
        let eggs = lot("土鸡蛋", package: day(-3, from: now), now: now)
        let water = lot("七鲜饮用纯净水", quantity: 1, category: "household", now: now)
        let yogurt = lot("红枣酸奶", package: day(3, from: now), now: now)
        let leftovers = TimedReminder(text: "热剩饭", fireDate: at(14), createdAt: now)
        let agenda = HomeAgenda.build(lots: [eggs, water, yogurt], reminders: [leftovers], events: [], now: now)

        let brief = DailyBrief.compose(agenda: agenda, lotCount: 3, reminderCount: 1, usesCalendar: true, now: now)

        XCTAssertEqual(brief.greeting, "早上好")
        XCTAssertFalse(brief.isEvening)
        XCTAssertTrue(brief.text.hasPrefix("有 2 样要处理：土鸡蛋已过期，七鲜饮用纯净水快用完了。"), brief.text)
        XCTAssertTrue(brief.text.contains("今天下午 2 点提醒你热剩饭"), brief.text)
        let weekday = day(3, from: now).relativeDayName(from: day(0, from: now), calendar: calendar)
        XCTAssertTrue(brief.text.contains("\(weekday)红枣酸奶到期"), brief.text)
        XCTAssertEqual(brief.basis, "依据：家里的 3 样东西 · 1 条提醒 · 日历")
    }

    func testEveningBriefKeepsUnfinishedTasksAlongsideTonight() {
        let now = at(20, 30)
        let earlier = TimedReminder(text: "热剩饭", fireDate: at(14), createdAt: now)
        let medicine = TimedReminder(text: "吃药", fireDate: at(21), repeats: .daily, createdAt: now)
        let agenda = HomeAgenda.build(lots: [], reminders: [earlier, medicine], events: [], now: now)

        let brief = DailyBrief.compose(agenda: agenda, lotCount: 0, reminderCount: 2, usesCalendar: false, now: now)

        XCTAssertEqual(brief.greeting, "晚上好")
        XCTAssertTrue(brief.isEvening)
        XCTAssertEqual(brief.text, "还有 1 件任务待完成：热剩饭。今晚还有晚上 9 点提醒你吃药。")
        XCTAssertEqual(brief.basis, "依据：家里的 0 样东西 · 2 条提醒")
    }

    func testBriefSeparatesCompletedFromPendingAndUpcoming() {
        let now = at(10)
        let completed = TimedReminder(text: "已取快递", fireDate: at(12), status: .completed,
                                      activity: [ReminderActivity(date: now, kind: "completed", detail: "提前完成")])
        let pending = TimedReminder(text: "交材料", fireDate: at(9))
        let agenda = HomeAgenda.build(lots: [], reminders: [completed, pending], events: [], now: now)
        let brief = DailyBrief.compose(agenda: agenda, lotCount: 0, reminderCount: 1, usesCalendar: false, now: now)
        XCTAssertEqual(brief.text, "还有 1 件任务待完成：交材料。今天已完成 1 件任务。")
    }

    func testQuietDayStillSaysSomething() {
        let now = at(10)
        let agenda = HomeAgenda.build(lots: [lot("大米", package: day(60, from: now), now: now)], reminders: [], events: [], now: now)
        let brief = DailyBrief.compose(agenda: agenda, lotCount: 1, reminderCount: 0, usesCalendar: false, now: now)
        XCTAssertEqual(brief.text, "今天没有要操心的事，家里的东西都还新鲜。")
        XCTAssertEqual(DailyBrief.compose(agenda: HomeAgenda.build(lots: [], reminders: [], events: [], now: now),
                                          lotCount: 0, reminderCount: 0, usesCalendar: false, now: now).text,
                       "家里还没记东西。买了什么跟我说一句，我来记着到期。")
    }

    func testSpokenTime() {
        XCTAssertEqual(DailyBrief.spokenTime(at(9)), "上午 9 点")
        XCTAssertEqual(DailyBrief.spokenTime(at(12, 15)), "中午 12:15 ")
        XCTAssertEqual(DailyBrief.spokenTime(at(21)), "晚上 9 点")
    }

    func testDiaryIsWrittenFromWhatWasSavedEachDay() {
        let today = at(10)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let turns = [
            ChatTurn(question: "买了两瓶酸奶", answer: "好", receipts: ["✓ 新增 红枣酸奶 ×2 瓶"], date: yesterday),
            ChatTurn(question: "饮用水放卫生间", answer: "记住了", receipts: ["✓ 记住：饮用水位置", "✓ 七鲜饮用纯净水 放到 卫生间"], date: today),
            ChatTurn(question: "下午两点提醒我热饭", answer: "好", receipts: ["✓ 提醒：热剩饭", "✗ 没保存：网络错误"], date: today),
            ChatTurn(question: "冰箱里有什么", answer: "有酸奶", date: today),
        ]

        let diary = DiaryDay.build(from: turns)

        XCTAssertEqual(diary.map(\.day), [calendar.startOfDay(for: today), calendar.startOfDay(for: yesterday)])
        XCTAssertEqual(diary[0].headline, "改了 1 处，设了 1 个提醒，记住了 1 个习惯")
        XCTAssertEqual(diary[0].lines, ["记住：饮用水位置", "七鲜饮用纯净水 放到 卫生间", "提醒：热剩饭"])
        XCTAssertEqual(diary[0].conversations, 3)
        XCTAssertEqual(diary[1].headline, "记了 1 样东西")
        XCTAssertEqual(DiaryDay.headline(for: [], conversations: 2), "聊了 2 次")
    }
}
