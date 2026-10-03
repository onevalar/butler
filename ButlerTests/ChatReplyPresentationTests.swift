import Foundation
import XCTest
@testable import Butler

final class ChatReplyPresentationTests: XCTestCase {
    @MainActor func testMarkdownRemainsIntactAcrossStreamingStopHistoryAndSync() async throws {
        let partial = "## 建议\n\n- **牛奶🥛**\n\n```swift\nlet count = 3"
        var turn = ChatTurn(question: "怎么安排", replyState: .answering)
        let progress = ChatReplyProgress()
        progress.begin(turn.id)
        progress.receive(partial)
        XCTAssertEqual(turn.displayedReply(using: progress), partial)
        turn.replyState = .stopped
        turn.partialReply = partial
        turn.answer = "本轮未完成"
        progress.finish()
        let restored = try JSONDecoder().decode(ChatTurn.self, from: JSONEncoder().encode(turn))
        XCTAssertEqual(restored.displayedReply(using: progress), partial, "Do not close fences or strip Markdown in storage")

        let completed = partial + "\n```\n\n[说明](https://example.com)"
        turn.partialReply = nil
        turn.replyState = .completed
        turn.answer = completed
        XCTAssertEqual(turn.displayedReply(using: progress), completed)
        let synced = try JSONDecoder().decode(SyncedChatTurn.self,
            from: JSONEncoder().encode(SyncedChatTurn(scope: .general, turn: turn)))
        XCTAssertEqual(synced.answer, completed)
    }

    @MainActor func testRetryAndToolPassRetainLabeledTextUntilReplacementNotAppend() async {
        let progress = ChatReplyProgress()
        progress.begin(UUID())
        progress.receive("")
        XCTAssertEqual(progress.text, "")
        XCTAssertFalse(progress.isPreviousPass)
        progress.receive("先看看冰箱\n还有🥛")
        XCTAssertFalse(progress.isPreviousPass)
        progress.prepareNextPass()
        XCTAssertEqual(progress.text, "先看看冰箱\n还有🥛")
        XCTAssertTrue(progress.isPreviousPass)
        progress.receive("") // A transport retry can clear more than once.
        progress.receive("")
        XCTAssertEqual(progress.text, "先看看冰箱\n还有🥛")
        XCTAssertTrue(progress.isPreviousPass)
        progress.receive("只剩")
        XCTAssertEqual(progress.text, "只剩")
        XCTAssertFalse(progress.isPreviousPass)
        progress.receive("只剩一盒，日期待核对。")
        XCTAssertEqual(progress.text, "只剩一盒，日期待核对。")
    }

    @MainActor func testProgressCannotLeakIntoAnotherRequestOrSurviveFinish() async {
        let progress = ChatReplyProgress()
        progress.receive("无主回调")
        XCTAssertEqual(progress.text, "")
        let first = UUID(), second = UUID()
        progress.begin(first)
        progress.receive("第一条的文字")
        progress.prepareNextPass()
        progress.begin(second)
        XCTAssertEqual(progress.turnID, second)
        XCTAssertEqual(progress.text, "")
        XCTAssertFalse(progress.isPreviousPass)
        progress.receive("第二条的文字")
        progress.finish()
        progress.receive("已结束后的回调")
        XCTAssertNil(progress.turnID)
        XCTAssertEqual(progress.text, "")
        XCTAssertFalse(progress.isPreviousPass)
    }

    @MainActor func testOnlyMatchingAnsweringTurnUsesProgressAndFinalAnswerReplacesIt() async {
        let older = ChatTurn(question: "旧问题", answer: "旧答案")
        var current = ChatTurn(question: "新问题", replyState: .answering)
        let other = ChatTurn(question: "另一会话", answer: "另一会话的文字", replyState: .answering)
        let progress = ChatReplyProgress()
        progress.begin(current.id)
        progress.receive("正在查询，不是结论")
        XCTAssertEqual(current.displayedReply(using: progress), "正在查询，不是结论")
        XCTAssertEqual(older.displayedReply(using: progress), "旧答案")
        XCTAssertEqual(other.displayedReply(using: progress), "另一会话的文字")
        let id = current.id
        current.answer = "查到了：青菜两袋。"
        current.replyState = .completed
        // Finishing may not have cleared the transient display yet.
        XCTAssertEqual(current.displayedReply(using: progress), "查到了：青菜两袋。")
        progress.finish()
        XCTAssertEqual(current.id, id)
        XCTAssertEqual(current.displayedReply(using: progress), "查到了：青菜两袋。")
    }

    @MainActor func testStoppedAndFailedPartialTextRoundTripsLocallyButIsNotASyncedAnswer() async throws {
        for state in [ChatTurn.ReplyState.stopped, .failed] {
            let turn = ChatTurn(question: "查库存", answer: "本轮未完成", failed: true,
                replyState: state, partialReply: "我先查一下冷藏区…")
            let restored = try JSONDecoder().decode(ChatTurn.self, from: JSONEncoder().encode(turn))
            XCTAssertEqual(restored, turn)
            XCTAssertEqual(restored.displayedReply(using: ChatReplyProgress()), "我先查一下冷藏区…")
            XCTAssertEqual(restored.answer, "本轮未完成")
            XCTAssertTrue(restored.receipts.isEmpty)
            let data = try JSONEncoder().encode(SyncedChatTurn(scope: .general, turn: restored))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(payload["partialReply"])
            XCTAssertEqual(payload["answer"] as? String, "本轮未完成")
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("冷藏区"))
        }
    }

    @MainActor func testReceiptMatchingKeepsWarningsDuplicatesAndHealthSeparate() async {
        let results = ["重复回执", "重复回执", "尚无文字行"].map {
            ConfirmationResult(proposalID: UUID(), requestTurnID: nil, title: "操作", state: .reported, message: $0)
        }
        let turn = ChatTurn(question: "确认", receipts: ["✗ 通知未开启", "重复回执", "重复回执", "额外说明", "重复回执"],
            confirmationResults: results, localHealthResults: ["重复回执"])
        XCTAssertEqual(turn.additionalReceipts, ["✗ 通知未开启", "额外说明", "重复回执"])
        XCTAssertEqual(turn.localHealthResults, ["重复回执"])
        let legacy = ChatTurn(question: "旧记录", receipts: ["✓ 原始回执", "✗ 原始警告"])
        XCTAssertEqual(legacy.additionalReceipts, ["✓ 原始回执", "✗ 原始警告"])
    }

    @MainActor func testUpdatingOneResultPreservesSupplementalWarningWithoutRepeatingOldResult() async {
        var result = ConfirmationResult(proposalID: UUID(), requestTurnID: nil, title: "文件夹",
            state: .awaitingUser, message: "等你选择")
        let execution = ChatTurn(question: "确认操作", receipts: ["✗ 提醒没有安排好", "等你选择"],
            confirmationResults: [result], localHealthResults: ["本机健康内容"])
        var turns = [execution]
        result.state = .succeeded
        result.message = "授权已保存"
        ChatTurn.updateConfirmation(execution.id, results: [result], in: &turns)
        XCTAssertEqual(turns[0].receipts, ["授权已保存", "✗ 提醒没有安排好"])
        XCTAssertEqual(turns[0].additionalReceipts, ["✗ 提醒没有安排好"])
        XCTAssertEqual(turns[0].localHealthResults, ["本机健康内容"])
        let updated = turns
        ChatTurn.updateConfirmation(execution.id, results: [result], in: &turns)
        XCTAssertEqual(turns, updated)
    }
}
