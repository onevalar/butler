import Foundation
import XCTest
@testable import Butler

final class ChatSendPersistenceTests: XCTestCase {
    @MainActor private func fixture(_ scope: ChatScope = .general) throws -> ChatSessionFiles {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = ChatSessionFiles(scope: scope, root: root)
        try files.prepare()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return files
    }

    @MainActor func testCommitKeepsEveryPhotoAndShareReceiptAcrossReopen() async throws {
        for scope: ChatScope in [.general, .task(UUID())] {
            let files = try fixture(scope)
            let previous = ChatTurn(question: "上一条", answer: "已回复")
            let turn = ChatTurn(question: "这两件东西")
            let draft = ChatDraft(text: "  这两件东西\n", photos: [Data([3, 8]), Data([9, 4, 1])], receivedShareIDs: [UUID()])
            let saved = try files.saveSendingTurn(turn, history: [previous], draft: draft)
            XCTAssertEqual(saved.id, turn.id)
            XCTAssertEqual(saved.photos, ["\(turn.id.uuidString)-0.jpg", "\(turn.id.uuidString)-1.jpg"])
            for (index, name) in try XCTUnwrap(saved.photos).enumerated() {
                XCTAssertEqual(try Data(contentsOf: files.photos.appendingPathComponent(name)), draft.photos[index])
            }
            XCTAssertEqual(try JSONDecoder().decode([ChatTurn].self, from: Data(contentsOf: files.transcript)), [previous, saved])
            // Simulate termination after the history commit, before clearing the draft.
            let reopened = ChatSessionFiles(scope: scope, root: files.root)
            XCTAssertEqual(try reopened.loadDraft(), ChatDraft(receivedShareIDs: draft.receivedShareIDs))
        }
    }

    @MainActor func testSecondPhotoFailureNeverPublishesPartialTurnOrOverwritesExistingPhoto() async throws {
        let files = try fixture()
        let previous = ChatTurn(question: "必须保留的原记录")
        try files.saveTurns([previous])
        let original = try Data(contentsOf: files.transcript)
        let turn = ChatTurn(question: "两张照片")
        let draft = ChatDraft(text: turn.question, photos: [Data([1, 2]), Data([8, 9])], receivedShareIDs: [UUID()])
        try FileManager.default.createDirectory(at: files.photos, withIntermediateDirectories: true)
        let occupied = files.photos.appendingPathComponent("\(turn.id.uuidString)-1.jpg")
        try Data([77]).write(to: occupied)
        XCTAssertThrowsError(try files.saveSendingTurn(turn, history: [previous], draft: draft))
        XCTAssertEqual(try Data(contentsOf: occupied), Data([77]))
        XCTAssertEqual(try Data(contentsOf: files.transcript), original)
        XCTAssertEqual(try files.loadDraft(), draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.photos.appendingPathComponent("\(turn.id.uuidString)-0.jpg").path))
    }

    @MainActor func testTranscriptFailureRetainsWholeDraftAndDoesNotLeaveCompletedPhotos() async throws {
        let files = try fixture()
        try FileManager.default.createDirectory(at: files.transcript, withIntermediateDirectories: false)
        let draft = ChatDraft(text: "保存失败要保留", photos: [Data([6, 2])])
        XCTAssertThrowsError(try files.saveSendingTurn(ChatTurn(question: draft.text), history: [], draft: draft))
        let raw = try JSONDecoder().decode(ChatDraft.self, from: Data(contentsOf: files.draft))
        XCTAssertEqual(raw.text, draft.text)
        XCTAssertEqual(raw.photos, draft.photos)
        // Unreadable history must not be treated as an empty history and consume the draft.
        XCTAssertThrowsError(try files.loadDraft())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: files.photos.path), [])
    }

    @MainActor func testDraftWriteFailureDoesNotStartPhotoOrTranscriptWrites() async throws {
        let files = try fixture()
        try FileManager.default.createDirectory(at: files.draft, withIntermediateDirectories: false)
        XCTAssertThrowsError(try files.saveSendingTurn(ChatTurn(question: "保留"), history: [],
            draft: ChatDraft(text: "保留", photos: [Data([2, 5])])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.photos.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.transcript.path))
    }

    @MainActor func testInterruptedBeforeCommitRestoresDraftEvenWhenOtherTurnsExist() async throws {
        let files = try fixture()
        try files.saveTurns([ChatTurn(question: "另一条消息")])
        let draft = ChatDraft(text: "没有提交的输入", photos: [Data([9, 2])], receivedShareIDs: [UUID()])
        var marked = draft
        marked.sendingTurnID = UUID()
        try JSONEncoder().encode(marked).write(to: files.draft)
        XCTAssertEqual(try files.loadDraft(), draft)
        try FileManager.default.removeItem(at: files.transcript)
        XCTAssertEqual(try files.loadDraft(), draft)
    }

    @MainActor func testCorruptTranscriptPreservesMarkedDraftBytes() async throws {
        let files = try fixture()
        let draft = ChatDraft(text: "不能丢失", photos: [Data([4])], sendingTurnID: UUID())
        let bytes = try JSONEncoder().encode(draft)
        try bytes.write(to: files.draft)
        try Data("broken history".utf8).write(to: files.transcript)
        XCTAssertThrowsError(try files.loadDraft())
        XCTAssertEqual(try Data(contentsOf: files.draft), bytes)
    }

    @MainActor func testLegacyDraftWithoutMarkerOrShareIDsRemainsReadable() async throws {
        let files = try fixture()
        try Data(#"{"text":"旧草稿","photos":["AQID"]}"#.utf8).write(to: files.draft)
        XCTAssertEqual(try files.loadDraft(), ChatDraft(text: "旧草稿", photos: [Data([1, 2, 3])]))
    }

    @MainActor func testNewDraftAfterCommitIsNeverConsumedByOldHistory() async throws {
        let files = try fixture()
        _ = try files.saveSendingTurn(ChatTurn(question: "已发送"), history: [], draft: ChatDraft(text: "已发送"))
        let next = ChatDraft(text: "新想法", photos: [Data([7])], receivedShareIDs: [UUID()])
        try JSONEncoder().encode(next).write(to: files.draft, options: .atomic)
        XCTAssertEqual(try files.loadDraft(), next)
    }
}
