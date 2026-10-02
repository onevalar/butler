import Foundation
import XCTest
@testable import Butler

final class ChatCollectionPersistenceTests: XCTestCase {
    @MainActor private func fixture() throws -> ChatSessionFiles {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = ChatSessionFiles(scope: .inventory, root: root)
        try files.prepare()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return files
    }

    @MainActor private func list(_ name: String) -> ItemCollection {
        ItemCollection(title: name, items: [.init(id: UUID(), name: name, reason: "建议理由")])
    }

    @MainActor func testCardIsSavedBeforeProseAndBelongsToExactRequestNotNewestTurn() async throws {
        let files = try fixture()
        let older = ChatTurn(question: "旧问题", answer: "旧答案")
        let request = ChatTurn(question: "修自行车用什么", relatedScopeKeys: ["inventory"], replyState: .answering)
        let newer = ChatTurn(question: "另一个记录")
        let card = list("扳手")
        let history = try files.saveReadOnlyCollections(for: request.id, displayed: card, edited: nil,
            history: [older, request, newer])
        let disk = try JSONDecoder().decode([ChatTurn].self, from: Data(contentsOf: files.transcript))
        XCTAssertEqual(history, disk)
        XCTAssertEqual(history[0], older)
        XCTAssertEqual(history[2], newer)
        XCTAssertEqual(history[1].collection, card)
        XCTAssertEqual(history[1].answer, "")
        XCTAssertEqual(history[1].replyState, .answering)
        XCTAssertEqual(Set(history[1].relatedScopeKeys ?? []), ["inventory", ChatScope.lot(card.items[0].id).key])
        XCTAssertTrue(history[1].receipts.isEmpty)
    }

    @MainActor func testEditAndNewCardCommitTogetherWithoutMovingOldCardToNewRequest() async throws {
        let files = try fixture()
        let oldCard = list("外套")
        let owner = ChatTurn(question: "之前的清单", collection: oldCard)
        let request = ChatTurn(question: "调整之后再列另一张", replyState: .answering)
        var edited = oldCard
        edited.items = []
        let newCard = list("螺丝刀")
        let saved = try files.saveReadOnlyCollections(for: request.id, displayed: newCard, edited: edited, history: [owner, request])
        XCTAssertEqual(saved[0].collection, edited)
        XCTAssertEqual(saved[1].collection, newCard)
        XCTAssertEqual(try JSONDecoder().decode([ChatTurn].self, from: Data(contentsOf: files.transcript)), saved)
    }

    @MainActor func testMissingOrFinishedRequestAndMissingEditedCardCannotPublishAnything() async throws {
        let files = try fixture()
        let request = ChatTurn(question: "查询", replyState: .answering)
        try files.saveTurns([request])
        let original = try Data(contentsOf: files.transcript)
        let card = list("不能错误挂载")
        XCTAssertThrowsError(try files.saveReadOnlyCollections(for: UUID(), displayed: card, edited: nil, history: [request]))
        for state: ChatTurn.ReplyState? in [nil, .completed, .failed, .stopped, .interrupted] {
            var ended = request
            ended.replyState = state
            XCTAssertThrowsError(try files.saveReadOnlyCollections(for: ended.id, displayed: card, edited: nil, history: [ended]))
        }
        // The first candidate must not reach disk if the second has no owner.
        XCTAssertThrowsError(try files.saveReadOnlyCollections(for: request.id, displayed: card, edited: list("不存在的旧清单"), history: [request]))
        XCTAssertEqual(try Data(contentsOf: files.transcript), original)
    }

    @MainActor func testFailedSavePreservesPreviouslyVisibleCardAndHistoryBytes() async throws {
        let files = try fixture()
        let request = ChatTurn(question: "查询", replyState: .answering)
        let first = list("已保存")
        var visible = try files.saveReadOnlyCollections(for: request.id, displayed: first, edited: nil, history: [request])
        let original = visible
        let bytes = try Data(contentsOf: files.transcript)
        // Move the existing transcript out of the way and block the destination with a directory.
        let preserved = files.directory.appendingPathComponent("preserved.json")
        try FileManager.default.moveItem(at: files.transcript, to: preserved)
        try FileManager.default.createDirectory(at: files.transcript, withIntermediateDirectories: false)
        do {
            visible = try files.saveReadOnlyCollections(for: request.id, displayed: list("不应显示"), edited: nil, history: visible)
            XCTFail("blocked transcript must fail")
        } catch {
            XCTAssertEqual(visible, original)
            XCTAssertEqual(try Data(contentsOf: preserved), bytes)
        }
        try FileManager.default.removeItem(at: files.transcript)
        try FileManager.default.moveItem(at: preserved, to: files.transcript)
        XCTAssertEqual(try JSONDecoder().decode([ChatTurn].self, from: Data(contentsOf: files.transcript)), original)
    }

    @MainActor func testUnchangedOrAbsentResultsDoNotAttemptAnotherWrite() async throws {
        let files = try fixture()
        let request = ChatTurn(question: "查询", replyState: .answering)
        let card = list("扳手")
        let saved = try files.saveReadOnlyCollections(for: request.id, displayed: card, edited: nil, history: [request])
        try FileManager.default.removeItem(at: files.transcript)
        try FileManager.default.createDirectory(at: files.transcript, withIntermediateDirectories: false)
        XCTAssertEqual(try files.saveReadOnlyCollections(for: request.id, displayed: card, edited: nil, history: saved), saved)
        XCTAssertEqual(try files.saveReadOnlyCollections(for: request.id, displayed: nil, edited: nil, history: saved), saved)
    }

    @MainActor func testSavedCardSurvivesIncompleteReplyAndRemainsOutsideSync() async throws {
        let files = try fixture()
        let request = ChatTurn(question: "查询", replyState: .answering)
        let card = list("本机物品清单")
        let saved = try files.saveReadOnlyCollections(for: request.id, displayed: card, edited: nil, history: [request])
        for state in [ChatTurn.ReplyState.stopped, .failed, .interrupted] {
            var ended = saved
            ended[0].replyState = state
            ended[0].failed = true
            ended[0].answer = "回复未完成"
            try files.saveTurns(ended)
            let restored = try JSONDecoder().decode([ChatTurn].self, from: Data(contentsOf: files.transcript))
            XCTAssertEqual(restored[0].collection, card)
            XCTAssertTrue(restored[0].collectionNotice.contains("回复未完成"))
            let sync = try JSONEncoder().encode(SyncedChatTurn(scope: .inventory, turn: restored[0]))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: sync) as? [String: Any])
            XCTAssertNil(payload["collection"])
            XCTAssertFalse(String(decoding: sync, as: UTF8.self).contains("本机物品清单"))
        }
        XCTAssertTrue(saved[0].collectionNotice.contains("仍在整理"))
        XCTAssertEqual(ChatTurn(question: "旧记录").collectionNotice, "只读清单 · 数量和状态以当前记录为准。")
    }
}
