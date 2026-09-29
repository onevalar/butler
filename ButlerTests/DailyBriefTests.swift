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
