import CloudKit
import Foundation

/// Validate the invitation before accepting or binding any local household state.
enum HouseholdInvitationIdentity {
    static func householdID(container: String, zoneName: String) throws -> UUID {
        let prefix = "ButlerHouseholdV1-"
        guard container == CloudKitSyncTransport.containerID, zoneName.hasPrefix(prefix),
              let id = UUID(uuidString: String(zoneName.dropFirst(prefix.count))) else {
            throw SyncFailure("这不是有效的小当家家庭邀请，请让家人重新发送邀请。")
        }
        return id
    }
}

@MainActor enum HouseholdJoinRecovery {
    /// The initial pull must succeed before staged local items can be merged/published.
    /// A durable joining flag makes an interrupted enable or download resumable after relaunch.
    static func synchronize(store: HouseholdStore, sync: SyncStore, finish: () throws -> Void) async throws {
        if store.joining, !sync.enabled { try await sync.setEnabled(true) }
        try await sync.synchronize()
        if store.joining {
            try finish()
            store.completeJoining()
            try await sync.synchronize()
        }
    }
}
