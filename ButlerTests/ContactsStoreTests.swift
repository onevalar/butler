import Foundation
import XCTest
@testable import Butler

@MainActor final class FakeContactsDevice: ContactsDevice {
    var access: ContactAccess = .notDetermined
    var grants = 0, searches = 0, reads: [ContactField] = [], writes = 0
    var pause = false
    var suspended: CheckedContinuation<Void, Never>?
    var grant: ContactAccess = .limited
    var people: [String: ContactDraft] = [:]
    var failAfterWrite = false
    var mismatchAfterWrite = false
    var beforeWrite: (() throws -> Void)?
    func authorize() async throws {
        grants += 1
        if pause { await withCheckedContinuation { suspended = $0 } }
        access = grant
    }
    func candidate(_ id: String, _ draft: ContactDraft) -> ContactCandidate {
        .init(id: id, name: draft.name, organization: draft.organization)
    }
    func search(_ name: String, limit: Int) throws -> [ContactCandidate] {
        searches += 1
        return Array(people.filter { $0.value.name.contains(name) }.sorted { $0.key < $1.key }
            .prefix(limit).map { candidate($0.key, $0.value) })
    }
    func read(_ id: String, field: ContactField) throws -> ContactSelection {
        reads.append(field)
        guard let draft = people[id] else { throw ContactFailure("no access") }
        if mismatchAfterWrite && writes > 0 && field == .phones {
            return .init(candidate: candidate(id, draft), field: field, values: [])
        }
        return .init(candidate: candidate(id, draft), field: field, values: draft.values(field))
    }
    func create(_ draft: ContactDraft) throws -> String {
        try beforeWrite?(); writes += 1
        let id = UUID().uuidString; people[id] = draft
        if failAfterWrite { throw ContactFailure("lost reply") }
        return id
    }
    func update(_ before: ContactSelection, values: [ContactValue]) throws {
        try beforeWrite?()
        guard let old = people[before.candidate.id], try read(before.candidate.id, field: before.field) == before else { throw ContactFailure("changed") }
        writes += 1
        people[before.candidate.id] = .init(
            givenName: before.field == .givenName ? values[0].value : old.givenName,
            familyName: before.field == .familyName ? values[0].value : old.familyName,
            organization: before.field == .organization ? values[0].value : old.organization,
            phones: before.field == .phones ? values : old.phones,
            emails: before.field == .emails ? values : old.emails)
        if failAfterWrite { throw ContactFailure("lost reply") }
    }
}

@MainActor final class ContactsStoreTests: XCTestCase {
    private var draft: ContactDraft {
        .init(givenName: "敏", familyName: "李", organization: "工作室", phones: [.init(label: "工作", value: "+86 13800001234")],
            emails: [.init(label: nil, value: "test@example.invalid")])
    }
    private func setup() throws -> (ContactsStore, FakeContactsDevice, URL) {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let device = FakeContactsDevice(), file = dir.appendingPathComponent("contacts.json")
        return (ContactsStore(file: file, device: device), device, file)
    }
    private func allow(_ store: ContactsStore) async throws { _ = try await store.apply(.access(true), operationID: UUID()) }
    private func fails(_ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected refusal") } catch {}
    }
    private func select(_ store: ContactsStore, id: String, field: ContactField) async throws -> UUID {
        _ = try store.search("李")
        let text = try await store.apply(.read(try store.candidate(id), field), operationID: UUID())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return try XCTUnwrap(UUID(uuidString: json["token"] as? String ?? ""))
    }
    func testOptionalByDefaultAndDeniedDoesNotRead() async throws {
        let (store, device, _) = try setup()
        XCTAssertFalse(store.allowed); XCTAssertEqual(store.access, .notDetermined)
        XCTAssertThrowsError(try store.search("李"))
        XCTAssertThrowsError(try store.createProposal(draft))
        XCTAssertEqual(device.grants, 0); XCTAssertEqual(device.searches, 0)
        device.grant = .denied
        await fails { try await allow(store) }
        XCTAssertFalse(store.allowed); XCTAssertTrue(device.reads.isEmpty); XCTAssertEqual(device.writes, 0)
    }
    func testLimitedNameSearchContainsNoPhoneOrEmailAndNeedsSelection() async throws {
        let (store, device, _) = try setup(); device.people["first"] = draft; device.people["second"] = draft
        try await allow(store)
        XCTAssertEqual(store.access, .limited)
        let candidates = try store.search("李")
        XCTAssertEqual(candidates.count, 2)
        let text = String(decoding: try JSONEncoder().encode(candidates), as: UTF8.self)
        XCTAssertFalse(text.contains("13800001234")); XCTAssertFalse(text.contains("example.invalid"))
        XCTAssertTrue(device.reads.isEmpty)
        XCTAssertThrowsError(try store.candidate("invented"))
        _ = try await select(store, id: "second", field: .phones)
        XCTAssertEqual(device.reads, [.phones]); XCTAssertEqual(device.writes, 0)
        XCTAssertTrue(try store.search("不存在").isEmpty)
    }
    func testSearchAndFieldBoundsDoNotTruncateReplacementBaseline() async throws {
        let (store, device, _) = try setup(); try await allow(store)
        XCTAssertThrowsError(try store.search("  "))
        XCTAssertEqual(device.searches, 0)
        for i in 0..<21 { device.people["\(i)"] = draft }
        XCTAssertThrowsError(try store.search("李"))
        XCTAssertThrowsError(try ContactField.phones.validate((0..<21).map { .init(label: nil, value: "\($0)") }))
        XCTAssertThrowsError(try ContactField.givenName.validate([]))
        XCTAssertNoThrow(try ContactField.phones.validate([]))
    }
    func testSelectedFieldUpdatePreservesOtherFieldsAndInvalidatesToken() async throws {
        let (store, device, _) = try setup(); device.people["id"] = draft; try await allow(store)
        let token = try await select(store, id: "id", field: .phones)
        let after: [ContactValue] = [.init(label: "手机", value: "13900007654")]
        let change = try store.updateProposal(token: token, values: after)
        XCTAssertEqual(device.writes, 0)
        let id = UUID(); _ = try await store.apply(change, operationID: id)
        _ = try await store.apply(change, operationID: id)
        XCTAssertEqual(device.writes, 1)
        XCTAssertEqual(device.people["id"]?.phones, after)
        XCTAssertEqual(device.people["id"]?.emails, draft.emails)
        XCTAssertEqual(device.people["id"]?.organization, draft.organization)
        XCTAssertThrowsError(try store.updateProposal(token: token, values: draft.phones))
    }
    func testExternalChangeAndRemovedAccessNeverOverwrite() async throws {
        let (store, device, _) = try setup(); device.people["id"] = draft; try await allow(store)
        let token = try await select(store, id: "id", field: .phones)
        let change = try store.updateProposal(token: token, values: [])
        device.people["id"] = .init(givenName: "敏", familyName: "李", organization: "工作室", phones: [], emails: draft.emails)
        await fails { _ = try await store.apply(change, operationID: UUID()) }
        device.people.removeAll()
        await fails { _ = try await store.apply(change, operationID: UUID()) }
        device.access = .denied
        XCTAssertThrowsError(try store.search("李")); XCTAssertEqual(device.writes, 0)
    }
    func testCreateJournalFirstAndIdenticalRetryAfterRelaunchDoesNotDuplicate() async throws {
        let (store, device, file) = try setup(); try await allow(store)
        let change = try store.createProposal(draft), id = UUID()
        device.beforeWrite = {
            let entries = try JSONDecoder().decode([ContactsStore.Operation].self, from: Data(contentsOf: file))
            XCTAssertEqual(entries.first?.id, id); XCTAssertEqual(entries.first?.state, .attempted)
        }
        _ = try await store.apply(change, operationID: id)
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(text.contains("13800001234")); XCTAssertFalse(text.contains("example.invalid"))
        let reopened = ContactsStore(file: file, device: device)
        XCTAssertThrowsError(try reopened.search("李"))
        try await allow(reopened); _ = try await reopened.apply(change, operationID: id)
        XCTAssertEqual(device.people.count, 1); XCTAssertEqual(device.writes, 1)
        XCTAssertEqual(try reopened.operations().first?.state, .verified)
    }
    func testNewSameNameBeforeConfirmationBlocksDuplicateCreate() async throws {
        let (store, device, _) = try setup(); try await allow(store)
        let change = try store.createProposal(draft)
        device.people["external"] = draft
        await fails { _ = try await store.apply(change, operationID: UUID()) }
        XCTAssertEqual(device.writes, 0)
    }
    func testReadbackMismatchIsNotReportedAsVerified() async throws {
        let (store, device, _) = try setup(); try await allow(store)
        device.mismatchAfterWrite = true
        await fails { _ = try await store.apply(try store.createProposal(draft), operationID: UUID()) }
        XCTAssertEqual(device.people.count, 1)
        XCTAssertEqual(try store.operations().first?.state, .attempted)
    }
    func testJournalWriteFailurePreventsExternalWrite() async throws {
        let (store, device, file) = try setup(); try await allow(store)
        let change = try store.createProposal(draft)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await fails { _ = try await store.apply(change, operationID: UUID()) }
        XCTAssertEqual(device.writes, 0)
        XCTAssertTrue(device.people.isEmpty)
    }
    func testLostReplyBlocksNewWritesUntilExplicitUnverifiedClose() async throws {
        let (store, device, file) = try setup(); try await allow(store)
        let change = try store.createProposal(draft), id = UUID(); device.failAfterWrite = true
        await fails { _ = try await store.apply(change, operationID: id) }
        let reopened = ContactsStore(file: file, device: device); try await allow(reopened)
        await fails { _ = try await reopened.apply(try reopened.createProposal(draft), operationID: UUID()) }
        XCTAssertEqual(device.writes, 1)
        XCTAssertEqual(try reopened.search("李").count, 1)
        _ = try await reopened.apply(.closeUnknown(id), operationID: UUID())
        XCTAssertEqual(try reopened.operations().first?.state, .closedUnverified)
        XCTAssertEqual(device.writes, 1)
    }
    func testRevokeAndCancelDuringAuthorizationDiscardLateGrant() async throws {
        let (store, device, _) = try setup(); device.pause = true
        let first = Task { try await store.apply(.access(true), operationID: UUID()) }
        while device.suspended == nil { await Task.yield() }
        await fails { try await allow(store) }
        _ = try await store.apply(.access(false), operationID: UUID())
        device.suspended?.resume(); device.suspended = nil
        await fails { _ = try await first.value }
        XCTAssertFalse(store.allowed)
        let second = Task { try await store.apply(.access(true), operationID: UUID()) }
        while device.suspended == nil { await Task.yield() }
        second.cancel(); device.suspended?.resume(); device.suspended = nil
        await fails { _ = try await second.value }
        XCTAssertFalse(store.allowed); XCTAssertEqual(device.searches, 0)
    }
    func testCorruptJournalFailsClosedAndRevocationClearsSelection() async throws {
        let (store, device, file) = try setup(); device.people["id"] = draft; try await allow(store)
        let token = try await select(store, id: "id", field: .phones)
        _ = try await store.apply(.access(false), operationID: UUID()); try await allow(store)
        XCTAssertThrowsError(try store.updateProposal(token: token, values: []))
        try Data("broken".utf8).write(to: file)
        let broken = ContactsStore(file: file, device: device)
        await fails { try await allow(broken) }
        XCTAssertEqual(device.writes, 0)
    }
}
