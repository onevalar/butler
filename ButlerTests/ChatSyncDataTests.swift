import Foundation
import XCTest
@testable import Butler

@MainActor final class ChatSyncDataTests: XCTestCase {
    private func directory() throws -> URL {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func adapter(_ root: URL) -> ChatSyncData {
        ChatSyncData(root: root, isWorking: { false }, didImport: { _ in })
    }
    func testProjectionExcludesExecutionDraftHealthSummaryAndImageContents() async throws {
        let root = try directory(), files = ChatSessionFiles(scope: .general, root: root)
        var turn = ChatTurn(question: "确认，把牛奶加入库存", answer: "以前的回答", receipts: ["历史回执"])
        turn.localHealthResults = ["health-private-724"]
        turn.collection = ItemCollection(title: "derived-private-553", items: [])
        turn.photos = ["\(turn.id.uuidString)-0.jpg"]
        try files.saveTurns([turn])
        try SyncRecord.encode(ChatDraft(text: "draft-private-319")).write(to: files.draft)
        try Data("pending-private-613".utf8).write(to: files.pending)
        try Data("summary-private-865".utf8).write(to: files.summary)
        try FileManager.default.createDirectory(at: files.photos, withIntermediateDirectories: true)
        try Data("photo-private-402".utf8).write(to: files.photos.appendingPathComponent(turn.photos![0]))
        let projection = try XCTUnwrap(adapter(root).snapshot()[.init(kind: .chat, id: turn.id)])
        let text = String(decoding: projection, as: UTF8.self)
        for value in ["health-private", "derived-private", "draft-private", "pending-private", "summary-private", "photo-private"] {
            XCTAssertFalse(text.contains(value), value)
        }
        let decoded = try JSONDecoder().decode(SyncedChatTurn.self, from: projection)
        XCTAssertEqual(decoded.question, turn.question); XCTAssertEqual(decoded.receipts, ["历史回执"])
        XCTAssertEqual(decoded.photos, turn.photos)
    }
    func testTwoDevicesMergeDifferentTurnsAndDeleteWithoutTouchingDraftOrPending() async throws {
        let a = try directory(), b = try directory(), cloud = FakeSyncCloud()
        let scope = ChatScope.task(UUID()), fa = ChatSessionFiles(scope: scope, root: a), fb = ChatSessionFiles(scope: scope, root: b)
        let first = ChatTurn(question: "A端先说", date: Date(timeIntervalSince1970: 100))
        let second = ChatTurn(question: "B端后说", date: Date(timeIntervalSince1970: 200))
        try fa.saveTurns([first]); try fb.saveTurns([second])
        let pending = Data("do not execute or clear".utf8), draft = try SyncRecord.encode(ChatDraft(text: "unsent"))
        try pending.write(to: fb.pending); try draft.write(to: fb.draft)
        try Data("old summary".utf8).write(to: fb.summary)
        var imported: [ChatScope] = []
        let localB = ChatSyncData(root: b, isWorking: { false }, didImport: { imported.append($0) })
        let sa = SyncStore(file: a.appendingPathComponent("journal.json"), local: adapter(a), transport: cloud, kinds: [.chat])
        let sb = SyncStore(file: b.appendingPathComponent("journal.json"), local: localB, transport: cloud, kinds: [.chat])
        try await sa.setEnabled(true); try await sb.setEnabled(true)
        try await sa.synchronize(); try await sb.synchronize(); try await sa.synchronize()
        XCTAssertEqual(try adapter(a).snapshot(), try localB.snapshot()); XCTAssertEqual(cloud.records.count, 2)
        XCTAssertEqual(try JSONDecoder().decode([ChatTurn].self, from: Data(contentsOf: fb.transcript)).map(\.id), [first.id, second.id])
        XCTAssertEqual(imported, [scope]); XCTAssertFalse(FileManager.default.fileExists(atPath: fb.summary.path))
        try fa.saveTurns([second]); try await sa.synchronize(); try await sb.synchronize()
        XCTAssertEqual(try JSONDecoder().decode([ChatTurn].self, from: Data(contentsOf: fb.transcript)).map(\.id), [second.id])
        XCTAssertEqual(try Data(contentsOf: fb.pending), pending); XCTAssertEqual(try Data(contentsOf: fb.draft), draft)
    }
    func testWorkingConversationDefersImportThenRetriesWithoutLosingAnswer() async throws {
        let root = try directory(), remote = ChatTurn(question: "remote"), local = ChatTurn(question: "new local answer")
        let files = ChatSessionFiles(scope: .general, root: root), cloud = FakeSyncCloud()
        cloud.records = [.init(id: UUID(), key: .init(kind: .chat, id: remote.id), parents: [],
            payload: try SyncRecord.encode(SyncedChatTurn(scope: .general, turn: remote)), device: UUID())]
        var busy = false
        let data = ChatSyncData(root: root, isWorking: { busy }, didImport: { _ in })
        let store = SyncStore(file: root.appendingPathComponent("journal.json"), local: data, transport: cloud, kinds: [.chat])
        try await store.setEnabled(true)
        cloud.duringFetch = { busy = true; try files.saveTurns([local]) }
        do { try await store.synchronize(); XCTFail("Must wait for live answer") } catch {}
        XCTAssertEqual(try JSONDecoder().decode([ChatTurn].self, from: Data(contentsOf: files.transcript)).map(\.id), [local.id])
        busy = false; cloud.duringFetch = nil; try await store.synchronize()
        XCTAssertEqual(Set(try data.snapshot().keys.map(\.id)), [remote.id, local.id]); XCTAssertEqual(cloud.records.count, 2)
    }
    func testStaleMoveInvalidAttachmentAndBrokenScopeFailWithoutWriting() async throws {
        let root = try directory(), data = adapter(root), files = ChatSessionFiles(scope: .general, root: root)
        var turn = ChatTurn(question: "original"), malformed = ChatTurn(question: "bad path")
        try files.saveTurns([turn])
        let key = SyncRecord.Key(kind: .chat, id: turn.id), before = try XCTUnwrap(data.snapshot()[key])
        turn.answer = "new words"; try files.saveTurns([turn])
        XCTAssertThrowsError(try data.replace(key, expected: before, with: nil))
        let now = try XCTUnwrap(data.snapshot()[key])
        XCTAssertThrowsError(try data.replace(key, expected: now, with: SyncRecord.encode(SyncedChatTurn(scope: .inventory, turn: turn))))
        malformed.photos = ["../../pending-changes.json"]
        XCTAssertThrowsError(try data.replace(.init(kind: .chat, id: malformed.id), expected: nil,
            with: SyncRecord.encode(SyncedChatTurn(scope: .general, turn: malformed))))
        XCTAssertEqual(try data.snapshot()[key], now)
        let scoped = ChatSessionFiles(scope: .inventory, root: root); try scoped.prepare()
        try Data("broken".utf8).write(to: scoped.directory.appendingPathComponent("scope.json"))
        XCTAssertThrowsError(try data.snapshot())
        XCTAssertEqual(try JSONDecoder().decode([ChatTurn].self, from: Data(contentsOf: files.transcript)), [turn])
    }
}
