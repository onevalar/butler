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

    func testOfflineFuzzyRequestKeepsPrecisionWithoutGuessingAClock() throws {
        for (request, period): (String, ArrangementPeriod) in [("明天提醒我买水", .day), ("明天下午提醒我买水", .afternoon)] {
            let parsed = try XCTUnwrap(LocalReminderParser.parse(request, now: date(28), calendar: calendar))
            XCTAssertEqual(parsed.timePeriod, period)
            XCTAssertEqual(parsed.text, "买水")
            XCTAssertEqual(parsed.fireDate, date(29, hour: 0))
        }
        XCTAssertNil(LocalReminderParser.parse("明天到家提醒我买水", now: date(28), calendar: calendar))
        XCTAssertNil(LocalReminderParser.parse("明天25点提醒我买水", now: date(28), calendar: calendar))
    }

    func testFuzzyArrangementSurvivesPersistenceAndNeverCreatesMidnightNotifications() throws {
        var task = TimedReminder(text: "买水", fireDate: date(29, hour: 0), timeZoneIdentifier: "Asia/Shanghai")
        task.timePeriod = .afternoon
        try ReminderSchedule.validate(task)
        let decoded = try JSONDecoder().decode(TimedReminder.self, from: JSONEncoder().encode(task))
        XCTAssertEqual(decoded, task)
        XCTAssertEqual(decoded.timePeriod, .afternoon)
        XCTAssertTrue(ReminderSchedule.preview(task, now: date(28)).isEmpty)
        XCTAssertNil(ReminderSchedule.nativeRepeatPhase(task, now: date(28)))
        XCTAssertEqual(ReminderSchedule.occurrences(task, on: date(29), calendar: calendar).count, 1)
        XCTAssertTrue(ReminderSchedule.occurrences(task, on: date(28), calendar: calendar).isEmpty)
        XCTAssertFalse(task.whenLabel.contains("00:00"))
        XCTAssertTrue(task.whenLabel.contains("下午"))
        XCTAssertTrue(ReminderSchedule.ruleSummary(task).contains("未设置定时通知"))
        let store = store(); try store.add(task)
        XCTAssertEqual(try store.todayTaskSnapshot(now: date(29), calendar: calendar).map(\.id), [task.id])
        let agenda = HomeAgenda.build(lots: [], reminders: [task], events: [], now: date(29), calendar: calendar)
        let entries = agenda.entries(on: calendar.startOfDay(for: date(29)))
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries.first?.start)
        XCTAssertTrue(agenda.pending(on: agenda.today, at: date(29)).isEmpty)
        XCTAssertEqual(agenda.pending(on: agenda.today, at: date(29, hour: 14)).count, 1)
        for now in [date(29), date(29, hour: 14)] {
            let list = HomeList.build(day: agenda.today, agenda: agenda, facts: [], now: now, calendar: calendar)
            XCTAssertEqual(list.rows.count, 1, "No duplicate all-day and pending rows")
            XCTAssertEqual(list.rows.first?.lead, "下午")
            let candidates = BriefCandidates.make(facts: [], agenda: agenda, now: now, calendar: calendar, tasks: [task])
            XCTAssertEqual(candidates.count, 1)
            XCTAssertTrue(candidates[0].detail.contains("下午"))
            XCTAssertFalse(candidates[0].detail.contains("00:00"))
        }
        task.repeats = .daily
        XCTAssertThrowsError(try ReminderSchedule.validate(task), "No accidental repeating notification rules")
    }

    func testWidgetProjectionExcludesAutomaticDeadlineWithoutWritingOrCompletingTask() throws {
        let file = URL.temporaryDirectory.appendingPathComponent("widget-task-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let automatic = TimedReminder(text: "自动结束", fireDate: date(28), autoCompleteAt: date(28, hour: 12))
        let later = TimedReminder(text: "晚些做", fireDate: date(28, hour: 22))
        let original = try JSONEncoder().encode([automatic, later])
        try original.write(to: file)
        let store = ReminderStore(file: file, schedules: false)
        XCTAssertEqual(Set(try store.todayTaskSnapshot(now: date(28, hour: 11), calendar: calendar).map(\.id)), [automatic.id, later.id])
        XCTAssertEqual(try store.todayTaskSnapshot(now: date(28, hour: 12), calendar: calendar).map(\.id), [later.id])
        XCTAssertEqual(store.reminder(id: automatic.id)?.status, .active)
        XCTAssertEqual(try Data(contentsOf: file), original)
        try Data("broken".utf8).write(to: file)
        let broken = ReminderStore(file: file, schedules: false)
        XCTAssertThrowsError(try broken.todayTaskSnapshot(now: date(28), calendar: calendar))
    }

    func testSystemCompletionChecksLatestRevisionAndDoesNotCompleteReopenedTask() throws {
        let store = store()
        var task = TimedReminder(text: "材料", fireDate: date(28))
        try store.add(task)
        task.text = "新的材料"
        try store.update(task)
        XCTAssertThrowsError(try store.complete(task.id, expectedRevision: 1))
        XCTAssertEqual(store.reminder(id: task.id)?.status, .active)
        try store.complete(task.id, expectedRevision: 2)
        XCTAssertEqual(store.reminder(id: task.id)?.status, .completed)
        XCTAssertThrowsError(try store.complete(task.id, expectedRevision: 2))
        XCTAssertEqual(store.reminder(id: task.id)?.activity.filter { $0.kind == "completed" }.count, 1)
        try store.reopen(task.id)
        XCTAssertThrowsError(try store.complete(task.id, expectedRevision: 2))
        XCTAssertEqual(store.reminder(id: task.id)?.status, .active)
    }

    func testSystemTodayIncludesLaterTodayAndOverdueButNotTomorrowPausedOrCompleted() throws {
        let store = store()
        let overdue = TimedReminder(text: "昨日未完成", fireDate: date(27))
        let tonight = TimedReminder(text: "今晚", fireDate: date(28, hour: 22))
        let tomorrow = TimedReminder(text: "明天", fireDate: date(29))
        let paused = TimedReminder(text: "暂停", fireDate: date(28))
        let completed = TimedReminder(text: "完成", fireDate: date(28))
        let daily = TimedReminder(text: "每日", fireDate: date(20), repeats: .daily, timeZoneIdentifier: "Asia/Shanghai")
        for task in [overdue, tonight, tomorrow, paused, completed, daily] { try store.add(task) }
        try store.pause(paused.id); try store.complete(completed.id)
        let result = try store.todayTasksForSystemEntry(now: date(28, hour: 10), calendar: calendar)
        XCTAssertEqual(Set(result.map(\.id)), Set([overdue.id, tonight.id, daily.id]))
        XCTAssertEqual(result.count, 3)
    }

    func testSystemQueryDoesNotHideCorruptStorageAsEmpty() throws {
        let file = URL.temporaryDirectory.appendingPathComponent("bad-shortcut-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("broken".utf8).write(to: file)
        let store = ReminderStore(file: file, schedules: false)
        XCTAssertThrowsError(try store.tasksForSystemEntry())
        XCTAssertThrowsError(try store.todayTasksForSystemEntry())
        XCTAssertThrowsError(try store.complete(UUID(), expectedRevision: 1))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "broken")
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
