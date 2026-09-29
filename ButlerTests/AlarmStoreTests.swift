import Foundation
import XCTest
@testable import Butler

@MainActor final class FakeAlarmDevice: AlarmDevice {
    var authorization = "authorized"
    var live: [SystemAlarm] = []
    var rules: [UUID: ButlerAlarm.Rule] = [:]
    var events: [String] = []
    var authorizationCalls = 0
    var failSchedule = false
    var failAfterScheduling = false
    var failCancellation = false
    var ignoreCancellation = false
    var onAuthorize: (() async -> Void)?
    var onSchedule: (() throws -> Void)?
    func authorize() async throws -> Bool {
        authorizationCalls += 1
        await onAuthorize?()
        return authorization == "authorized"
    }
    func read() throws -> [SystemAlarm] { live }
    func schedule(id: UUID, title: String, rule: ButlerAlarm.Rule) async throws {
        events.append("schedule:\(id)")
        try onSchedule?()
        if failSchedule { throw AlarmFailure("system rejected") }
        rules[id] = rule
        let state: SystemAlarm.State = if case .timer = rule { .countdown } else { .scheduled }
        live.append(SystemAlarm(id: id, state: state))
        if failAfterScheduling { throw AlarmFailure("reply lost after accepting") }
    }
    func cancel(id: UUID) throws {
        events.append("cancel:\(id)")
        if failCancellation { throw AlarmFailure("cancel failed") }
        if ignoreCancellation { return }
        live.removeAll { $0.id == id }
    }
    func stop(id: UUID) throws {
        events.append("stop:\(id)")
        if case .weekly = rules[id] { setState(id, .scheduled) }
        else { live.removeAll { $0.id == id } }
    }
    func pause(id: UUID) throws { events.append("pause:\(id)"); setState(id, .paused) }
    func resume(id: UUID) throws { events.append("resume:\(id)"); setState(id, .countdown) }
    func setState(_ id: UUID, _ state: SystemAlarm.State) {
        live = live.map { $0.id == id ? SystemAlarm(id: id, state: state) : $0 }
    }
}

@MainActor final class AlarmStoreTests: XCTestCase {
    private func file() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alarm-test-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("alarms.json")
    }

    private func create(_ id: UUID = UUID(), rule: ButlerAlarm.Rule = .weekly(hour: 7, minute: 23, weekdays: [2, 4, 7])) -> ButlerAlarm.Change {
        .set(id: id, title: "叫醒我", rule: rule, expectedRevision: nil)
    }

    private func action(_ value: ButlerAlarm, _ action: ButlerAlarm.Action) -> ButlerAlarm.Change {
        .action(id: value.id, action: action, expectedRevision: value.revision, expiresAt: .now.addingTimeInterval(300))
    }

    private func expectFailure(_ body: () async throws -> Void, contains message: String? = nil) async {
        do { try await body(); XCTFail("Expected failure") }
        catch { if let message { XCTAssertTrue(error.localizedDescription.contains(message), error.localizedDescription) } }
    }

    func testInvalidRulesAndExactTimeBoundary() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertThrowsError(try ButlerAlarm.Rule.once(now).validate(now: now))
        XCTAssertNoThrow(try ButlerAlarm.Rule.once(now.addingTimeInterval(1)).validate(now: now))
        for rule: ButlerAlarm.Rule in [.weekly(hour: 24, minute: 0, weekdays: [1]),
            .weekly(hour: 7, minute: 60, weekdays: [1]), .weekly(hour: 7, minute: 0, weekdays: []),
            .weekly(hour: 7, minute: 0, weekdays: [1, 1]), .weekly(hour: 7, minute: 0, weekdays: [0, 8]),
            .timer(seconds: 0), .timer(seconds: 86_401)] {
            XCTAssertThrowsError(try rule.validate(now: now))
        }
        XCTAssertNoThrow(try ButlerAlarm.Rule.timer(seconds: 1).validate(now: now))
        XCTAssertNoThrow(try ButlerAlarm.Rule.timer(seconds: 86_400).validate(now: now))
        XCTAssertTrue(ButlerAlarm.Rule.weekly(hour: 7, minute: 23, weekdays: [7, 2, 4]).summary.contains("周二、周四、周日 07:23"))
    }

    func testQueriesAndProposalsNeverAskPermissionAndDenialNeverSavesOrSchedules() async throws {
        let device = FakeAlarmDevice(); device.authorization = "denied"
        let store = AlarmStore(file: file(), device: device)
        let change = create()
        try store.validate(change)
        XCTAssertTrue(try store.refresh().isEmpty)
        XCTAssertEqual(device.authorizationCalls, 0)
        await expectFailure({ try await store.apply(change, operationID: UUID()) }, contains: "权限")
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(device.events.isEmpty)
    }

    func testJournalIsWrittenBeforeSystemCallAndReplayDoesNotRestartTimer() async throws {
        let url = file(); let device = FakeAlarmDevice(); let store = AlarmStore(file: url, device: device)
        let change = create(rule: .timer(seconds: 173)); let operation = UUID()
        device.onSchedule = {
            let journal = try JSONDecoder().decode([ButlerAlarm].self, from: Data(contentsOf: url))
            XCTAssertEqual(journal.first?.operation?.kind, .schedule)
            XCTAssertEqual(journal.first?.operationID, operation)
        }
        try await store.apply(change, operationID: operation)
        let reopened = AlarmStore(file: url, device: device)
        try await reopened.apply(change, operationID: operation)
        XCTAssertEqual(device.events.count, 1)
        XCTAssertEqual(reopened.records.first?.rule, .timer(seconds: 173))
        XCTAssertNil(reopened.records.first?.operation)
    }

    func testReplacementCancelsOldBeforeNewAndNeverTouchesUnrelatedAlarm() async throws {
        let device = FakeAlarmDevice(); let store = AlarmStore(file: file(), device: device)
        let first = create(); let other = create(rule: .timer(seconds: 311))
        try await store.apply(first, operationID: UUID()); try await store.apply(other, operationID: UUID())
        let old = try store.record(first.id); let unrelated = try store.record(other.id)
        let changed = ButlerAlarm.Change.set(id: old.id, title: "晚半小时", rule: .weekly(hour: 7, minute: 53, weekdays: [2, 4, 7]), expectedRevision: old.revision)
        device.events = []
        try await store.apply(changed, operationID: UUID())
        let saved = try store.record(old.id)
        XCTAssertEqual(device.events, ["cancel:\(old.systemID)", "schedule:\(saved.systemID)"])
        XCTAssertEqual(Set(device.live.map(\.id)), Set([saved.systemID, unrelated.systemID]))
        XCTAssertEqual(saved.revision, 2)
        await expectFailure({ try await store.apply(changed, operationID: UUID()) }, contains: "变化")
        XCTAssertEqual(device.events.count, 2)
    }

    func testLostSuccessReplyReconcilesAcrossReloadWithoutDuplicating() async throws {
        let url = file(); let device = FakeAlarmDevice(); let store = AlarmStore(file: url, device: device)
        device.failAfterScheduling = true
        let change = create(); let operation = UUID()
        await expectFailure { try await store.apply(change, operationID: operation) }
        XCTAssertNotNil(try store.record(change.id).operation)
        let reopened = AlarmStore(file: url, device: device)
        try await reopened.apply(change, operationID: operation)
        XCTAssertNil(try reopened.record(change.id).operation)
        XCTAssertEqual(device.events.count, 1)
        XCTAssertEqual(device.live.count, 1)
    }

    func testFailedReplacementRetainsOldIDUntilExplicitCancellation() async throws {
        let device = FakeAlarmDevice(); let url = file(); let store = AlarmStore(file: url, device: device)
        let change = create(); try await store.apply(change, operationID: UUID())
        let old = try store.record(change.id)
        device.failCancellation = true
        await expectFailure {
            try await store.apply(.set(id: old.id, title: "新时间", rule: .timer(seconds: 421), expectedRevision: 1), operationID: UUID())
        }
        XCTAssertEqual(device.live.map(\.id), [old.systemID])
        XCTAssertEqual(device.events.filter { $0.hasPrefix("schedule:") }.count, 1)
        let reopened = AlarmStore(file: url, device: device)
        _ = try reopened.refresh()
        let pending = try reopened.record(old.id)
        XCTAssertEqual(pending.operation?.retiredIDs, [old.systemID])
        device.failCancellation = false
        try await reopened.apply(action(pending, .cancel), operationID: UUID())
        XCTAssertTrue(device.live.isEmpty)
        XCTAssertFalse(try reopened.record(old.id).enabled)
    }

    func testUncertainMissingScheduleIsNotReplayedAndExternalRemovalStaysRemoved() async throws {
        let url = file(); let device = FakeAlarmDevice(); let store = AlarmStore(file: url, device: device)
        device.failSchedule = true
        let change = create(); let op = UUID()
        await expectFailure { try await store.apply(change, operationID: op) }
        device.failSchedule = false
        let reopened = AlarmStore(file: url, device: device)
        await expectFailure({ try await reopened.apply(change, operationID: op) }, contains: "核实")
        XCTAssertEqual(device.events.count, 1)
        try await reopened.apply(action(try reopened.record(change.id), .enable), operationID: UUID())
        device.live = [] // Owner/system removed it outside the conversation.
        _ = try reopened.refresh()
        XCTAssertTrue(device.live.isEmpty)
        XCTAssertEqual(device.events.filter { $0.hasPrefix("schedule:") }.count, 2)
    }

    func testTimerPauseResumeStopAndWeeklyStopHaveDifferentEffects() async throws {
        let device = FakeAlarmDevice(); let store = AlarmStore(file: file(), device: device)
        let timer = create(rule: .timer(seconds: 173))
        try await store.apply(timer, operationID: UUID())
        try await store.apply(action(try store.record(timer.id), .pause), operationID: UUID())
        XCTAssertEqual(device.live.first?.state, .paused)
        try await store.apply(action(try store.record(timer.id), .resume), operationID: UUID())
        XCTAssertEqual(device.live.first?.state, .countdown)
        await expectFailure { try await store.apply(action(try store.record(timer.id), .stop), operationID: UUID()) }
        device.setState(try store.record(timer.id).systemID, .alerting)
        try await store.apply(action(try store.record(timer.id), .stop), operationID: UUID())
        XCTAssertTrue(device.live.isEmpty)
        let weekly = create(); try await store.apply(weekly, operationID: UUID())
        let record = try store.record(weekly.id); device.setState(record.systemID, .alerting)
        let stop = action(record, .stop); let op = UUID()
        try await store.apply(stop, operationID: op)
        XCTAssertEqual(device.live.first?.state, .scheduled)
        device.setState(record.systemID, .alerting) // Next week's alarm must not be stopped by a replay.
        try await store.apply(stop, operationID: op)
        XCTAssertEqual(device.live.first?.state, .alerting)
        let expired = ButlerAlarm.Change.action(id: weekly.id, action: .stop, expectedRevision: 2, expiresAt: .now.addingTimeInterval(-1))
        await expectFailure({ try await store.apply(expired, operationID: UUID()) }, contains: "过期")
        XCTAssertEqual(device.live.first?.state, .alerting)
    }

    func testCorruptOrUnwritableJournalPreventsSystemMutation() async throws {
        let url = file(); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("broken".utf8); try corrupt.write(to: url)
        let device = FakeAlarmDevice(); let store = AlarmStore(file: url, device: device)
        await expectFailure { try await store.apply(create(), operationID: UUID()) }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        try FileManager.default.removeItem(at: url)
        let writable = AlarmStore(file: url, device: device)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        await expectFailure { try await writable.apply(create(), operationID: UUID()) }
        XCTAssertTrue(device.events.isEmpty)
    }

    func testUnacknowledgedCancellationDoesNotCreateReplacement() async throws {
        let device = FakeAlarmDevice(); let store = AlarmStore(file: file(), device: device)
        let change = create(); try await store.apply(change, operationID: UUID())
        let old = try store.record(change.id)
        device.ignoreCancellation = true
        await expectFailure({
            try await store.apply(.set(id: old.id, title: "新时间", rule: .timer(seconds: 239), expectedRevision: old.revision), operationID: UUID())
        }, contains: "旧闹钟尚未确认取消")
        XCTAssertEqual(device.events.filter { $0.hasPrefix("schedule:") }.count, 1)
        XCTAssertEqual(device.live.map(\.id), [old.systemID])
        XCTAssertEqual(try store.record(old.id).operation?.retiredIDs, [old.systemID])
    }

    func testReceiptSaveFailureReconcilesPersistedIntentWithoutRescheduling() async throws {
        let url = file(); let device = FakeAlarmDevice(); let store = AlarmStore(file: url, device: device)
        let change = create(rule: .timer(seconds: 239)); let operation = UUID()
        var savedIntent = Data()
        device.onSchedule = {
            savedIntent = try Data(contentsOf: url)
            // Simulate storage becoming unwritable after the durable intent, before the receipt.
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        await expectFailure { try await store.apply(change, operationID: operation) }
        XCTAssertEqual(device.live.count, 1)
        XCTAssertNotNil(try store.record(change.id).operation)
        try FileManager.default.removeItem(at: url)
        try savedIntent.write(to: url)
        let reopened = AlarmStore(file: url, device: device)
        try await reopened.apply(change, operationID: operation)
        XCTAssertNil(try reopened.record(change.id).operation)
        XCTAssertEqual(device.events.count, 1)
    }

    func testDeviceLocalStorageSetupFailureBlocksPermissionAndMutation() async throws {
        let device = FakeAlarmDevice()
        let store = AlarmStore(file: file(), device: device, preparationError: "无法排除跨设备备份")
        await expectFailure({ try await store.apply(create(), operationID: UUID()) }, contains: "备份")
        XCTAssertThrowsError(try store.refresh())
        XCTAssertEqual(device.authorizationCalls, 0)
        XCTAssertTrue(device.events.isEmpty)
    }

    func testCancellationDuringAuthorizationDoesNotSchedule() async throws {
        let device = FakeAlarmDevice(); let store = AlarmStore(file: file(), device: device)
        var permission: CheckedContinuation<Void, Never>?
        device.onAuthorize = { await withCheckedContinuation { permission = $0 } }
        let task = Task { try await store.apply(self.create(), operationID: UUID()) }
        while permission == nil { await Task.yield() }
        task.cancel()
        permission?.resume()
        do { try await task.value; XCTFail("Cancelled confirmation must not schedule") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(device.events.isEmpty)
        XCTAssertTrue(store.records.isEmpty)
    }

    func testPermissionWaitLocksOutConcurrentMutations() async throws {
        let device = FakeAlarmDevice(); let store = AlarmStore(file: file(), device: device)
        var permission: CheckedContinuation<Void, Never>?
        device.onAuthorize = { await withCheckedContinuation { permission = $0 } }
        let first = Task { try await store.apply(self.create(), operationID: UUID()) }
        while permission == nil { await Task.yield() }
        await expectFailure({ try await store.apply(create(), operationID: UUID()) }, contains: "正在执行")
        permission?.resume()
        try await first.value
        XCTAssertEqual(device.live.count, 1)
    }
}
