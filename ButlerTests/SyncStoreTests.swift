import Foundation
import XCTest
@testable import Butler

@MainActor final class FakeSyncData: SyncLocalData {
    var values: [SyncRecord.Key: Data] = [:]
    var unreadable = false, crashAfterReplace = false
    var writes = 0
    func snapshot() throws -> [SyncRecord.Key: Data] {
        if unreadable { throw SyncFailure("unreadable") }; return values
    }
    func replace(_ key: SyncRecord.Key, expected: Data?, with payload: Data?) throws {
        guard values[key] == expected else { throw SyncFailure("stale") }
        values[key] = payload; writes += 1
        if crashAfterReplace { throw SyncFailure("crash after local commit") }
    }
}
@MainActor final class FakeSyncCloud: SyncTransport {
    var records: [SyncRecord] = []
    var user = "account-A", requests = 0
    var loseReply = false, offline = false
    var duringFetch: (() async throws -> Void)?
    var cloudHead = SyncCloudHead()
    var stopAfterFence = false
    var duringSend: (() async throws -> Void)?
    func account() async throws -> String {
        requests += 1
        if offline { throw SyncFailure("offline") }; return user
    }
    func head(account: String) async throws -> SyncCloudHead { cloudHead }
    func fetch(account: String, head: SyncCloudHead) async throws -> [SyncRecord] {
        try await duringFetch?(); return records
    }
    func send(_ record: SyncRecord, account: String, epoch: UUID?) async throws {
        try await duringSend?()
        guard user == account else { throw SyncFailure("account mismatch") }
        guard cloudHead.epoch == epoch, cloudHead.cleaning == nil else { throw SyncFailure("fenced") }
        if !records.contains(where: { $0.id == record.id }) { records.append(record) }
        cloudHead.revision = UUID().uuidString
        if loseReply { throw SyncFailure("reply lost") }
    }
    func clean(_ plan: SyncCleanup) async throws {
        guard user == plan.account else { throw SyncFailure("account mismatch") }
        if cloudHead.epoch == plan.id, cloudHead.cleaning == nil { return }
        if cloudHead.cleaning != plan.id {
            guard cloudHead == plan.head else { throw SyncCleanupNotStarted() }
            cloudHead.cleaning = plan.id; cloudHead.revision = UUID().uuidString
        }
        if stopAfterFence { throw SyncFailure("interrupted after fence") }
        records = plan.retained; cloudHead = .init(epoch: plan.id, revision: UUID().uuidString)
        if loseReply { throw SyncFailure("cleanup reply lost") }
    }
}
@MainActor final class SyncStoreTests: XCTestCase {
    private let key = SyncRecord.Key(kind: .note, id: UUID())
    private func make(_ cloud: FakeSyncCloud) throws -> (SyncStore, FakeSyncData, URL) {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let local = FakeSyncData(), file = dir.appendingPathComponent("sync.json")
        return (SyncStore(file: file, local: local, transport: cloud), local, file)
    }
    private func fail(_ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected refusal") } catch {}
    }
    func testDisabledDoesNotContactCloudAndDisablePreservesBothCopies() async throws {
        let cloud = FakeSyncCloud(), (store, local, _) = try make(cloud)
        local.values[key] = Data("original".utf8)
        await fail { try await store.synchronize() }; XCTAssertEqual(cloud.requests, 0)
        try await store.setEnabled(true); try await store.synchronize(); try await store.setEnabled(false)
        XCTAssertEqual(cloud.records.count, 1); XCTAssertEqual(local.values[key], Data("original".utf8))
    }
    func testTwoDevicesConvergeWithoutEchoThenPropagateDeletion() async throws {
        let cloud = FakeSyncCloud(), (a, la, _) = try make(cloud), (b, lb, _) = try make(cloud)
        la.values[key] = Data("buy three".utf8)
        try await a.setEnabled(true); try await b.setEnabled(true)
        try await a.synchronize(); try await b.synchronize(); try await b.synchronize()
        XCTAssertEqual(lb.values[key], Data("buy three".utf8)); XCTAssertEqual(cloud.records.count, 1)
        la.values[key] = nil; try await a.synchronize(); try await b.synchronize()
        XCTAssertNil(lb.values[key]); XCTAssertEqual(cloud.records.count, 2); XCTAssertNil(cloud.records.last?.payload)
    }
    func testConcurrentEditDeletePreservedUntilExplicitResolution() async throws {
        let cloud = FakeSyncCloud(), (a, la, _) = try make(cloud), (b, lb, _) = try make(cloud)
        la.values[key] = Data("base".utf8)
        try await a.setEnabled(true); try await b.setEnabled(true)
        try await a.synchronize(); try await b.synchronize()
        la.values[key] = nil; lb.values[key] = Data("keep seven".utf8)
        try await a.synchronize(); try await b.synchronize(); try await a.synchronize()
        XCTAssertNil(la.values[key]); XCTAssertEqual(lb.values[key], Data("keep seven".utf8))
        let conflict = try XCTUnwrap(a.conflicts().first), winner = try XCTUnwrap(conflict.first { $0.payload != nil })
        try a.resolve(key: key, expectedHeads: Set(conflict.map(\.id)), selected: winner.id)
        try await a.synchronize(); try await b.synchronize()
        XCTAssertEqual(la.values[key], Data("keep seven".utf8)); XCTAssertEqual(lb.values[key], la.values[key])
        XCTAssertTrue(try b.conflicts().isEmpty); XCTAssertEqual(cloud.records.count, 4)
    }
    func testEqualLocalRevisionNumbersAreNotConflictResolutionAndStaleChoiceFails() async throws {
        let cloud = FakeSyncCloud(), (a, la, _) = try make(cloud), (b, lb, _) = try make(cloud)
        la.values[key] = Data("revision1-A".utf8); lb.values[key] = Data("revision1-B".utf8)
        try await a.setEnabled(true); try await b.setEnabled(true); try await a.synchronize(); try await b.synchronize()
        let old = try XCTUnwrap(b.conflicts().first)
        lb.values[key] = Data("revision2-B".utf8)
        XCTAssertThrowsError(try b.resolve(key: key, expectedHeads: Set(old.map(\.id)), selected: old[0].id))
        XCTAssertEqual(lb.values[key], Data("revision2-B".utf8))
    }
    func testLostUploadReceiptAndRestartNeverCreateSecondRevision() async throws {
        let cloud = FakeSyncCloud(), (a, la, file) = try make(cloud)
        la.values[key] = Data("one".utf8); try await a.setEnabled(true); cloud.loseReply = true
        await fail { try await a.synchronize() }; XCTAssertEqual(cloud.records.count, 1)
        cloud.loseReply = false
        let reopened = SyncStore(file: file, local: la, transport: cloud)
        try await reopened.synchronize(); XCTAssertEqual(cloud.records.count, 1); XCTAssertEqual(reopened.pendingCount, 0)
    }
    func testInterruptedImportRecoversWithoutEchoOrOverwritingLaterLocalEdit() async throws {
        let cloud = FakeSyncCloud(), (a, la, _) = try make(cloud), (b, lb, file) = try make(cloud)
        la.values[key] = Data("remote".utf8); try await a.setEnabled(true); try await a.synchronize()
        try await b.setEnabled(true); lb.crashAfterReplace = true
        await fail { try await b.synchronize() }; XCTAssertEqual(lb.values[key], Data("remote".utf8))
        lb.crashAfterReplace = false
        let reopened = SyncStore(file: file, local: lb, transport: cloud)
        try await reopened.synchronize(); XCTAssertEqual(cloud.records.count, 1); XCTAssertEqual(lb.writes, 1)
        la.values[key] = Data("remote two".utf8); try await a.synchronize(); lb.crashAfterReplace = true
        await fail { try await reopened.synchronize() }
        lb.crashAfterReplace = false; lb.values[key] = Data("local after crash".utf8)
        let again = SyncStore(file: file, local: lb, transport: cloud)
        try await again.synchronize()
        XCTAssertEqual(lb.values[key], Data("local after crash".utf8)); XCTAssertEqual(try again.conflicts().count, 1)
    }
    func testEditDuringFetchBecomesConflictRatherThanGettingOverwritten() async throws {
        let cloud = FakeSyncCloud(), (a, la, _) = try make(cloud), (b, lb, _) = try make(cloud)
        la.values[key] = Data("base".utf8); try await a.setEnabled(true); try await b.setEnabled(true)
        try await a.synchronize(); try await b.synchronize()
        la.values[key] = Data("remote".utf8); try await a.synchronize()
        cloud.duringFetch = { lb.values[self.key] = Data("typing".utf8) }
        try await b.synchronize()
        XCTAssertEqual(lb.values[key], Data("typing".utf8)); XCTAssertEqual(try b.conflicts().count, 1)
    }
    func testAccountSwitchAndDisableDuringFetchPreventImportAndUpload() async throws {
        let cloud = FakeSyncCloud(), (a, la, _) = try make(cloud)
        la.values[key] = Data("private".utf8); try await a.setEnabled(true)
        cloud.duringFetch = { cloud.user = "account-B" }
        await fail { try await a.synchronize() }
        XCTAssertFalse(a.enabled); XCTAssertTrue(cloud.records.isEmpty)
        await fail { try await a.setEnabled(true) }
        cloud.user = "account-A"; try await a.setEnabled(true)
        cloud.duringFetch = { try await a.setEnabled(false) }
        await fail { try await a.synchronize() }; XCTAssertTrue(cloud.records.isEmpty)
    }
    func testUnreadableLocalFileAndMissingCloudHistoryAreNotDeletions() async throws {
        let cloud = FakeSyncCloud(), (a, la, _) = try make(cloud)
        la.values[key] = Data("keep".utf8); try await a.setEnabled(true); try await a.synchronize()
        la.unreadable = true; await fail { try await a.synchronize() }; XCTAssertEqual(cloud.records.count, 1)
        la.unreadable = false; cloud.records = []
        await fail { try await a.synchronize() }; XCTAssertTrue(cloud.records.isEmpty)
        XCTAssertEqual(la.values[key], Data("keep".utf8))
    }
    func testBackupRestorePausesAndPreservesRestoredEditsOnReenable() async throws {
        let cloud = FakeSyncCloud(), (a, la, _) = try make(cloud), (b, lb, _) = try make(cloud)
        la.values[key] = Data("base".utf8)
        try await a.setEnabled(true); try await b.setEnabled(true)
        try await a.synchronize(); try await b.synchronize()
        try b.prepareForRestore(); lb.values[key] = Data("restored backup".utf8)
        la.values[key] = Data("remote newer".utf8); try await a.synchronize()
        await fail { try await b.synchronize() }
        XCTAssertEqual(lb.values[key], Data("restored backup".utf8))
        try await b.setEnabled(true); try await b.synchronize()
        XCTAssertEqual(lb.values[key], Data("restored backup".utf8)); XCTAssertEqual(try b.conflicts().count, 1)
    }

    func testIncompleteCloudHistoryCannotBeFilledInFromAnUnsentLocalParent() async throws {
        let cloud = FakeSyncCloud(), (a, la, _) = try make(cloud)
        la.values[key] = Data("local".utf8); try await a.setEnabled(true)
        cloud.records = [.init(id: UUID(), key: key, parents: [UUID()], payload: Data("orphan".utf8), device: UUID())]
        await fail { try await a.synchronize() }
        XCTAssertEqual(la.values[key], Data("local".utf8)); XCTAssertEqual(la.writes, 0)
    }

    func testSeparateChatConsentDoesNotSnapshotFetchOrCreateTombstonesWhileOff() async throws {
        let cloud = FakeSyncCloud(), (_, local, file) = try make(cloud)
        let chat = SyncRecord.Key(kind: .chat, id: UUID())
        let store = SyncStore(file: file, local: local, transport: cloud, kinds: [.chat])
        local.unreadable = true
        await fail { try await store.synchronize() }; XCTAssertEqual(cloud.requests, 0)
        local.unreadable = false; local.values[chat] = Data("chat only".utf8)
        try await store.setEnabled(true); try await store.synchronize(); try store.pause()
        let requests = cloud.requests
        local.values[chat] = nil
        await fail { try await store.synchronize() }
        XCTAssertEqual(cloud.requests, requests); XCTAssertEqual(cloud.records.count, 1)
        let reopened = SyncStore(file: file, local: local, transport: cloud, kinds: [.chat])
        XCTAssertFalse(reopened.enabled)
        // Off did not mean deleted. Only explicit re-enable publishes the actual local edit.
        try await reopened.setEnabled(true); try await reopened.synchronize()
        XCTAssertEqual(cloud.records.count, 2); XCTAssertNil(cloud.records.last?.payload)
    }

    func testStreamsRejectWrongLocalRemoteAndPersistedKinds() async throws {
        let cloud = FakeSyncCloud(), (store, local, file) = try make(cloud)
        let chat = SyncRecord.Key(kind: .chat, id: UUID())
        local.values[chat] = Data("must not upload".utf8)
        try await store.setEnabled(true)
        await fail { try await store.synchronize() }; XCTAssertTrue(cloud.records.isEmpty)
        local.values = [:]
        cloud.records = [.init(id: UUID(), key: chat, parents: [], payload: Data("must not import".utf8), device: UUID())]
        await fail { try await store.synchronize() }; XCTAssertEqual(local.writes, 0)
        let chatStore = SyncStore(file: file, local: local, transport: cloud, kinds: [.chat])
        try await chatStore.synchronize()
        let wrong = SyncStore(file: file, local: local, transport: cloud)
        XCTAssertFalse(wrong.enabled); XCTAssertNotNil(wrong.warning)
    }

    func testDeferredResolutionSurvivesRestartAndDoesNotOverwriteInterveningEdits() async throws {
        let cloud = FakeSyncCloud(), (a, la, _) = try make(cloud), (b, lb, file) = try make(cloud)
        la.values[key] = Data("device A".utf8); lb.values[key] = Data("device B".utf8)
        try await a.setEnabled(true); try await b.setEnabled(true)
        try await a.synchronize(); try await b.synchronize()
        var rows = try XCTUnwrap(b.conflicts().first)
        let chosen = try XCTUnwrap(rows.first { $0.payload == Data("device A".utf8) })
        // The confirmation is still writing the live chat: do not read or import it now.
        lb.unreadable = true
        try b.resolve(key: key, expectedHeads: Set(rows.map(\.id)), selected: chosen.id, applyLocally: false)
        XCTAssertEqual(lb.writes, 0); lb.unreadable = false
        lb.values[key] = Data("new words during confirmation".utf8)
        let reopened = SyncStore(file: file, local: lb, transport: cloud)
        try await reopened.synchronize()
        XCTAssertEqual(lb.values[key], Data("new words during confirmation".utf8))
        rows = try XCTUnwrap(reopened.conflicts().first)
        let selected = try XCTUnwrap(rows.first { $0.payload == Data("device A".utf8) })
        try reopened.resolve(key: key, expectedHeads: Set(rows.map(\.id)), selected: selected.id, applyLocally: false)
        try await reopened.synchronize()
        XCTAssertEqual(lb.values[key], Data("device A".utf8)); XCTAssertTrue(try reopened.conflicts().isEmpty)
    }

    func testCleanupKeepsLatestAndConflictsButRemovesOldAncestors() async throws {
        let cloud = FakeSyncCloud(), (a, la, _) = try make(cloud), (b, lb, _) = try make(cloud)
        la.values[key] = Data("old".utf8)
        try await a.setEnabled(true); try await b.setEnabled(true)
        try await a.synchronize(); try await b.synchronize()
        la.values[key] = Data("A-current".utf8); lb.values[key] = Data("B-current".utf8)
        try await a.synchronize(); try await b.synchronize()
        let plan = try await a.previewCleanup(.history)
        XCTAssertEqual(cloud.records.count, 3); XCTAssertEqual(plan.retained.count, 2)
        try await a.clean(plan)
        XCTAssertEqual(Set(cloud.records.compactMap(\.payload)), [Data("A-current".utf8), Data("B-current".utf8)])
        XCTAssertTrue(cloud.records.allSatisfy { $0.parents.isEmpty }); XCTAssertFalse(a.enabled)
        XCTAssertEqual(la.values[key], Data("A-current".utf8)); XCTAssertTrue(a.needsReconnect)
        await fail { try await b.synchronize() }; XCTAssertTrue(b.needsReconnect)
        XCTAssertEqual(lb.values[key], Data("B-current".utf8)); XCTAssertEqual(cloud.records.count, 2)
    }

    func testClearRequiresSeparateReconnectionAndNeverReplaysOldJournal() async throws {
        let cloud = FakeSyncCloud(), (a, la, _) = try make(cloud), (offline, local, file) = try make(cloud)
        la.values[key] = Data("private".utf8)
        try await a.setEnabled(true); try await offline.setEnabled(true)
        try await a.synchronize(); try await offline.synchronize()
        try await a.clean(a.previewCleanup(.everything))
        XCTAssertTrue(cloud.records.isEmpty); XCTAssertEqual(la.values[key], Data("private".utf8))
        local.values[key] = Data("offline edit".utf8)
        let restarted = SyncStore(file: file, local: local, transport: cloud)
        await fail { try await restarted.synchronize() }; await fail { try await restarted.setEnabled(true) }
        XCTAssertTrue(cloud.records.isEmpty)
        let (account, head) = try await restarted.reconnectPreview()
        try await restarted.reconnect(account: account, head: head); try await restarted.synchronize()
        XCTAssertEqual(cloud.records.count, 1); XCTAssertEqual(cloud.records.first?.payload, Data("offline edit".utf8))
        XCTAssertTrue(cloud.records.first!.parents.isEmpty)
    }

    func testCleanupInterruptedFenceAndLostFinalReceiptResumeSameOperation() async throws {
        let cloud = FakeSyncCloud(), (store, local, file) = try make(cloud)
        local.values[key] = Data("keep local".utf8); try await store.setEnabled(true); try await store.synchronize()
        let plan = try await store.previewCleanup(.everything)
        cloud.stopAfterFence = true
        await fail { try await store.clean(plan) }
        XCTAssertEqual(store.cleanupID, plan.id); XCTAssertFalse(store.enabled)
        let reopened = SyncStore(file: file, local: local, transport: cloud)
        let resumed = try await reopened.previewCleanup(.everything)
        XCTAssertEqual(resumed, plan)
        cloud.stopAfterFence = false; cloud.loseReply = true
        await fail { try await reopened.clean(resumed) }; XCTAssertTrue(cloud.records.isEmpty)
        cloud.loseReply = false
        try await reopened.clean(resumed)
        XCTAssertNil(reopened.cleanupID); XCTAssertTrue(cloud.records.isEmpty)
        XCTAssertEqual(local.values[key], Data("keep local".utf8))
    }

    func testChangedPreviewRefusesAndCleanupFencesAWriteAlreadyInFlight() async throws {
        let cloud = FakeSyncCloud(), (a, la, _) = try make(cloud), (b, lb, _) = try make(cloud)
        la.values[key] = Data("base".utf8); try await a.setEnabled(true); try await b.setEnabled(true)
        try await a.synchronize(); try await b.synchronize()
        let stale = try await a.previewCleanup(.everything)
        lb.values[key] = Data("new".utf8); try await b.synchronize()
        await fail { try await a.clean(stale) }; XCTAssertNil(a.cleanupID); XCTAssertEqual(cloud.records.count, 2)
        let plan = try await a.previewCleanup(.everything)
        cloud.duringSend = { try await a.clean(plan) }
        lb.values[key] = Data("in flight".utf8)
        await fail { try await b.synchronize() }
        XCTAssertTrue(cloud.records.isEmpty); XCTAssertEqual(lb.values[key], Data("in flight".utf8))
    }

    func testReconnectToPreservedCurrentContentDoesNotEchoIdenticalLocalRows() async throws {
        let cloud = FakeSyncCloud(), (store, local, _) = try make(cloud)
        local.values[key] = Data("old".utf8); try await store.setEnabled(true); try await store.synchronize()
        local.values[key] = Data("current".utf8); try await store.synchronize()
        try await store.clean(store.previewCleanup(.history))
        let (account, head) = try await store.reconnectPreview()
        try await store.reconnect(account: account, head: head); try await store.synchronize()
        XCTAssertEqual(cloud.records.count, 1); XCTAssertTrue(try store.conflicts().isEmpty)
    }

    func testLegacyEnvironmentRequiresRecoveryAndArchivesJournalBeforeUploadingCurrentData() async throws {
        let development = FakeSyncCloud(), (legacy, local, file) = try make(development)
        local.values[key] = Data("old".utf8)
        try await legacy.setEnabled(true); try await legacy.synchronize()
        local.values[key] = Data("current".utf8)
        let original = try Data(contentsOf: file)
        let production = FakeSyncCloud()
        let migrated = SyncStore(file: file, local: local, transport: production, environment: "Production")
        XCTAssertTrue(migrated.needsReconnect)
        await fail { try await migrated.synchronize() }
        await fail { try await migrated.setEnabled(true) }
        XCTAssertTrue(production.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), original)
        let (account, head) = try await migrated.reconnectPreview()
        try await migrated.reconnect(account: account, head: head)
        let backups = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("reconnect-backup-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
        try await migrated.synchronize()
        XCTAssertEqual(production.records.count, 1)
        XCTAssertEqual(production.records.first?.payload, Data("current".utf8))
        XCTAssertEqual(development.records.first?.payload, Data("old".utf8))
        let reopened = SyncStore(file: file, local: local, transport: production, environment: "Production")
        XCTAssertFalse(reopened.needsReconnect)
        try await reopened.synchronize()
        XCTAssertEqual(production.records.count, 1)
        let switchedBack = SyncStore(file: file, local: local, transport: development, environment: "Development")
        XCTAssertTrue(switchedBack.needsReconnect)
        await fail { try await switchedBack.synchronize() }
        XCTAssertEqual(local.values[key], Data("current".utf8))
    }

    func testRecoveryRefusesChangedAccountOrCloudHeadWithoutResettingJournal() async throws {
        let cloud = FakeSyncCloud(), (store, local, file) = try make(cloud)
        local.values[key] = Data("keep".utf8)
        try await store.setEnabled(true); try await store.synchronize()
        let original = try Data(contentsOf: file)
        let (account, head) = try await store.reconnectPreview()
        cloud.user = "someone-else"
        await fail { try await store.reconnect(account: account, head: head) }
        cloud.user = account; cloud.cloudHead.revision = "changed"
        await fail { try await store.reconnect(account: account, head: head) }
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(local.values[key], Data("keep".utf8))
        XCTAssertEqual(cloud.records.count, 1)
    }

    func testMissingCloudHistoryPersistsRecoveryRequirementAcrossRestart() async throws {
        let cloud = FakeSyncCloud(), (store, local, file) = try make(cloud)
        local.values[key] = Data("keep".utf8)
        try await store.setEnabled(true); try await store.synchronize()
        cloud.records = []
        await fail { try await store.synchronize() }
        let reopened = SyncStore(file: file, local: local, transport: cloud)
        XCTAssertTrue(reopened.needsReconnect)
        XCTAssertFalse(reopened.enabled)
        await fail { try await reopened.setEnabled(true) }
        XCTAssertTrue(cloud.records.isEmpty)
        XCTAssertEqual(local.values[key], Data("keep".utf8))
    }

    func testCorruptJournalUnknownVersionAndCyclicHistoryFailClosed() async throws {
        let cloud = FakeSyncCloud(), (_, local, file) = try make(cloud)
        try Data("broken".utf8).write(to: file)
        let broken = SyncStore(file: file, local: local, transport: cloud)
        await fail { try await broken.setEnabled(true) }; XCTAssertEqual(cloud.requests, 0)
        let x = UUID(), y = UUID(), device = UUID()
        XCTAssertThrowsError(try SyncStore.validate([
            .init(id: x, key: key, parents: [y], payload: nil, device: device),
            .init(id: y, key: key, parents: [x], payload: nil, device: device)]))
        XCTAssertThrowsError(try SyncStore.validate([.init(id: x, key: key, parents: [], payload: nil, device: device, version: 2)]))
    }
}
