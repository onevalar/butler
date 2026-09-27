import Foundation
import XCTest
@testable import Butler

final class LocalReminderParserTests: XCTestCase {
    private let calendar = Calendar.current
    private func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        let base = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date(timeIntervalSince1970: 1_790_000_000))!
        return calendar.date(byAdding: .day, value: dayOffset, to: base)!
    }

    func testBareClockTimeMeansTheNearestOneStillAhead() {
        let now = at(19, 16)
        let seven18 = LocalReminderParser.parse("七点 18 的时候提醒我一下", now: now)
        XCTAssertEqual(seven18?.fireDate, at(19, 18))
        XCTAssertEqual(seven18?.text, "到时间了")
        XCTAssertEqual(LocalReminderParser.parse("帮我定一个 7:00提醒我的一个通知", now: at(18, 55))?.fireDate, at(19, 0))
        XCTAssertEqual(LocalReminderParser.parse("7点提醒我", now: at(20, 0))?.fireDate, at(7, 0, dayOffset: 1))
        XCTAssertEqual(LocalReminderParser.parse("11点提醒我热剩饭", now: at(9, 23))?.fireDate, at(11, 0))
        XCTAssertEqual(LocalReminderParser.parse("11点提醒我热剩饭", now: at(9, 23))?.text, "热剩饭")
    }

    func testSaidPeriodsAndDaysAreFollowed() {
        let now = at(9, 0)
        XCTAssertEqual(LocalReminderParser.parse("晚上9点提醒我吃药", now: now)?.fireDate, at(21, 0))
        XCTAssertEqual(LocalReminderParser.parse("晚上9点提醒我吃药", now: now)?.text, "吃药")
        XCTAssertEqual(LocalReminderParser.parse("明天早上8点半提醒我买菜", now: now)?.fireDate, at(8, 30, dayOffset: 1))
        XCTAssertEqual(LocalReminderParser.parse("明天早上8点半提醒我买菜", now: now)?.text, "买菜")
        XCTAssertEqual(LocalReminderParser.parse("下午三点一刻提醒我开会", now: now)?.fireDate, at(15, 15))
        let daily = LocalReminderParser.parse("每天晚上九点提醒我吃药", now: now)
        XCTAssertEqual(daily?.repeats, .daily)
        XCTAssertEqual(daily?.fireDate, at(21, 0))
    }

    func testRelativeTimesAndThingsThatAreNotReminders() {
        let now = at(12, 0)
        XCTAssertEqual(LocalReminderParser.parse("20分钟后提醒我关火", now: now)?.fireDate, now.addingTimeInterval(20 * 60))
        XCTAssertEqual(LocalReminderParser.parse("20分钟后提醒我关火", now: now)?.text, "关火")
        XCTAssertEqual(LocalReminderParser.parse("半小时后提醒我", now: now)?.fireDate, now.addingTimeInterval(30 * 60))
        XCTAssertNil(LocalReminderParser.parse("冰箱里还有什么", now: now))
        XCTAssertNil(LocalReminderParser.parse("提醒我一下", now: now), "no time given")
    }

    func testChineseNumbers() {
        XCTAssertEqual(LocalReminderParser.normalizeNumbers("七点十八"), "7点18")
        XCTAssertEqual(LocalReminderParser.normalizeNumbers("十点半"), "10点半")
        XCTAssertEqual(LocalReminderParser.normalizeNumbers("二十一点"), "21点")
        XCTAssertEqual(LocalReminderParser.normalizeNumbers("周一两点"), "周一2点")
    }
}
