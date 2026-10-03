import Foundation
import XCTest
@testable import Butler

@MainActor final class FakeCalendarDevice: SystemCalendarDevice {
    nonisolated deinit {}

    var authorized = true
    var authorizationCalls = 0
    var reads = 0
    var writes = 0
    var failAfterWrite = false
    var onSave: (() throws -> Void)?
    var onAuthorize: (() async -> Void)?
    var live: [SystemCalendarEvent] = []
    var prepared: SystemCalendarEvent?
    var spans: [CalendarEventSpan] = []
    var lists = [SystemCalendarList(id: "personal", title: "安排", source: "私人", writable: true),
                 SystemCalendarList(id: "work", title: "安排", source: "工作", writable: true)]
    func authorize() async throws -> Bool { authorizationCalls += 1; await onAuthorize?(); return authorized }
    func calendars() throws -> [SystemCalendarList] { reads += 1; return lists }
    func events(start: Date, end: Date, calendarID: String?) throws -> [SystemCalendarEvent] {
        reads += 1
        return live.filter { $0.fields.start < end && $0.fields.end > start && (calendarID == nil || $0.calendar.id == calendarID) }
    }
    func event(_ key: CalendarEventKey) throws -> SystemCalendarEvent? { reads += 1; return live.first { $0.key == key } }
    func prepare(calendarID: String, fields: CalendarEventFields, frequency: String?) throws -> CalendarEventKey {
        let key = CalendarEventKey(itemID: UUID().uuidString, start: fields.start)
        prepared = .init(key: key, calendar: lists.first { $0.id == calendarID }!, fields: fields, revision: "1",
            recurring: frequency != nil, recurrenceDescription: frequency ?? "none", editable: true, scheduleEditable: true)
        return key
    }
    func savePrepared(_ key: CalendarEventKey) throws -> CalendarEventKey {
        try onSave?(); live.append(prepared!); writes += 1
        if failAfterWrite { throw CalendarFailure("reply lost") }; return key
    }
    func discardPrepared(_ key: CalendarEventKey) { prepared = nil }
    func edit(_ before: SystemCalendarEvent, patch: CalendarEventPatch, span: CalendarEventSpan) throws -> CalendarEventKey? {
        guard live.first(where: { $0.key == before.key })?.revision == before.revision else { throw CalendarFailure("stale") }
        spans.append(span); writes += 1
        // Deliberately preserve a preceding and a following occurrence to distinguish the spans.
        let targets = live.filter { $0.key == before.key || (span == .futureEvents && $0.key.itemID == before.key.itemID && $0.key.start > before.key.start) }
        for event in targets {
            live.removeAll { $0.key == event.key }
            if case .delete = patch { continue }
            let fields = patch.fields(after: event.fields)
            live.append(.init(key: .init(itemID: event.key.itemID, start: fields.start), calendar: event.calendar,
                fields: fields, revision: UUID().uuidString, recurring: event.recurring,
                recurrenceDescription: event.recurrenceDescription, editable: true, scheduleEditable: true))
        }
        if failAfterWrite { throw CalendarFailure("reply lost") }
        if case .delete = patch { return nil }
        return .init(itemID: before.key.itemID, start: patch.fields(after: before.fields).start)
    }
}

@MainActor final class SystemCalendarStoreTests: XCTestCase {
    private func file() -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent("calendar-test-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("operations.json")
    }
    private func fields() -> CalendarEventFields {
        let start = ISO8601DateFormatter().date(from: "2027-07-13T01:27:00Z")!
        return .init(title: "交材料", location: "东门", notes: "原件", start: start, end: start.addingTimeInterval(2700), timeZone: "Asia/Shanghai", allDay: false, alertMinutes: 17)
    }
    private func create(_ device: FakeCalendarDevice) -> SystemCalendarChange { .create(calendar: device.lists[1], fields: fields(), frequency: nil) }
    private func failure(_ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected failure") } catch {}
    }

    func testHomePermissionDoesNotAuthorizeConversationAndRevocationSurvivesRestart() async throws {
        let url = file(), device = FakeCalendarDevice(); let store = SystemCalendarStore(file: url, device: device)
        XCTAssertTrue(store.systemAuthorized)
        XCTAssertThrowsError(try store.calendars()); XCTAssertThrowsError(try store.operations())
        await failure { _ = try await store.apply(create(device), operationID: UUID()) }
        XCTAssertEqual(device.reads, 0); XCTAssertEqual(device.writes, 0); XCTAssertEqual(device.authorizationCalls, 0)
        _ = try await store.apply(.access(true), operationID: UUID())
        XCTAssertEqual(device.reads, 0)
        XCTAssertEqual(try store.calendars().count, 2)
        _ = try await store.apply(.access(false), operationID: UUID())
        XCTAssertTrue(device.authorized)
        let reopened = SystemCalendarStore(file: url, device: device)
        XCTAssertFalse(reopened.conversationAllowed); XCTAssertThrowsError(try reopened.calendars())
    }

    func testDeniedAndCancelledAuthorizationNeverGrantsConversationAccess() async throws {
        let device = FakeCalendarDevice(); device.authorized = false
        let store = SystemCalendarStore(file: file(), device: device)
        await failure { _ = try await store.apply(.access(true), operationID: UUID()) }
        XCTAssertFalse(store.conversationAllowed)
        device.authorized = true
        var pending: CheckedContinuation<Void, Never>?
        device.onAuthorize = { await withCheckedContinuation { pending = $0 } }
        let task = Task { try await store.apply(.access(true), operationID: UUID()) }
        while pending == nil { await Task.yield() }
        XCTAssertThrowsError(try store.calendars())
        task.cancel(); pending?.resume()
        await failure { _ = try await task.value }
        XCTAssertFalse(store.conversationAllowed)
    }

    func testJournalPrecedesWriteLostReplyReconcilesAndNewUUIDCannotDuplicate() async throws {
        let url = file(), device = FakeCalendarDevice(); let store = SystemCalendarStore(file: url, device: device)
        _ = try await store.apply(.access(true), operationID: UUID())
        let op = UUID(), change = create(device)
        device.onSave = {
            let reopened = SystemCalendarStore(file: url, device: device)
            let operations = try reopened.operations()
            XCTAssertEqual(operations.first?.id, op)
            XCTAssertEqual(operations.first?.key, device.prepared?.key)
            XCTAssertEqual(operations.first?.succeeded, false)
        }
        device.failAfterWrite = true
        await failure { _ = try await store.apply(change, operationID: op) }
        await failure { _ = try await store.apply(change, operationID: UUID()) }
        let reopened = SystemCalendarStore(file: url, device: device)
        _ = try await reopened.apply(change, operationID: op)
        XCTAssertEqual(device.writes, 1); XCTAssertEqual(device.live.first?.calendar.id, "work")
        XCTAssertTrue(try reopened.operations()[0].succeeded)
    }

    func testStaleProposalAndRevokedSystemPermissionDoNotWrite() async throws {
        let device = FakeCalendarDevice(); let store = SystemCalendarStore(file: file(), device: device)
        _ = try await store.apply(.access(true), operationID: UUID())
        _ = try await store.apply(create(device), operationID: UUID())
        let before = device.live[0]
        _ = try device.edit(before, patch: .title("手机上改过"), span: .thisEvent)
        await failure { _ = try await store.apply(.edit(before: before, patch: .delete, span: .thisEvent), operationID: UUID()) }
        XCTAssertEqual(device.live[0].fields.title, "手机上改过")
        device.authorized = false
        XCTAssertThrowsError(try store.calendars())
        await failure { _ = try await store.apply(create(device), operationID: UUID()) }
        XCTAssertEqual(device.writes, 2)
    }

    func testRepeatOccurrenceSelectionAndFutureScopeAreNotInterchanged() async throws {
        for span in [CalendarEventSpan.thisEvent, .futureEvents] {
            let device = FakeCalendarDevice(); let store = SystemCalendarStore(file: file(), device: device)
            _ = try await store.apply(.access(true), operationID: UUID())
            for day in [0, 1, 2] {
                var f = fields(); f.start.addTimeInterval(Double(day) * 86400); f.end.addTimeInterval(Double(day) * 86400)
                device.live.append(.init(key: .init(itemID: "series", start: f.start), calendar: device.lists[1], fields: f,
                    revision: "\(day)", recurring: true, recurrenceDescription: "daily", editable: true, scheduleEditable: true))
            }
            let before = device.live[1]
            _ = try await store.apply(.edit(before: before, patch: .delete, span: span), operationID: UUID())
            XCTAssertEqual(device.spans, [span])
            XCTAssertEqual(device.live.count, span == .thisEvent ? 2 : 1)
            XCTAssertEqual(device.live[0].fields.start, fields().start, "Prior occurrence must survive")
        }
    }

    func testUncertainDeletionAndFutureChangeCannotBeProvenFromMissingOrSingleInstance() async throws {
        let device = FakeCalendarDevice(); let store = SystemCalendarStore(file: file(), device: device)
        _ = try await store.apply(.access(true), operationID: UUID())
        _ = try await store.apply(.create(calendar: device.lists[1], fields: fields(), frequency: "daily"), operationID: UUID())
        device.failAfterWrite = true
        let editID = UUID()
        await failure { _ = try await store.apply(.edit(before: device.live[0], patch: .title("新标题"), span: .futureEvents), operationID: editID) }
        XCTAssertThrowsError(try store.reconcile(editID))
        let deleteID = UUID()
        await failure { _ = try await store.apply(.edit(before: device.live[0], patch: .delete, span: .thisEvent), operationID: deleteID) }
        XCTAssertThrowsError(try store.reconcile(deleteID))
        XCTAssertEqual(device.writes, 3)
    }

    func testAllDayExclusiveEndAcrossDSTAndInvalidRanges() async throws {
        var f = fields(); f.allDay = true; f.timeZone = "America/New_York"
        f.start = ISO8601DateFormatter().date(from: "2027-03-14T05:00:00Z")!
        f.end = ISO8601DateFormatter().date(from: "2027-03-15T04:00:00Z")!
        XCTAssertEqual(f.end.timeIntervalSince(f.start), 23 * 3600)
        XCTAssertNoThrow(try f.validate())
        f.end.addTimeInterval(3600); XCTAssertThrowsError(try f.validate())
        f = fields(); f.end = f.start; XCTAssertThrowsError(try f.validate())
        f = fields(); f.alertMinutes = -1; XCTAssertThrowsError(try f.validate())
        f = fields(); f.timeZone = "invented"; XCTAssertThrowsError(try f.validate())
    }

    func testReadOnlyInvitationsAndComplexSchedulesAreNotOverwritten() async throws {
        let device = FakeCalendarDevice(); let store = SystemCalendarStore(file: file(), device: device)
        _ = try await store.apply(.access(true), operationID: UUID())
        let f = fields(), key = CalendarEventKey(itemID: "external", start: fields().start)
        let invitation = SystemCalendarEvent(key: key, calendar: device.lists[1], fields: f, revision: "1",
            recurring: false, recurrenceDescription: "none", editable: false, scheduleEditable: true)
        device.live = [invitation]
        XCTAssertThrowsError(try store.validate(.edit(before: invitation, patch: .delete, span: .thisEvent)))
        let complex = SystemCalendarEvent(key: key, calendar: device.lists[1], fields: f, revision: "2",
            recurring: false, recurrenceDescription: "none", editable: true, scheduleEditable: false)
        device.live = [complex]
        XCTAssertThrowsError(try store.validate(.edit(before: complex,
            patch: .schedule(start: f.start, end: f.end, timeZone: f.timeZone, allDay: false, alertMinutes: nil), span: .thisEvent)))
        XCTAssertNoThrow(try store.validate(.edit(before: complex, patch: .title("只改标题"), span: .thisEvent)))
        device.lists[1] = .init(id: "work", title: "安排", source: "工作", writable: false)
        await failure { _ = try await store.apply(create(device), operationID: UUID()) }
        XCTAssertEqual(device.writes, 0)
    }

    func testCorruptJournalFailsClosedAndUnwritableJournalNeverSavesPreparedEvent() async throws {
        let url = file(), device = FakeCalendarDevice()
        let store = SystemCalendarStore(file: url, device: device)
        _ = try await store.apply(.access(true), operationID: UUID())
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        await failure { _ = try await store.apply(create(device), operationID: UUID()) }
        XCTAssertNil(device.prepared); XCTAssertEqual(device.writes, 0)
        try FileManager.default.removeItem(at: url); try Data("bad".utf8).write(to: url)
        let broken = SystemCalendarStore(file: url, device: device)
        await failure { _ = try await broken.apply(.access(true), operationID: UUID()) }
        XCTAssertThrowsError(try broken.calendars())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "bad")
    }
}
