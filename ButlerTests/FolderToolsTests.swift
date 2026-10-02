import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor final class FolderToolsTests: XCTestCase {
    private func fixture() throws -> (ButlerChat, URL, ModelContainer, UserDefaults, String) {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "folder-tools-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { try? FileManager.default.removeItem(at: root); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let config = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ButlerStore.schema, configurations: [config])
        let chat = ButlerChat(container: container, reminders: ReminderStore(file: root.appendingPathComponent("tasks.json"), schedules: false),
            connection: SubscriptionConnection(keychainAccount: suite), directory: root, defaults: defaults)
        return (chat, root, container, defaults, suite)
    }

    func testPickerRequiresConfirmedRequestAndCannotReplayOrGrantFromTool() async throws {
        let (chat, root, _, _, _) = try fixture(), tools = try XCTUnwrap(chat.tools)
        tools.folders = AuthorizedFolderStore(file: root.appendingPathComponent("folders.json"), device: FakeFolderDevice())
        _ = await tools.execute(.init(id: "choose", name: "propose_folder_access", arguments: "{}"))
        XCTAssertNil(tools.folderSelectionRequest); XCTAssertTrue(try tools.folders.grants().isEmpty)
        XCTAssertThrowsError(try chat.acceptFolderSelection(root, request: UUID()))
        chat.confirm()
        let deadline = ContinuousClock.now + .seconds(2)
        while chat.working && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(chat.working)
        XCTAssertEqual(chat.turns.last?.confirmationResults?.first?.state, .awaitingUser)
        let owner = try XCTUnwrap(chat.turns.last?.id)
        let request = try XCTUnwrap(tools.folderSelectionRequest)
        try chat.acceptFolderSelection(root, request: request)
        XCTAssertEqual(chat.turns.last?.id, owner)
        XCTAssertEqual(chat.turns.last?.confirmationResults?.first?.proposalID, request)
        XCTAssertEqual(chat.turns.last?.confirmationResults?.first?.state, .succeeded)
        XCTAssertEqual(try tools.folders.grants().count, 1)
        XCTAssertThrowsError(try chat.acceptFolderSelection(root, request: request))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(tools.toolJSON.utf8)) as? [[String: Any]])
        XCTAssertEqual(json.filter { ($0["name"] as? String) == "propose_export_text_file" }.count, 1)
    }

    func testNewPickerInvalidatesOnlyPreviousSelectionAndStaleCancellationCannotCancelNewOne() async throws {
        let (chat, _, _, _, _) = try fixture(), tools = try XCTUnwrap(chat.tools)
        var requests: [UUID] = []
        for _ in 0..<2 {
            tools.add(.folder(.authorize), title: "选择文件夹", detail: nil)
            chat.confirm()
            let deadline = ContinuousClock.now + .seconds(2)
            while chat.working && ContinuousClock.now < deadline { await Task.yield() }
            XCTAssertFalse(chat.working)
            requests.append(try XCTUnwrap(tools.folderSelectionRequest))
        }
        XCTAssertNotEqual(requests[0], requests[1])
        XCTAssertEqual(chat.turns[0].confirmationResults?.first?.state, .notStarted)
        XCTAssertEqual(chat.turns[1].confirmationResults?.first?.state, .awaitingUser)
        chat.cancelFolderSelection(requests[0])
        XCTAssertEqual(tools.folderSelectionRequest, requests[1])
        chat.cancelFolderSelection(requests[1])
        XCTAssertNil(tools.folderSelectionRequest)
        XCTAssertEqual(chat.turns[1].confirmationResults?.first?.state, .notStarted)
    }

    func testExportPreviewDedupSoleConfirmationAndRevocation() async throws {
        let (chat, root, _, _, _) = try fixture(), tools = try XCTUnwrap(chat.tools), device = FakeFolderDevice()
        tools.folders = AuthorizedFolderStore(file: root.appendingPathComponent("folders.json"), device: device)
        let grant = try tools.folders.authorize(root)
        let args = String(decoding: try JSONSerialization.data(withJSONObject: ["folder_id": grant.id.uuidString, "filename": "list.md", "text": "完整的清单\n牛奶2盒"]), as: UTF8.self)
        for id in ["one", "again"] { _ = await tools.execute(.init(id: id, name: "propose_export_text_file", arguments: args)) }
        let proposal = try XCTUnwrap(tools.pending.first)
        XCTAssertEqual(tools.pending.count, 1); XCTAssertEqual(device.creates, 0)
        XCTAssertTrue(proposal.detail?.contains("完整的清单\n牛奶2盒") == true)
        XCTAssertFalse(proposal.persists)
        tools.add(.folder(.authorize), title: "other", detail: nil)
        _ = await tools.confirmIncludingSystemChanges()
        XCTAssertEqual(device.creates, 0); XCTAssertEqual(tools.pending.count, 2)
        try tools.folders.revoke(grant.id)
        let receipt = await tools.confirmIncludingSystemChanges(ids: [proposal.id])
        XCTAssertEqual(device.creates, 0); XCTAssertTrue(receipt.joined().contains("撤销"))
    }

    func testChatRecoversInterruptedProgressAndFiltersRestoredPending() async throws {
        let (chat, root, container, defaults, suite) = try fixture(), tools = try XCTUnwrap(chat.tools)
        tools.add(.note(.init(id: UUID(), title: "不得重放", text: "原内容", quantity: nil, revision: 1)), title: "笔记", detail: nil)
        let proposal = try XCTUnwrap(tools.pending.first)
        let filename = ChatScope.general.key.utf8.map { String(format: "%02x", $0) }.joined() + ".json"
        let journal = ConfirmationJournal(file: root.appendingPathComponent("device-operation-history").appendingPathComponent(filename))
        let id = try journal.begin(ids: [proposal.id], titles: [proposal.title])
        try journal.progress(id, receipts: ["结果待核查"])
        let reopened = ButlerChat(container: container, reminders: tools.reminders,
            connection: SubscriptionConnection(keychainAccount: suite), directory: root, defaults: defaults)
        XCTAssertTrue(reopened.tools?.pending.isEmpty == true)
        XCTAssertTrue(reopened.tools?.notes.records.isEmpty == true)
        XCTAssertEqual(reopened.turns.filter { $0.id == id }.count, 1)
        XCTAssertTrue(reopened.turns.last?.answer.contains("没有自动续跑") == true)
        reopened.reloadFromDisk()
        XCTAssertEqual(reopened.turns.filter { $0.id == id }.count, 1)
        XCTAssertTrue(reopened.tools?.pending.isEmpty == true)
        withExtendedLifetime(chat) {}
    }

    func testCancelledConfirmationAndFailedProgressCannotOpenPicker() async throws {
        let (chat, _, _, _, _) = try fixture(), tools = try XCTUnwrap(chat.tools)
        tools.add(.folder(.authorize), title: "choose", detail: nil)
        let work = Task { await tools.confirmIncludingSystemChanges() }
        work.cancel()
        let cancelled = await work.value
        XCTAssertTrue(cancelled.joined().contains("没有开始"))
        XCTAssertTrue(tools.pending.isEmpty); XCTAssertNil(tools.folderSelectionRequest)
        tools.add(.folder(.authorize), title: "choose again", detail: nil)
        let result = await tools.confirmIncludingSystemChanges(progress: { _ in throw FolderFailure("disk full") })
        XCTAssertTrue(result.joined().contains("未开始"))
        XCTAssertTrue(tools.pending.isEmpty); XCTAssertNil(tools.folderSelectionRequest)
    }

    func testSavedReceiptIsNotAppendedAgainAfterMissingAcknowledgement() async throws {
        let (chat, root, container, defaults, suite) = try fixture()
        let filename = ChatScope.general.key.utf8.map { String(format: "%02x", $0) }.joined() + ".json"
        let journal = ConfirmationJournal(file: root.appendingPathComponent("device-operation-history").appendingPathComponent(filename))
        let id = try journal.begin(ids: [UUID()], titles: ["saved"])
        try journal.progress(id, receipts: ["✓ saved"], finished: true)
        let turn = ChatTurn(question: "save", receipts: ["✓ saved"], confirmationIDs: [id])
        try ChatSessionFiles(scope: .general, root: root).saveTurns([turn])
        let reopened = ButlerChat(container: container, reminders: chat.tools?.reminders,
            connection: SubscriptionConnection(keychainAccount: suite), directory: root, defaults: defaults)
        XCTAssertEqual(reopened.turns, [turn])
        XCTAssertTrue(try ConfirmationJournal(file: root.appendingPathComponent("device-operation-history").appendingPathComponent(filename)).records()[0].reported)
    }
}
