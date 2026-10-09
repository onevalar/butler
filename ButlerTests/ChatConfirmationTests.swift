import Foundation
import XCTest
@testable import Butler

final class ChatConfirmationTests: XCTestCase {
    func testPresentationRemovesRepeatedTitleButPreservesDistinctEvidence() {
        XCTAssertNil(ConfirmationPresentation.detail("✓ 新增 水 ×4 箱", title: "新增 水 ×4 箱"))
        XCTAssertNil(ConfirmationPresentation.detail("新增 水 ×4 箱", title: "新增 水 ×4 箱"))
        XCTAssertEqual(ConfirmationPresentation.detail("✗ 修改水数量：保存失败，请重试", title: "修改水数量"), "保存失败，请重试")
        XCTAssertEqual(ConfirmationPresentation.detail("已保存，但系统通知未授权", title: "新增提醒"), "已保存，但系统通知未授权")
        XCTAssertEqual(ConfirmationPresentation.detail("水数量：已改为5瓶", title: "水"), "水数量：已改为5瓶")
    }

    @MainActor func testLateResultsUpdateExecutionIdentityAndEachOriginalRequestNotNewestTurn() async throws {
        let a = ChatTurn(question: "买纸巾"), b = ChatTurn(question: "记偏好")
        let execution = ChatTurn(question: "确认操作")
        let newest = ChatTurn(question: "另一个问题", answer: "新回复", receipts: ["不许改变"])
        let resultA = ConfirmationResult(proposalID: UUID(), requestTurnID: a.id, title: "纸巾", state: .succeeded,
            message: "已保存纸巾", relatedScopeKeys: ["lot:paper"])
        let resultB = ConfirmationResult(proposalID: UUID(), requestTurnID: b.id, title: "偏好", state: .failed, message: "保存失败")
        var turns = [a, b, execution, newest]
        ChatTurn.updateConfirmation(execution.id, results: [resultB, resultA], in: &turns)
        XCTAssertEqual(turns[0].relatedScopeKeys, ["lot:paper"])
        XCTAssertNil(turns[1].relatedScopeKeys)
        XCTAssertEqual(turns[2].receipts, ["保存失败", "已保存纸巾"])
        XCTAssertEqual(turns[2].confirmationResults?.map(\.requestTurnID), [b.id, a.id])
        XCTAssertEqual(turns[3], newest)
        let once = turns
        ChatTurn.updateConfirmation(execution.id, results: [resultB, resultA], in: &turns)
        XCTAssertEqual(turns, once, "Repeated evidence must not duplicate receipts")
    }

    @MainActor func testMissingAndLegacyOwnersNeverAttachToNewestRequest() async throws {
        let newest = ChatTurn(question: "不是来源")
        let execution = ChatTurn(question: "确认操作")
        let results = [nil, UUID()].map { ConfirmationResult(proposalID: UUID(), requestTurnID: $0,
            title: "旧操作", state: .needsVerification, message: "不能猜测归属", relatedScopeKeys: ["task:old"]) }
        var turns = [execution, newest]
        ChatTurn.updateConfirmation(execution.id, results: results, in: &turns)
        XCTAssertEqual(turns[1], newest)
        let before = turns
        ChatTurn.updateConfirmation(UUID(), results: results, in: &turns)
        XCTAssertEqual(turns, before)
    }

    @MainActor func testLocalEvidenceRoundTripsButNeverExpandsSyncAllowList() async throws {
        let result = ConfirmationResult(proposalID: UUID(), requestTurnID: UUID(), title: "控制", state: .needsVerification, message: "请核对设备")
        let original = ChatTurn(question: "确认操作", receipts: [result.message], confirmationIDs: [UUID()],
            confirmationResults: [result], confirmationFinished: true, replyState: .completed, localHealthResults: ["健康数值不可序列化"])
        let local = try JSONDecoder().decode(ChatTurn.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(local.confirmationResults, [result])
        XCTAssertEqual(local.confirmationFinished, true)
        XCTAssertTrue(local.localHealthResults.isEmpty)
        let encoded = try JSONEncoder().encode(SyncedChatTurn(scope: .general, turn: original))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for forbidden in ["confirmationResults", "confirmationFinished", "confirmationIDs", "replyState", "localHealthResults"] {
            XCTAssertNil(payload[forbidden])
        }
        let remote = try JSONDecoder().decode(SyncedChatTurn.self, from: encoded).turn
        XCTAssertNil(remote.confirmationResults)
        XCTAssertNil(remote.replyState)
        XCTAssertEqual(remote.receipts, ["请核对设备"])
    }

    @MainActor func testLegacyTurnWithoutNewFieldsDecodesWithoutInventingState() async throws {
        let payload: [String: Any] = ["id": UUID().uuidString, "question": "确认", "answer": "", "failed": false,
            "receipts": ["✓ 历史说明"], "date": 14]
        let turn = try JSONDecoder().decode(ChatTurn.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertNil(turn.confirmationResults)
        XCTAssertNil(turn.replyState)
        XCTAssertNil(turn.confirmationFinished)
        XCTAssertNil(turn.partialReply)
        XCTAssertEqual(turn.receipts, ["✓ 历史说明"])
    }
}
