import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Keep high-frequency text observation inside the bubble, not in the history,
/// photo decoding, inventory cards, or composer builders above.
struct ChatReplyBubble: View {
    let turn: ChatTurn
    let progress: ChatReplyProgress
    let workingStage: String

    var body: some View {
        let replying = turn.replyState == .answering && progress.turnID == turn.id
        let reply = turn.displayedReply(using: progress)
        if replying || !reply.isEmpty {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    if !reply.isEmpty {
                        ChatMarkdownText(text: reply)
                            .foregroundStyle(turn.failed && turn.partialReply == nil ? Color.red : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if replying {
                        ChatWorkingIndicator(label: progress.status(stage: workingStage))
                    } else if turn.partialReply != nil {
                        Text("未完成的过程文字 · 不代表执行结果")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if turn.partialReply != nil, !turn.answer.isEmpty {
                        Text(turn.answer).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .glassCard(radius: 18)
                Spacer(minLength: 40)
            }
        }
    }
}

struct ChatWorkingIndicator: View {
    let label: String

    var body: some View {
        // A spinner has no text baseline. Center it with the label, including
        // when larger accessibility text wraps onto multiple lines.
        HStack(alignment: .center, spacing: 8) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            Text(label).fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline).foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
