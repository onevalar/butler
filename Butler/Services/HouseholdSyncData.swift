import Foundation
import SwiftData
import UserNotifications

/// What goes through the household zone: shared things (with who can see them and who recorded them)
/// and the people in the household. Personal things and everything else stay in this device's own sync.
@MainActor final class HouseholdSyncData: SyncLocalData {
    struct SharedInventory: Codable {
        var inventory: ButlerSyncData.Inventory
        var sharing: ItemSharing
    }

    let base: ButlerSyncData
    let store: HouseholdStore
    /// Tells this person what others did that concerns them: a task given to them, one they made that
    /// someone else finished. Posted at once, not at the task's time.
    var announce: (_ title: String, _ body: String, _ task: UUID) -> Void = HouseholdSyncData.post

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
        if store.state != nil {
            for task in try base.tasks.tasksForSync() where task.sharing?.isShared == true {
                result[.init(kind: .task, id: task.id)] = try SyncRecord.encode(ButlerSyncData.portable(task))
            }
            for (id, task) in store.hiddenTasks { result[.init(kind: .task, id: id)] = try SyncRecord.encode(task) }
        }
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
        case .task:
            let old = base.tasks.reminder(id: key.id)
            if let payload {
                var value = try JSONDecoder().decode(TimedReminder.self, from: payload)
                guard value.id == key.id, let sharing = value.sharing, sharing.isShared else {
                    throw SyncFailure("家庭任务记录无效，未修改本机。")
                }
                if let me = store.state?.me, !sharing.canSee(me) {
                    // Not for this person: kept aside, out of lists, reminders and the model.
                    if old != nil { try base.tasks.receiveSyncedTask(key.id, value: nil) }
                    store.setHiddenTask(value, id: key.id)
                } else {
                    if store.hiddenTasks[key.id] != nil { store.setHiddenTask(nil, id: key.id) }
                    value.revision = try base.nextRevision()
                    try base.tasks.receiveSyncedTask(key.id, value: value)
                    tell(old: old, new: value)
                }
            } else {
                // Made personal by its creator, or deleted.
                if old != nil { try base.tasks.receiveSyncedTask(key.id, value: nil) }
                if store.hiddenTasks[key.id] != nil { store.setHiddenTask(nil, id: key.id) }
            }
        default:
            throw SyncFailure("家庭同步只包含共享的物品、任务和成员。")
        }
        WidgetSnapshotPublisher.shared.refresh()
        NotificationCenter.default.post(name: .init("butlerBriefSourcesChanged"), object: nil)
    }

    /// A task that now reminds this person and was given by someone else; one this person made, finished by someone else.
    private func tell(old: TimedReminder?, new: TimedReminder) {
        guard let me = store.state?.me, let sharing = new.sharing else { return }
        let names = store.names
        let remindedBefore = old.map { $0.status == .active && $0.sharing?.reminded.contains(me) == true } ?? false
        let by = new.activity.last?.by ?? sharing.createdBy
        if new.status == .active, sharing.reminded.contains(me), !remindedBefore, by != me {
            announce("\(names.name(by) ?? "家人")交给你一件事", "\(new.text) · \(new.whenLabel)", new.id)
        }
        if new.status == .completed, old?.status != .completed, sharing.createdBy == me,
           let done = new.activity.last(where: { $0.kind == "completed" })?.by, done != me {
            announce("\(names.name(done) ?? "家人")完成了", new.text, new.id)
        }
    }

    static func post(_ title: String, _ body: String, _ task: UUID) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["reminderID": task.uuidString]
        let request = UNNotificationRequest(identifier: "butler.household.\(task.uuidString).\(UUID().uuidString)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
