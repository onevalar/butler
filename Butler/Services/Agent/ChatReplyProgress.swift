import Foundation
import Observation

/// Display-only text, owned by one request. Never an answer or execution receipt.
/// Transport callbacks replace the whole text; an empty callback starts a new
/// attempt, not a request to erase the previous passage while waiting.
/// Observe fields independently: a text delta must not invalidate turn-ID readers.
@MainActor @Observable
final class ChatReplyProgress {
    private(set) var turnID: UUID?
    private(set) var text = ""
    private(set) var isPreviousPass = false

    nonisolated deinit {}

    func begin(_ id: UUID) {
        turnID = id
        text = ""
        isPreviousPass = false
    }

    func receive(_ value: String) {
        guard turnID != nil else { return }
        guard !value.isEmpty else { prepareNextPass(); return }
        if text != value { text = value }
        if isPreviousPass { isPreviousPass = false }
    }

    func prepareNextPass() {
        if !text.isEmpty, !isPreviousPass { isPreviousPass = true }
    }

    func finish() {
        turnID = nil
        text = ""
        isPreviousPass = false
    }
}
