import Foundation
import SwiftData

/// What goes through the household zone: shared things (with who can see them and who recorded them)
/// and the people in the household. Personal things and everything else stay in this device's own sync.
@MainActor final class HouseholdSyncData: SyncLocalData {
    struct SharedInventory: Codable {
        var inventory: ButlerSyncData.Inventory
        var sharing: ItemSharing
    }

    let base: ButlerSyncData
    let store: HouseholdStore

    init(base: ButlerSyncData, store: HouseholdStore) {
        self.base = base
        self.store = store
    }

    nonisolated deinit {}

    func snapshot() throws -> [SyncRecord.Key: Data] {
        var result: [SyncRecord.Key: Data] = [:]
        let shared = store.householdProducts(container: base.container)
        for (id, inventory) in try base.inventories(where: { shared.contains($0) }) {
            guard let sharing = store.sharing[id] else { continue }
            result[.init(kind: .inventory, id: id)] = try SyncRecord.encode(SharedInventory(inventory: inventory, sharing: sharing))
        }
        for member in store.members { result[.init(kind: .member, id: member.id)] = try SyncRecord.encode(member) }
        return result
    }

    func replace(_ key: SyncRecord.Key, expected: Data?, with payload: Data?) throws {
        guard try snapshot()[key] == expected else { throw SyncFailure("本机资料刚发生变化，未覆盖。") }
        switch key.kind {
        case .inventory:
            if let payload {
                let value = try JSONDecoder().decode(SharedInventory.self, from: payload)
                guard value.inventory.product.id == key.id, value.sharing.scope == .household else {
                    throw SyncFailure("家庭库存记录无效，未修改本机。")
                }
                // Record who can see it first, so this device's own sync already leaves it alone.
                store.setSharing(value.sharing, for: key.id)
                try base.replaceInventory(key.id, value.inventory, revision: try base.nextRevision())
            } else {
                // Someone made it personal or threw it away: it leaves this phone.
                try base.replaceInventory(key.id, nil, revision: try base.nextRevision())
                store.setSharing(nil, for: key.id)
            }
        case .member:
            if let payload {
                let member = try JSONDecoder().decode(HouseholdMember.self, from: payload)
                guard member.id == key.id, !member.name.isEmpty, member.name.count <= 40 else {
                    throw SyncFailure("家庭成员记录无效。")
                }
                store.upsert(member)
            } else {
                store.removeMember(key.id)
            }
        default:
            throw SyncFailure("家庭同步只包含共享的物品和成员。")
        }
        WidgetSnapshotPublisher.shared.refresh()
        NotificationCenter.default.post(name: .init("butlerBriefSourcesChanged"), object: nil)
    }
}
