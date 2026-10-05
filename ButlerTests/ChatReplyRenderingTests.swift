import SwiftUI
import UIKit
import XCTest
@testable import Butler

/// Native layout regression checks. These require an iOS simulator, not the
/// portable chat script; attachments also support reviewing spinner alignment.
@MainActor
final class ChatReplyRenderingTests: XCTestCase {
    func testWaitingBubbleContainsOnlyOneStatusRow() throws {
        let turn = ChatTurn(question: "记录车次", replyState: .answering)
        let progress = ChatReplyProgress()
        progress.begin(turn.id)
        let stage = "正在整理结果…"
        let bubble = try render(ChatReplyBubble(turn: turn, progress: progress, workingStage: stage))
        // 320 minus trailing spacer (40), HStack gap (8), and padding (28).
        let status = try render(ChatWorkingIndicator(label: stage), width: 244)
        XCTAssertEqual(bubble.size.height, status.size.height + 18, accuracy: 1,
                       "Waiting must not add placeholder Markdown or a second status caption")
    }

    func testStreamingAndToolPassAddOnlyOneStatusToTheSameBody() throws {
        var turn = ChatTurn(question: "记录车次", replyState: .answering)
        let progress = ChatReplyProgress()
        progress.begin(turn.id)
        progress.receive("先核对车次。")
        let streaming = try render(ChatReplyBubble(turn: turn, progress: progress, workingStage: "正在理解你的安排…"))
        progress.prepareNextPass()
        let toolPass = try render(ChatReplyBubble(turn: turn, progress: progress, workingStage: "正在查看任务和提醒…"))
        turn.answer = "先核对车次。"
        turn.replyState = .completed
        // Completed state must win even before transient progress is cleared.
        let completed = try render(ChatReplyBubble(turn: turn, progress: progress, workingStage: "正在查看任务和提醒…"))
        let streamingStatus = try render(ChatWorkingIndicator(label: "正在回复…"), width: 244)
        let toolStatus = try render(ChatWorkingIndicator(label: "正在查看任务和提醒… · 上文待更新"), width: 244)
        XCTAssertEqual(streaming.size.height - completed.size.height, streamingStatus.size.height + 8, accuracy: 1)
        XCTAssertEqual(toolPass.size.height - completed.size.height, toolStatus.size.height + 8, accuracy: 1)
    }

    func testReplyStatesInBothThemesAndLargeText() throws {
        for scheme in [ColorScheme.light, .dark] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                for state in ["等待", "输出", "工具处理", "重试", "完成", "停止", "失败"] {
                    var turn = ChatTurn(question: "记录车次", replyState: .answering)
                    let progress = ChatReplyProgress()
                    progress.begin(turn.id)
                    if state != "等待" { progress.receive("先核对车次，再准备需要确认的事项。") }
                    if state == "工具处理" { progress.prepareNextPass() }
                    if state == "重试" { progress.receive("") }
                    if state == "完成" {
                        turn.replyState = .completed
                        turn.answer = "已整理好车次，请在下方确认。"
                        progress.finish()
                    }
                    if state == "停止" || state == "失败" {
                        turn.replyState = state == "停止" ? .stopped : .failed
                        turn.failed = true
                        turn.partialReply = progress.text
                        turn.answer = state == "停止" ? "已停止。" : "连接中断，请稍后重试。"
                        progress.finish()
                    }
                    let image = try render(
                        ChatReplyBubble(turn: turn, progress: progress, workingStage: "正在整理结果…"),
                        scheme: scheme, size: size)
                    XCTAssertEqual(image.size.width, 320, accuracy: 0.5)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "回复状态 · \(state) · \(scheme) · \(size)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    private func render<Content: View>(_ content: Content, width: CGFloat = 320,
                                      scheme: ColorScheme = .light,
                                      size: DynamicTypeSize = .large) throws -> UIImage {
        let renderer = ImageRenderer(content: content
            .frame(width: width)
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, size)
            .background(scheme == .dark ? Color.black : Color.white))
        renderer.scale = 2
        return try XCTUnwrap(renderer.uiImage)
    }
}
