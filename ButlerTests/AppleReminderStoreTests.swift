import Foundation
import XCTest
@testable import Butler

@MainActor final class FakeAppleReminderDevice: AppleReminderDevice {
    var authorized = true
    var authorization: String { authorized ? "authorized" : "denied" }
    var availableLists = [AppleReminderList(id: "personal", title: "待办", source: "iCloud", writable: true, isDefault: true),
                          AppleReminderList(id: "work", title: "待办", source: "工作", writable: true, isDefault: false)]
    var live: [String: AppleReminderSnapshot] = [:]
    var prepared: [String: AppleReminderSnapshot] = [:]
    var writes: [String] = []
    var authorizationCalls = 0
    var failBeforeSave = false
    var failAfterWrite = false
    var failRead = false
    var onSave: (() throws -> Void)?
    var onReadAll: (() async -> Void)?
    var onAuthorize: (() async -> Void)?
    func authorize() async throws -> Bool { authorizationCalls += 1; await onAuthorize?(); return authorized }
    func lists() throws -> [AppleReminderList] { availableLists }
    func reminders(listID: String?) async throws -> [AppleReminderSnapshot] {
        await onReadAll?()
        if failRead { throw AppleReminderFailure("read failed") }
        return live.values.filter { listID == nil || $0.list.id == listID }.sorted { $0.id < $1.id }
    }
    func reminder(id: String) throws -> AppleReminderSnapshot? {
        if failRead { throw AppleReminderFailure("read failed") }
        return live[id]
    }
    func prepare(listID: String, fields: AppleReminderFields) throws -> String {
        let id = UUID().uuidString
        let list = availableLists.first { $0.id == listID }!
        prepared[id] = AppleReminderSnapshot(id: id, list: list, fields: fields, completed: false,
                                            revision: "1", scheduleEditable: true, scheduleDescription: fields.scheduleSummary)
        return id
    }
    func savePrepared(id: String) throws {
        try onSave?()
        if failBeforeSave { throw AppleReminderFailure("save rejected") }
        live[id] = prepared[id]
        writes.append("create:\(id)")
        if failAfterWrite { throw AppleReminderFailure("reply lost") }
    }
    func discardPrepared(id: String) { prepared[id] = nil }
    func edit(before: AppleReminderSnapshot, patch: AppleReminderPatch) throws {
        guard live[before.id]?.revision == before.revision else { throw AppleReminderFailure("stale") }
        if case .delete = patch { live[before.id] = nil }
        else {
            let completed: Bool = if case .completed(let value) = patch { value } else { before.completed }
            live[before.id] = AppleReminderSnapshot(id: before.id, list: before.list, fields: patch.fields(after: before.fields),
                completed: completed, revision: UUID().uuidString, scheduleEditable: before.scheduleEditable,
                scheduleDescription: before.scheduleDescription)
        }
        writes.append("edit:\(before.id)")
        if failAfterWrite { throw AppleReminderFailure("reply lost") }
    }
}

@MainActor final class AppleReminderStoreTests: XCTestCase {
    private func file() -> URL {
        let directory = URL.temporaryDirectory.appendingPathComponent("apple-reminder-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("operations.json")
    }
    private func fields() -> AppleReminderFields {
        AppleReminderFields(title: "交电费", notes: "电表尾号27", due: .init(year: 2027, month: 4, day: 9, hour: 7, minute: 23, timeZone: "Asia/Shanghai"),
                            priority: 3, recurrence: nil, notifyAtDue: true)
    }
    private func create(_ device: FakeAppleReminderDevice) -> AppleReminderChange { .create(list: device.availableLists[1], fields: fields()) }
    private func failure(_ body: () async throws -> Void, contains text: String? = nil) async {
        do { try await body(); XCTFail("Expected failure") }
        catch { if let text { XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription) } }
    }

    func testCalendarDatesTimeZonesAndRecurrenceBoundaries() async throws {
        let date = try AppleReminderDue(year: 2027, month: 4, day: 9, hour: 7, minute: 23, timeZone: "Asia/Shanghai").date()
        XCTAssertEqual(ISO8601DateFormatter().string(from: date), "2027-04-08T23:23:00Z")
        XCTAssertThrowsError(try AppleReminderDue(year: 2027, month: 2, day: 29).date())
        XCTAssertNoThrow(try AppleReminderDue(year: 2028, month: 2, day: 29).date())
        XCTAssertThrowsError(try AppleReminderDue(year: 2027, month: 3, day: 14, hour: 2, minute: 30, timeZone: "America/New_York").date())
        XCTAssertNoThrow(try AppleReminderDue(year: 2027, month: 3, day: 14, hour: 3, minute: 30, timeZone: "America/New_York").date())
        var value = fields(); value.due = .init(year: 2027, month: 4, day: 9)
        XCTAssertThrowsError(try value.validate(), "Date-only must not acquire a midnight alarm")
        value.notifyAtDue = false; XCTAssertNoThrow(try value.validate())
        value.due = nil; value.recurrence = .init(frequency: .daily, interval: 1)
        XCTAssertThrowsError(try value.validate())
        XCTAssertThrowsError(try AppleReminderRecurrence(frequency: .weekly, interval: 1, weekdays: [2, 2]).validate())
        XCTAssertThrowsError(try AppleReminderRecurrence(frequency: .monthly, interval: 1, weekdays: [2]).validate())
        XCTAssertThrowsError(try AppleReminderRecurrence(frequency: .daily, interval: 0).validate())
        XCTAssertNoThrow(try AppleReminderRecurrence(frequency: .weekly, interval: 2, weekdays: [2, 7]).validate())
        XCTAssertEqual(AppleReminderRecurrence(frequency: .weekly, interval: 2, weekdays: [7, 2]),
                       AppleReminderRecurrence(frequency: .weekly, interval: 2, weekdays: [2, 7]))
        XCTAssertNotEqual(AppleReminderRecurrence(frequency: .weekly, interval: 2, weekdays: [7, 2]),
                          AppleReminderRecurrence(frequency: .weekly, interval: 1, weekdays: [2, 7]))
    }

    func testAuthorizationOnlyFromConfirmedAccessAndDeniedQueriesAreNotEmpty() async throws {
        let device = FakeAppleReminderDevice(); device.authorized = false
        let store = AppleReminderStore(file: file(), device: device)
        XCTAssertThrowsError(try store.lists())
        await failure { _ = try await store.reminders(listID: nil) }
        XCTAssertThrowsError(try store.validate(create(device)))
        XCTAssertEqual(device.authorizationCalls, 0)
        await failure { _ = try await store.apply(.access, operationID: UUID()) }
        XCTAssertEqual(device.authorizationCalls, 1)
        XCTAssertTrue(device.writes.isEmpty)
        XCTAssertTrue(store.operations.isEmpty)
    }

    func testSelectedListAndJournalBeforeWriteAndRepeatedConfirmation() async throws {
        let url = file(); let device = FakeAppleReminderDevice(); let store = AppleReminderStore(file: url, device: device)
        let change = create(device); let op = UUID()
        try store.validate(change)
        XCTAssertTrue(device.prepared.isEmpty)
        device.onSave = {
            let journal = try JSONDecoder().decode([AppleReminderStore.Operation].self, from: Data(contentsOf: url))
            XCTAssertEqual(journal.first?.id, op)
            XCTAssertEqual(journal.first?.targetID, device.prepared.keys.first)
            XCTAssertFalse(journal.first!.succeeded)
        }
        _ = try await store.apply(change, operationID: op)
        let reopened = AppleReminderStore(file: url, device: device)
        _ = try await reopened.apply(change, operationID: op)
        XCTAssertEqual(device.writes.count, 1)
        XCTAssertEqual(device.live.values.first?.list.id, "work", "Same title must not choose the default/personal list")
        XCTAssertEqual(device.live.values.first?.fields, fields())
        XCTAssertTrue(device.prepared.isEmpty)
    }

    func testLostCreateReplyReconcilesWithoutSavingAgain() async throws {
        let url = file(); let device = FakeAppleReminderDevice(); let store = AppleReminderStore(file: url, device: device)
        let op = UUID(); let change = create(device); device.failAfterWrite = true
        await failure { _ = try await store.apply(change, operationID: op) }
        XCTAssertFalse(store.operations.first!.succeeded)
        await failure({ _ = try await store.apply(change, operationID: UUID()) }, contains: "相同创建")
        let reopened = AppleReminderStore(file: url, device: device)
        _ = try await reopened.apply(change, operationID: op)
        XCTAssertTrue(reopened.operations.first!.succeeded)
        XCTAssertEqual(device.writes.count, 1)
        await failure { _ = try await reopened.apply(.create(list: device.availableLists[0], fields: fields()), operationID: op) }
    }

    func testMissingIdentifierNeverRecreatesAndUnknownDeletionNeverClaimsSuccess() async throws {
        let url = file(); let device = FakeAppleReminderDevice(); let store = AppleReminderStore(file: url, device: device)
        device.failBeforeSave = true
        let change = create(device); let op = UUID()
        await failure { _ = try await store.apply(change, operationID: op) }
        device.failBeforeSave = false
        await failure { _ = try await store.apply(change, operationID: op) }
        XCTAssertTrue(device.writes.isEmpty)
        // A different, explicitly confirmed reminder can still be created.
        _ = try await store.apply(.create(list: device.availableLists[0], fields: fields()), operationID: UUID())
        let before = device.live.values.first!
        device.failAfterWrite = true
        let deleteID = UUID()
        await failure { _ = try await store.apply(.edit(before: before, patch: .delete), operationID: deleteID) }
        XCTAssertTrue(device.live.isEmpty)
        XCTAssertThrowsError(try store.reconcile(deleteID), "Missing IDs can also mean a full-sync identifier change")
        XCTAssertFalse(store.operations.last!.succeeded)
        XCTAssertEqual(device.writes.count, 2)
    }

    func testExternalEditsAndListChangesInvalidateProposalWithoutWriting() async throws {
        let device = FakeAppleReminderDevice(); let store = AppleReminderStore(file: file(), device: device)
        _ = try await store.apply(create(device), operationID: UUID())
        let before = device.live.values.first!
        try device.edit(before: before, patch: .notes("手机上改过的新备注"))
        await failure({ _ = try await store.apply(.edit(before: before, patch: .title("旧提案")), operationID: UUID()) }, contains: "变化")
        XCTAssertEqual(device.live[before.id]?.fields.notes, "手机上改过的新备注")
        XCTAssertEqual(device.writes.count, 2)
        let change = create(device)
        device.availableLists[1] = .init(id: "work", title: "已改名", source: "工作", writable: true, isDefault: false)
        await failure({ _ = try await store.apply(change, operationID: UUID()) }, contains: "目标列表")
        XCTAssertEqual(device.writes.count, 2)
    }

    func testCompletionReopenAndScheduleEditsPreserveOtherFields() async throws {
        let device = FakeAppleReminderDevice(); let store = AppleReminderStore(file: file(), device: device)
        _ = try await store.apply(create(device), operationID: UUID())
        let id = device.live.keys.first!
        _ = try await store.apply(.edit(before: store.reminder(id), patch: .completed(true)), operationID: UUID())
        XCTAssertTrue(device.live[id]!.completed)
        _ = try await store.apply(.edit(before: store.reminder(id), patch: .completed(false)), operationID: UUID())
        XCTAssertFalse(device.live[id]!.completed)
        let due = AppleReminderDue(year: 2027, month: 5, day: 13)
        _ = try await store.apply(.edit(before: store.reminder(id), patch: .schedule(due: due, recurrence: nil, notifyAtDue: false)), operationID: UUID())
        XCTAssertEqual(device.live[id]?.fields.due, due)
        XCTAssertEqual(device.live[id]?.fields.notes, "电表尾号27")
        XCTAssertEqual(device.live[id]?.fields.priority, 3)
        XCTAssertFalse(device.live[id]!.fields.notifyAtDue)
    }

    func testComplexSchedulesRejectReschedulingButAllowUnrelatedEdits() async throws {
        let device = FakeAppleReminderDevice(); let store = AppleReminderStore(file: file(), device: device)
        let before = AppleReminderSnapshot(id: "external", list: device.availableLists[0], fields: fields(), completed: false,
                                          revision: "1", scheduleEditable: false, scheduleDescription: "到达公司时提醒")
        device.live[before.id] = before
        XCTAssertThrowsError(try store.validate(.edit(before: before, patch: .schedule(due: nil, recurrence: nil, notifyAtDue: false))))
        _ = try await store.apply(.edit(before: before, patch: .title("到公司交材料")), operationID: UUID())
        XCTAssertEqual(device.live[before.id]?.scheduleDescription, "到达公司时提醒")
        XCTAssertEqual(device.live[before.id]?.fields.notes, fields().notes)
    }

    func testUnreadableOrUnwritableStorageNeverWritesSystemAndDiscardsDraft() async throws {
        let url = file(); let device = FakeAppleReminderDevice()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("corrupt".utf8); try corrupt.write(to: url)
        let broken = AppleReminderStore(file: url, device: device)
        await failure { _ = try await broken.apply(create(device), operationID: UUID()) }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        try FileManager.default.removeItem(at: url)
        let store = AppleReminderStore(file: url, device: device)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        await failure { _ = try await store.apply(create(device), operationID: UUID()) }
        XCTAssertTrue(device.writes.isEmpty)
        XCTAssertTrue(device.prepared.isEmpty)
    }

    func testSavedSystemWriteWithLostLocalReceiptRecoversPersistedIntent() async throws {
        let url = file(); let device = FakeAppleReminderDevice(); let store = AppleReminderStore(file: url, device: device)
        var durable = Data()
        device.onSave = {
            durable = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let change = create(device); let op = UUID()
        await failure { _ = try await store.apply(change, operationID: op) }
        XCTAssertEqual(device.live.count, 1)
        try FileManager.default.removeItem(at: url); try durable.write(to: url)
        let reopened = AppleReminderStore(file: url, device: device)
        _ = try await reopened.apply(change, operationID: op)
        XCTAssertTrue(reopened.operations.first!.succeeded)
        XCTAssertEqual(device.writes.count, 1)
    }

    func testReadInProgressBlocksMutationAndRevokedPermissionIsNotEmptyData() async throws {
        let device = FakeAppleReminderDevice(); let store = AppleReminderStore(file: file(), device: device)
        var pending: CheckedContinuation<Void, Never>?
        device.onReadAll = { await withCheckedContinuation { pending = $0 } }
        let read = Task { try await store.reminders(listID: nil) }
        while pending == nil { await Task.yield() }
        await failure({ _ = try await store.apply(create(device), operationID: UUID()) }, contains: "正在操作")
        device.authorized = false
        pending?.resume()
        await failure { _ = try await read.value }
        XCTAssertTrue(device.writes.isEmpty)
    }
}
