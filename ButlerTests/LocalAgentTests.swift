import Foundation
import XCTest
@testable import Butler

@MainActor
final class LocalAgentTests: XCTestCase {
    private func file() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("memory.json")
    }

    private func seed(_ store: LocalMemoryStore, title: String, quantity: Int?) throws -> UUID {
        let preview = try store.propose(id: nil, title: title, text: "放冰箱上层", quantity: quantity, source: "虚构测试")
        try store.confirm(preview.id)
        return preview.after.id
    }

    func testLocalSaveReopenAndAbsoluteRemainingLeaveOtherShopAlone() async throws {
        let url = try file()
        let store = try LocalMemoryStore(file: url)
        let hema = try seed(store, title: "盒马麻薯", quantity: 6)
        let sams = try seed(store, title: "山姆麻薯", quantity: 18)
        let change = try store.setRemaining(id: hema, quantity: 2, source: "盒马那盒还剩两个")
        XCTAssertEqual(change.before?.quantity, 6)
        XCTAssertEqual(change.after.quantity, 2)
        XCTAssertEqual(try LocalMemoryStore(file: url).records.first { $0.id == hema }?.quantity, 6)
        try store.confirm(change.id)
        let reopened = try LocalMemoryStore(file: url)
        try reopened.confirm(change.id)
        XCTAssertEqual(reopened.records.count, 2)
        XCTAssertEqual(reopened.records.first { $0.id == hema }?.quantity, 2)
        XCTAssertEqual(reopened.records.first { $0.id == sams }?.quantity, 18)
        XCTAssertEqual(reopened.records.first { $0.id == hema }?.revision, 2)
        XCTAssertEqual(try reopened.search("盒马").map(\.id), [hema])
    }

    func testFreeTextNeedsNoCategoryAndInvalidCorrectionExpiresOldPreview() async throws {
        let store = try LocalMemoryStore(file: file())
        let note = try store.propose(id: nil, title: "衣服搭配", text: "蓝色衬衫配米色裤子", quantity: nil, source: "记住这个搭配")
        XCTAssertTrue(store.records.isEmpty)
        try store.confirm(note.id)
        XCTAssertNil(store.records[0].quantity)
        let old = try store.propose(id: nil, title: "周末", text: "去取衣服", quantity: nil, source: "周末安排")
        XCTAssertThrowsError(try store.setRemaining(id: note.after.id, quantity: 2, source: "错误数量操作"))
        XCTAssertNil(store.preview)
        XCTAssertThrowsError(try store.confirm(old.id))
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(try store.search("米色裤子").first?.text, "蓝色衬衫配米色裤子")
    }

    func testWriteFailureDoesNotPublishAndCorruptFileIsNotOverwritten() async throws {
        let url = try file()
        let store = try LocalMemoryStore(file: url)
        let proposal = try store.propose(id: nil, title: "安排", text: "明天取衣服", quantity: nil, source: "测试")
        // A directory at the destination makes atomic replacement fail.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.confirm(proposal.id))
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(store.preview?.id, proposal.id)
        try FileManager.default.removeItem(at: url)
        let invalid = Data("broken json".utf8)
        try invalid.write(to: url)
        XCTAssertThrowsError(try LocalMemoryStore(file: url))
        XCTAssertEqual(try Data(contentsOf: url), invalid)
    }

    func testModelQueriesPhoneThenProposesAndCannotConfirmItself() async throws {
        let store = try LocalMemoryStore(file: file())
        let hema = try seed(store, title: "盒马麻薯", quantity: 6)
        _ = try seed(store, title: "山姆麻薯", quantity: 18)
        let model = ScriptedModel()
        model.steps = [
            { messages in
                XCTAssertEqual(messages.count, 1) // No bulk memory upload.
                return LocalModelReply(text: "", calls: [.init(id: "search", name: "search_memory", arguments: #"{"query":"盒马"}"#)])
            },
            { messages in
                guard case .tool(_, let result) = messages.last else { throw LocalAgentError.invalidArguments }
                let matches = try JSONDecoder().decode([LocalMemory].self, from: Data(result.utf8))
                XCTAssertEqual(matches.map(\.id), [hema])
                XCTAssertEqual(matches.first?.quantity, 6)
                return LocalModelReply(text: "", calls: [.init(id: "edit", name: "set_remaining",
                    arguments: "{\"id\":\"\(hema)\",\"quantity\":2}")])
            },
            { messages in
                guard case .tool(_, let result) = messages.last else { throw LocalAgentError.invalidArguments }
                XCTAssertTrue(result.contains("awaiting_user_confirmation"))
                XCTAssertEqual(store.records.first { $0.id == hema }?.quantity, 6)
                return LocalModelReply(text: "", calls: [.init(id: "illegal", name: "confirm", arguments: "{}")])
            },
            { messages in
                guard case .tool(_, let result) = messages.last else { throw LocalAgentError.invalidArguments }
                XCTAssertTrue(result.contains("unknown_tool"))
                return LocalModelReply(text: "请核对手机上的数量修改。", calls: [])
            }
        ]
        let agent = LocalAgent(memory: store, model: model)
        let answer = try await agent.send("盒马麻薯还剩两个")
        XCTAssertEqual(answer, "请核对手机上的数量修改。")
        XCTAssertEqual(store.records.first { $0.id == hema }?.quantity, 6)
        let preview = try XCTUnwrap(store.preview)
        try agent.confirm(preview.id)
        try agent.confirm(preview.id)
        XCTAssertEqual(store.records.first { $0.id == hema }?.quantity, 2)
        guard case .receipt(let id, let saved) = agent.messages.last else { return XCTFail("Missing local receipt") }
        XCTAssertEqual(id, preview.id)
        XCTAssertTrue(saved)
    }

    func testDuplicateCallsDoNotReplacePreviewAndCancelNeverWrites() async throws {
        let store = try LocalMemoryStore(file: file())
        let model = ScriptedModel()
        let call = LocalToolCall(id: "same", name: "propose_memory", arguments: #"{"title":"搭配","text":"蓝衬衫配米色裤子"}"#)
        var firstID: UUID?
        model.steps = [
            { _ in LocalModelReply(text: "", calls: [call]) },
            { _ in firstID = store.preview?.id; return LocalModelReply(text: "", calls: [call]) },
            { _ in XCTAssertEqual(store.preview?.id, firstID); return LocalModelReply(text: "核对后保存", calls: []) }
        ]
        let agent = LocalAgent(memory: store, model: model)
        _ = try await agent.send("记下搭配")
        try agent.discard()
        XCTAssertNil(store.preview)
        XCTAssertTrue(store.records.isEmpty)
        guard case .receipt(_, let saved) = agent.messages.last else { return XCTFail("Missing cancellation receipt") }
        XCTAssertFalse(saved)
    }

    func testSyncArrivalInvalidatesOldPreviewAndBatchProposal() async throws {
        let store = try LocalMemoryStore(file: file())
        let id = try seed(store, title: "偏好", quantity: nil)
        let pending = try store.propose(id: id, title: "偏好", text: "旧编辑", quantity: nil, source: "测试")
        let incoming = LocalMemory(id: id, title: "偏好", text: "另一设备确认的更改", quantity: nil, revision: 11)
        try store.receiveSyncedNote(incoming)
        XCTAssertThrowsError(try store.confirm(pending.id))
        XCTAssertThrowsError(try store.upsert(pending.after))
        XCTAssertEqual(try store.recordsForSync(), [incoming])
        try store.delete(id)
        XCTAssertThrowsError(try store.upsert(pending.after))
    }

    func testSyncReadRejectsExternallyRemovedOrDamagedNotesInsteadOfPublishingDeletion() async throws {
        let url = try file(), store = try LocalMemoryStore(file: url)
        _ = try seed(store, title: "保留", quantity: nil)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try store.recordsForSync())
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try store.recordsForSync())
        XCTAssertEqual(store.records.count, 1)
    }

    func testModelFailureClearsPreviewAndIncompleteConversation() async throws {
        let store = try LocalMemoryStore(file: file())
        let model = ScriptedModel()
        model.steps = [
            { _ in LocalModelReply(text: "", calls: [.init(id: "new", name: "propose_memory", arguments: #"{"title":"安排","text":"取衣服"}"#)]) },
            { _ in throw URLError(.networkConnectionLost) }
        ]
        let agent = LocalAgent(memory: store, model: model)
        do { _ = try await agent.send("记一下"); XCTFail("Expected network failure") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        XCTAssertNil(store.preview)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(agent.messages.isEmpty)
        XCTAssertFalse(agent.busy)
    }
}

@MainActor
private final class ScriptedModel: LocalAgentModel {
    var steps: [([LocalAgentMessage]) throws -> LocalModelReply] = []
    func reply(to messages: [LocalAgentMessage]) async throws -> LocalModelReply {
        guard !steps.isEmpty else { throw LocalAgentError.toolLimit }
        return try steps.removeFirst()(messages)
    }
}
