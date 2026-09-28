import Foundation

/// Content chooses the button; send eligibility only chooses whether it is enabled.
struct ChatComposerPolicy {
    enum Action: Equatable {
        case voice, send, stopResponse, cancelPreparation, stopDictation, finishDictation
    }

    let draft: String
    let photoCount: Int
    let working: Bool
    let voicePhase: ChatDictationSession.Phase

    var hasContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photoCount > 0
    }

    var action: Action {
        switch voicePhase {
        case .preparing: return .cancelPreparation
        case .listening: return .stopDictation
        case .finishing: return .finishDictation
        case .idle: return working ? .stopResponse : hasContent ? .send : .voice
        }
    }

    var showsInlineMicrophone: Bool { hasContent && voicePhase == .idle }
    var canStartVoice: Bool { !working && voicePhase == .idle }
    var canEditText: Bool { voicePhase == .idle }
}

/// View-owned token keeps late recognition completions from touching a newer draft.
struct ChatDictationSession {
    enum Phase { case idle, preparing, listening, finishing }
    private(set) var phase: Phase = .idle
    private(set) var id: UUID?

    mutating func begin() -> UUID? {
        guard phase == .idle else { return nil }
        let id = UUID()
        self.id = id
        phase = .preparing
        return id
    }

    @discardableResult
    mutating func prepared(_ id: UUID, listening: Bool) -> Bool {
        guard self.id == id, phase == .preparing else { return false }
        if listening { phase = .listening } else { cancel() }
        return true
    }

    mutating func finish() -> UUID? {
        guard phase == .listening, let id else { return nil }
        phase = .finishing
        return id
    }

    func accepts(_ id: UUID) -> Bool { self.id == id && phase != .idle }

    @discardableResult
    mutating func end(_ id: UUID) -> Bool {
        guard accepts(id) else { return false }
        cancel()
        return true
    }

    mutating func cancel() {
        id = nil
        phase = .idle
    }
}
