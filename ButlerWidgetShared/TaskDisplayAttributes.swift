import ActivityKit
import Foundation

/// Names, notes, inventory and conversation content never enter this ActivityKit payload.
struct TaskDisplayAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let deadline: Date
        let ended: Bool
    }
    let sessionID: UUID
    let taskID: UUID
}
