import Foundation

/// Async callbacks belong to one press only; a cancelled session can never affect its successor.
struct VoiceInteractionSession {
    private(set) var id: UUID?

    mutating func begin() -> UUID {
        let next = UUID()
        id = next
        return next
    }

    func contains(_ candidate: UUID) -> Bool { id == candidate }
    mutating func invalidate() { id = nil }
}
