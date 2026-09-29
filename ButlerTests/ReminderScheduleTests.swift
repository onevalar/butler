import Foundation
import XCTest
@testable import Butler

@MainActor
final class ReminderScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ day: Int, hour: Int = 9, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func store() -> ReminderStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("reminder-test-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return ReminderStore(file: file, schedules: false)
    }

    func testLegacyRecordsDecodeWithoutLosingIdentityOrRepeat() throws {
        let original = TimedReminder(text: "买菜", fireDate: date(28), repeats: .weekly)
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["status", "revision", "timeZoneIdentifier", "activity", "phases", "endDate", "autoCompleteAt"] {
            object.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(TimedReminder.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.fireDate, original.fireDate)
        XCTAssertEqual(decoded.repeats, .weekly)
        XCTAssertEqual(decoded.status, .active)
        XCTAssertEqual(decoded.revision, 1)
        XCTAssertEqual(decoded.activity, [])
    }

    func testDailyPhaseThenLastDayBurstMatchesTheWholePlan() throws {
        let reminder = TimedReminder(text: "提交材料", fireDate: date(28), phases: [
            ReminderPhase(startDate: date(28), endDate: date(29), repeats: .daily),
            ReminderPhase(startDate: date(30), intervalMinutes: 5, maxOccurrences: 4)
        ], timeZoneIdentifier: "Asia/Shanghai")
        try ReminderSchedule.validate(reminder)
        XCTAssertEqual(ReminderSchedule.preview(reminder, now: date(27), limit: 10), [
            date(28), date(29), date(30), date(30, minute: 5), date(30, minute: 10), date(30, minute: 15)
        ])
    }

    func testOccurrenceLimitCountsEarlierFiringsAndOverlappingPhasesAreDeduplicated() {
        let reminder = TimedReminder(text: "取快递", fireDate: date(28), phases: [
            ReminderPhase(startDate: date(28), intervalMinutes: 5, maxOccurrences: 3),
            ReminderPhase(startDate: date(28, minute: 10))
        ])
        XCTAssertEqual(ReminderSchedule.preview(reminder, now: date(28, minute: 5), limit: 20), [date(28, minute: 10)])
        XCTAssertTrue(ReminderSchedule.preview(reminder, now: date(28, minute: 10)).isEmpty)
    }

    func testFutureStartIsNotLostByNativeRepeatingTriggerOrAgenda() {
        let reminder = TimedReminder(text: "后天开始", fireDate: date(30), repeats: .daily, createdAt: date(28),
                                     timeZoneIdentifier: "Asia/Shanghai")
        XCTAssertFalse(ReminderSchedule.canUseNativeRepeat(reminder, now: date(28)))
        XCTAssertTrue(ReminderSchedule.canUseNativeRepeat(reminder, now: date(29, hour: 12)))
        XCTAssertEqual(ReminderSchedule.preview(reminder, now: date(28), limit: 1), [date(30)])
        XCTAssertNil(HomeAgenda.occurrence(of: reminder, on: date(29), calendar: calendar))
    }

    func testSingleUnboundedDailyPhaseCanKeepRepeatingUntilCompletion() {
        var reminder = TimedReminder(text: "每天提醒直到完成", fireDate: date(28), phases: [
            ReminderPhase(startDate: date(28), repeats: .daily)
        ], timeZoneIdentifier: "Asia/Shanghai")
        XCTAssertTrue(ReminderSchedule.canUseNativeRepeat(reminder, now: date(28, hour: 8)))
        reminder.phases?[0].maxOccurrences = 10
        XCTAssertFalse(ReminderSchedule.canUseNativeRepeat(reminder, now: date(28, hour: 8)))
        reminder.phases?[0].maxOccurrences = nil
        reminder.status = .completed
        XCTAssertFalse(ReminderSchedule.canUseNativeRepeat(reminder, now: date(28, hour: 8)))
    }

    func testUnreadableOrCorruptFileCannotBeOverwrittenOnInitialLoadOrReload() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("reminder-corrupt-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let corrupt = Data("not a reminder archive".utf8)
        try corrupt.write(to: file)
        let broken = ReminderStore(file: file, schedules: false)
        let task = TimedReminder(text: "不要覆盖旧记录", fireDate: .now.addingTimeInterval(3600))
        XCTAssertThrowsError(try broken.add(task))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)

        try JSONEncoder().encode([task]).write(to: file)
        let loaded = ReminderStore(file: file, schedules: false)
        try corrupt.write(to: file)
        loaded.reload()
        XCTAssertNotNil(loaded.reminder(id: task.id), "retain the last good in-memory snapshot")
        XCTAssertThrowsError(try loaded.complete(task.id))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        XCTAssertNotNil(loaded.scheduleWarning)
    }

    func testRestoringSnapshotWithoutReminderFileClearsOldTaskMemory() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("reminder-missing-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ReminderStore(file: file, schedules: false)
        try store.add(TimedReminder(text: "后来创建的", fireDate: .now.addingTimeInterval(3600)))
        try FileManager.default.removeItem(at: file)
        store.reload()
        XCTAssertTrue(store.reminders.isEmpty)
        XCTAssertNoThrow(try store.add(TimedReminder(text: "恢复后新建", fireDate: .now.addingTimeInterval(3600))))
    }

    func testCompleteCancelsEveryPhaseAndRetainsHistoryAcrossReload() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("reminder-history-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ReminderStore(file: file, schedules: false)
        let reminder = TimedReminder(text: "交材料", fireDate: .now.addingTimeInterval(3600), repeats: .daily)
        try store.add(reminder)
        try store.complete(reminder.id)
        try store.complete(reminder.id)
        let saved = try XCTUnwrap(ReminderStore(file: file, schedules: false).reminder(id: reminder.id))
        XCTAssertEqual(saved.status, .completed)
        XCTAssertEqual(saved.revision, 2)
        XCTAssertEqual(saved.activity.map(\.kind), ["created", "completed"])
        XCTAssertTrue(ReminderSchedule.preview(saved).isEmpty)
    }

    func testPauseResumeAndCancelPreserveTaskIdentityAndDoNotDeletePastReminders() throws {
        let store = store()
        let past = TimedReminder(text: "过去的提醒", fireDate: .now.addingTimeInterval(-3600))
        let future = TimedReminder(text: "新提醒", fireDate: .now.addingTimeInterval(3600))
        try store.add(past)
        try store.add(future)
        try store.pause(future.id)
        XCTAssertTrue(ReminderSchedule.preview(try XCTUnwrap(store.reminder(id: future.id))).isEmpty)
        try store.resume(future.id)
        XCTAssertEqual(store.reminder(id: future.id)?.status, .active)
        try store.remove(future.id)
        try store.resume(future.id)
        XCTAssertEqual(store.reminder(id: future.id)?.status, .cancelled)
        XCTAssertNotNil(store.reminder(id: past.id))
        XCTAssertEqual(store.reminders.count, 2)
    }

    func testExplicitReopenRetainsHistoryAndDoesNotImmediatelyAutoCompleteAgain() throws {
        let store = store()
        let now = Date.now
        var task = TimedReminder(text: "纠正误完成", fireDate: now.addingTimeInterval(-7200))
        task.autoCompleteAt = now.addingTimeInterval(-3600)
        try store.add(task)
        try store.refresh(now: now)
        XCTAssertEqual(store.reminder(id: task.id)?.status, .completed)
        try store.reopen(task.id, now: now)
        try store.refresh(now: now)
        let saved = try XCTUnwrap(store.reminder(id: task.id))
        XCTAssertEqual(saved.status, .active)
        XCTAssertNil(saved.autoCompleteAt)
        XCTAssertEqual(saved.activity.suffix(2).map(\.kind), ["autoCompleted", "reopened"])
        try store.reopen(task.id, now: now)
        XCTAssertEqual(store.reminder(id: task.id)?.revision, saved.revision)
        store.reload()
        XCTAssertEqual(store.reminder(id: task.id), saved)
    }

    func testEditingRejectsStaleRevisionAndPreservesStatusAndHistory() throws {
        let store = store()
        let original = TimedReminder(text: "新提醒", fireDate: .now.addingTimeInterval(3600))
        try store.add(original)
        var change = original
        change.text = "修改后的提醒"
        change.status = .completed // update is not a hidden completion command
        try store.update(change)
        XCTAssertEqual(store.reminder(id: original.id)?.status, .active)
        XCTAssertThrowsError(try store.update(original))
        XCTAssertEqual(store.reminder(id: original.id)?.text, "修改后的提醒")
        XCTAssertEqual(store.reminder(id: original.id)?.activity.map(\.kind), ["created", "updated"])
    }

    func testOnlyExplicitAutoCompletionChangesTaskStateAtDeadline() throws {
        let store = store()
        let start = Date.now.addingTimeInterval(3600)
        let end = start.addingTimeInterval(3600)
        let stopped = TimedReminder(text: "只停止提醒", fireDate: start, repeats: .daily, endDate: end)
        let automatic = TimedReminder(text: "自动结束", fireDate: start, repeats: .daily, autoCompleteAt: end)
        try store.add(stopped)
        try store.add(automatic)
        try store.refresh(now: end)
        try store.refresh(now: end.addingTimeInterval(60))
        XCTAssertEqual(store.reminder(id: stopped.id)?.status, .active)
        let completed = try XCTUnwrap(store.reminder(id: automatic.id))
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.activity.filter { $0.kind == "autoCompleted" }.count, 1)
        XCTAssertEqual(completed.activity.last?.date, end)
    }

    func testAutoCompletionPreventsSameTimeOrLaterNotificationsEvenBeforeAppRefresh() {
        let reminder = TimedReminder(text: "结束", fireDate: date(28), autoCompleteAt: date(28, minute: 10), phases: [
            ReminderPhase(startDate: date(28), intervalMinutes: 5, maxOccurrences: 8)
        ])
        XCTAssertEqual(ReminderSchedule.preview(reminder, now: date(27), limit: 20), [date(28), date(28, minute: 5)])
    }

    func testUnboundedHighFrequencyAndConflictingRulesAreRejected() {
        var reminder = TimedReminder(text: "提醒", fireDate: date(28), phases: [
            ReminderPhase(startDate: date(28), intervalMinutes: 5)
        ])
        XCTAssertThrowsError(try ReminderSchedule.validate(reminder))
        reminder.phases?[0].maxOccurrences = 4
        XCTAssertNoThrow(try ReminderSchedule.validate(reminder))
        reminder.phases?[0].repeats = .daily
        XCTAssertThrowsError(try ReminderSchedule.validate(reminder))
    }

    func testDailyWallClockStaysAtNineAcrossDaylightSavingTransition() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 9)))
        let reminder = TimedReminder(text: "早上提醒", fireDate: start, repeats: .daily, timeZoneIdentifier: "America/New_York")
        let dates = ReminderSchedule.preview(reminder, now: start.addingTimeInterval(-1), limit: 3)
        XCTAssertEqual(dates.map { calendar.component(.hour, from: $0) }, [9, 9, 9])
        XCTAssertEqual(dates[1].timeIntervalSince(dates[0]), 25 * 3600)
    }

    func testOldNotificationCannotCompleteRevisedTaskButCurrentActionIsIdempotent() throws {
        let store = store()
        let original = TimedReminder(text: "提醒", fireDate: .now.addingTimeInterval(3600))
        try store.add(original)
        var changed = original
        changed.text = "新规则"
        try store.update(changed)
        let manager = NotificationManager.shared
        let previous = manager.reminderStore
        manager.reminderStore = store
        defer { manager.reminderStore = previous }
        manager.completeReminder(original.id, revision: 1)
        XCTAssertEqual(store.reminder(id: original.id)?.status, .active)
        manager.completeReminder(original.id, revision: 2)
        manager.completeReminder(original.id, revision: 2)
        XCTAssertEqual(store.reminder(id: original.id)?.status, .completed)
        XCTAssertEqual(store.reminder(id: original.id)?.activity.filter { $0.kind == "completed" }.count, 1)
    }
}
