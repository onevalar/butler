import CloudKit
import Foundation
import Observation
import SwiftData
import UIKit

/// Creating, joining, syncing and leaving the household. The household's things live in one CloudKit zone
/// in the creator's iCloud, shared with the family through a zone-wide `CKShare`.
@MainActor @Observable
final class HouseholdService {
    static let shared = HouseholdService()

    struct Summary: Equatable {
        var shared: Int
        var personal: [String]
        var merged: Int = 0
    }

    private(set) var busy = false
    private(set) var lastSync: Date?
    var notice: String?
    /// Shown once after joining or creating: what was shared and what stayed personal.
    var summary: Summary?
    /// Just joined: ask for the name the family uses for this person.
    var needsName = false

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var base: ButlerSyncData?
    @ObservationIgnored private var root: URL?
    @ObservationIgnored private(set) var syncStore: SyncStore?
    @ObservationIgnored private var pendingInvite: CKShare.Metadata?
    @ObservationIgnored private lazy var cloud = CKContainer(identifier: CloudKitSyncTransport.containerID)

    var store: HouseholdStore { .shared }

    private init() {}

    func configure(container: ModelContainer, base: ButlerSyncData, root: URL) {
        guard self.container == nil else { return }
        self.container = container
        self.base = base
        self.root = root
        Self.wire(base, store)
        if let state = store.state {
            makeSyncStore(state)
            base.tasks.rescheduleAll()
            Task { await subscribe() }
        }
        if let invite = pendingInvite {
            pendingInvite = nil
            Task { await accept(invite) }
        }
    }

    private func makeSyncStore(_ state: HouseholdState) {
        guard let base, let root else { return }
        syncStore = SyncStore(file: root.appendingPathComponent("household-\(state.id.uuidString).json"),
                              local: HouseholdSyncData(base: base, store: store),
                              transport: CloudKitSyncTransport(household: state), kinds: Self.kinds)
    }

    static let kinds: Set<SyncRecord.Kind> = [.inventory, .member, .task]

    /// Connects this device's own data to the household: which things and tasks travel through the household,
    /// who is acting, and which tasks this phone reminds about.
    static func wire(_ base: ButlerSyncData, _ store: HouseholdStore) {
        base.householdProducts = { [weak base, weak store] in
            guard let base, let store else { return [] }
            return store.householdProducts(container: base.container)
        }
        base.householdTasks = { [weak base, weak store] in
            guard let base, store?.state != nil else { return [] }
            return Set(base.tasks.reminders.filter { $0.sharing?.isShared == true }.map(\.id))
        }
        base.tasks.actor = { [weak store] in store?.state?.me }
        base.tasks.remindsHere = { [weak store] task in
            if let me = store?.state?.me, let sharing = task.sharing, sharing.isShared { return sharing.reminded.contains(me) }
            return task.syncReceived != true
        }
    }

    private var zoneID: CKRecordZone.ID? {
        store.state.map { CKRecordZone.ID(zoneName: $0.zoneName, ownerName: $0.zoneOwner) }
    }

    private func myMemberID() async throws -> UUID {
        guard try await cloud.accountStatus() == .available else {
            throw SyncFailure("请先在 iPhone 的“设置”里登录 iCloud，再建立或加入家庭。")
        }
        return HouseholdMember.id(forUser: try await cloud.userRecordID().recordName)
    }

    // MARK: Create

    /// Creates the household in this person's iCloud and sorts what is already on the phone.
    func create(name: String, myName: String) async throws -> Summary {
        guard let container, store.state == nil else { throw SyncFailure("已经在一个家庭里了。") }
        busy = true; defer { busy = false }
        let me = try await myMemberID()
        try backUpBeforeSharing(container)
        let id = UUID()
        let zone = CKRecordZone(zoneName: "ButlerHouseholdV1-\(id.uuidString)")
        _ = try await cloud.privateCloudDatabase.save(zone)
        let share = CKShare(recordZoneID: zone.zoneID)
        share[CKShare.SystemFieldKey.title] = name as CKRecordValue
        share.publicPermission = .none
        _ = try await cloud.privateCloudDatabase.modifyRecords(saving: [share], deleting: [])
        let state = HouseholdState(id: id, name: name, role: .owner, zoneName: zone.zoneID.zoneName,
                                   zoneOwner: CKCurrentUserDefaultName, me: me, joinedAt: .now)
        store.begin(state, me: HouseholdMember(id: me, name: myName, isOwner: true, joinedAt: .now))
        let summary = sortedSummary(container)
        self.summary = summary
        makeSyncStore(state)
        try await syncStore?.setEnabled(true)
        await sync()
        await subscribe()
        return summary
    }

    /// The share for the system's invite sheet (owner only).
    func share() async throws -> CKShare {
        guard store.isOwner, let zoneID else { throw SyncFailure("只有创建家庭的人可以邀请家人。") }
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        guard let share = try await cloud.privateCloudDatabase.record(for: id) as? CKShare else {
            throw SyncFailure("家庭邀请没有找到，请稍后再试。")
        }
        return share
    }

    var cloudContainer: CKContainer { cloud }

    // MARK: Join

    /// Called when this person opens an invitation link.
    func accept(_ metadata: CKShare.Metadata) async {
        guard let container else { pendingInvite = metadata; return }
        guard store.state == nil else {
            notice = "这台手机已经在一个家庭里了。要加入新的家庭，请先退出当前家庭。"
            return
        }
        busy = true; defer { busy = false }
        do {
            let me = try await myMemberID()
            try backUpBeforeSharing(container)
            _ = try await cloud.accept(metadata)
            let zone = metadata.share.recordID.zoneID
            let name = (metadata.share[CKShare.SystemFieldKey.title] as? String) ?? "我们家"
            let id = UUID(uuidString: String(zone.zoneName.dropFirst("ButlerHouseholdV1-".count))) ?? UUID()
            let state = HouseholdState(id: id, name: name, role: .member, zoneName: zone.zoneName,
                                       zoneOwner: zone.ownerName, me: me, joinedAt: .now)
            let given = metadata.share.currentUserParticipant?.userIdentity.nameComponents
                .map { PersonNameComponentsFormatter.localizedString(from: $0, style: .short) }
            // What was already on this phone waits until the household's things have arrived, then is merged.
            let existing = Set(((try? ModelContext(container).fetch(FetchDescriptor<CatalogProduct>())) ?? []).map(\.id))
            store.begin(state, me: HouseholdMember(id: me, name: (given?.isEmpty == false ? given! : "家人"),
                                                   isOwner: false, joinedAt: .now), staging: existing)
            needsName = true
            makeSyncStore(state)
            try await syncStore?.setEnabled(true)
            await sync()
            summary = finishJoining(container)
            await sync()
            await subscribe()
        } catch {
            notice = "没能加入家庭：\(error.localizedDescription)"
            ChatDiagnostics.log("household accept failed: \(error)")
        }
    }

    /// After the first sync: the same thing recorded by both is merged into the household's; the rest is sorted.
    private func finishJoining(_ container: ModelContainer) -> Summary {
        let context = ModelContext(container)
        let products = (try? context.fetch(FetchDescriptor<CatalogProduct>())) ?? []
        let lots = (try? context.fetch(FetchDescriptor<InventoryLot>())) ?? []
        let templates = (try? context.fetch(FetchDescriptor<PersonalProductTemplate>())) ?? []
        let staged = store.staged
        let household = products.filter { !staged.contains($0.id) && store.sharing[$0.id]?.scope == .household }
        var merged = 0
        for product in products where staged.contains(product.id) {
            let key = product.canonicalName.trimmingCharacters(in: .whitespaces).lowercased()
            guard let match = household.first(where: {
                $0.canonicalName.trimmingCharacters(in: .whitespaces).lowercased() == key && $0.brand == product.brand
            }) else { continue }
            for lot in lots where lot.productID == product.id { lot.productID = match.id }
            for template in templates where template.productID == product.id { context.delete(template) }
            context.delete(product)
            merged += 1
        }
        try? context.save()
        store.unstage(staged)
        var summary = sortedSummary(container)
        summary.merged = merged
        return summary
    }

    /// Sorts anything not yet sorted and reports the result for the one summary card.
    private func sortedSummary(_ container: ModelContainer) -> Summary {
        store.classifyNew(container: container)
        let products = (try? ModelContext(container).fetch(FetchDescriptor<CatalogProduct>())) ?? []
        let personal = products.filter { store.sharing[$0.id]?.scope == .personal }.map(\.canonicalName)
        return Summary(shared: products.count - personal.count, personal: personal)
    }

    private func backUpBeforeSharing(_ container: ModelContainer) throws {
        guard let root else { return }
        let backup = try BackupService.makeBackup(container: container)
        let file = root.appendingPathComponent("before-household-\(Int(Date.now.timeIntervalSince1970)).json")
        try BackupService.encode(backup).write(to: file, options: .atomic)
    }

    // MARK: Day to day

    func rename(me name: String) {
        guard var me = store.me else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 20 else { return }
        me.name = trimmed
        store.upsert(me)
        needsName = false
        Task { await sync() }
    }

    /// Who can see one thing. Changing it moves the thing between the household and this person's own sync.
    func setScope(_ scope: ItemSharing.Scope, for product: UUID, hiddenFrom: Set<UUID> = []) {
        guard let state = store.state else { return }
        var entry = store.sharing[product] ?? ItemSharing(scope: scope, recordedBy: state.me)
        entry.scope = scope
        entry.hiddenFrom = scope == .household ? hiddenFrom : []
        entry.changedBy = state.me
        store.setSharing(entry, for: product)
        Task { await sync() }
    }

    func sync() async {
        guard let syncStore, syncStore.enabled, !syncStore.busy else { return }
        if store.state?.role == .member, await householdEnded() { return }
        do {
            try await syncStore.synchronize()
            lastSync = .now
        } catch {
            ChatDiagnostics.log("household sync: \(error.localizedDescription)")
        }
    }

    /// A member whose household was dissolved, or who was removed, keeps everything as their own.
    private func householdEnded() async -> Bool {
        guard let zoneID else { return false }
        do {
            let zones = try await cloud.sharedCloudDatabase.allRecordZones()
            guard !zones.contains(where: { $0.zoneID == zoneID }) else { return false }
        } catch { return false }
        notice = "你已不在「\(store.state?.name ?? "家庭")」里了，家里的东西作为你自己的保留在这台手机上。"
        if let state = store.state { await unsubscribe(state) }
        endLocally()
        return true
    }

    // MARK: Push

    private var subscriptionID: String? { store.state.map { "household-\($0.id.uuidString)" } }

    /// Asks iCloud to wake this phone when anyone changes the household, once per household.
    private func subscribe() async {
        guard let state = store.state, let zoneID, let id = subscriptionID else { return }
        UIApplication.shared.registerForRemoteNotifications()
        let key = "household.subscribed.\(id)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        do {
            if state.role == .owner {
                let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: id)
                subscription.notificationInfo = info
                _ = try await cloud.privateCloudDatabase.modifySubscriptions(saving: [subscription], deleting: [])
            } else {
                let subscription = CKDatabaseSubscription(subscriptionID: id)
                subscription.notificationInfo = info
                _ = try await cloud.sharedCloudDatabase.modifySubscriptions(saving: [subscription], deleting: [])
            }
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            ChatDiagnostics.log("household subscribe failed: \(error)")
        }
    }

    private func unsubscribe(_ state: HouseholdState) async {
        let id = "household-\(state.id.uuidString)"
        UserDefaults.standard.removeObject(forKey: "household.subscribed.\(id)")
        let database = state.role == .owner ? cloud.privateCloudDatabase : cloud.sharedCloudDatabase
        _ = try? await database.modifySubscriptions(saving: [], deleting: [id])
    }

    // MARK: Leave

    /// A member leaves; the owner dissolves. Either way everyone keeps a copy as their own.
    func leave() async throws {
        guard let state = store.state, let zoneID else { return }
        busy = true; defer { busy = false }
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        if state.role == .owner {
            _ = try await cloud.privateCloudDatabase.modifyRecords(saving: [], deleting: [shareID])
        } else {
            _ = try await cloud.sharedCloudDatabase.modifyRecords(saving: [], deleting: [shareID])
        }
        await unsubscribe(state)
        endLocally()
    }

    private func endLocally() {
        try? syncStore?.pause()
        if let root, let state = store.state {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("household-\(state.id.uuidString).json"))
        }
        syncStore = nil
        store.end()
        // Tasks this phone was not reminding about stay as records; what it reminds about is decided again.
        base?.tasks.rescheduleAll()
    }
}
