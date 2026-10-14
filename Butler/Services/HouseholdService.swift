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
    private(set) var syncIssue: String?
    private(set) var needsSyncRecovery = false
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
    @ObservationIgnored private var inviteTask: Task<CKShare, Error>?
    @ObservationIgnored private var linkTask: Task<URL, Error>?
    @ObservationIgnored private var syncing = false
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
        guard let environment = Bundle.main.object(forInfoDictionaryKey: "ButlerCloudEnvironment") as? String,
              ["Development", "Production"].contains(environment) else {
            syncIssue = "当前安装的云端配置不完整，请更新小当家。"
            return
        }
        syncStore = SyncStore(file: root.appendingPathComponent("household-\(state.id.uuidString).json"),
                              local: HouseholdSyncData(base: base, store: store),
                              transport: CloudKitSyncTransport(household: state), kinds: Self.kinds, environment: environment)
        needsSyncRecovery = syncStore?.needsReconnect == true
        if needsSyncRecovery { syncIssue = "需要恢复家庭同步，本机资料已保留。" }
        ChatDiagnostics.log("household configured; environment=\(environment); recovery=\(needsSyncRecovery)")
    }

    static let kinds: Set<SyncRecord.Kind> = [.inventory, .member, .task, .rule]

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
        // What someone else set for this person waits for the end of their quiet hours; their own times are kept.
        base.tasks.deliveryDate = { [weak store] task, date in
            guard let store, let me = store.state?.me, let sharing = task.sharing, sharing.isShared,
                  sharing.createdBy != me else { return date }
            return store.deliveryDate(for: date)
        }
        base.tasks.extraAlerts = { [weak store] task, _ in
            guard let store, let me = store.state?.me, let sharing = task.sharing, sharing.isShared,
                  sharing.escalateTo == me, let after = sharing.escalateAfter,
                  task.repeats == .none, task.phases == nil else { return [] }
            let who = store.names.name(sharing.assignee ?? sharing.createdBy) ?? "家人"
            let at = store.deliveryDate(for: task.fireDate.addingTimeInterval(Double(after) * 60))
            return [(at, "\(who)还没处理：\(task.text)")]
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
        guard !busy, !syncing else { throw SyncFailure("正在处理家庭资料，请稍后重试。") }
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
        // A batch operation can succeed while an individual save fails. This single-record
        // API must return the saved share before we persist a successful local household.
        _ = try HouseholdSharePreparation.checked(try await cloud.privateCloudDatabase.save(share))
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
        guard store.isOwner, let state = store.state, let zoneID else {
            throw SyncFailure("只有创建家庭的人可以邀请家人。")
        }
        if let inviteTask { return try await inviteTask.value }
        let task = Task { @MainActor in
            do {
                guard try await self.myMemberID() == state.me else {
                    throw SyncFailure("当前 iCloud 账号与创建家庭时不同，请切回原账号后再邀请家人。")
                }
                let database = self.cloud.privateCloudDatabase
                let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
                let share = try await HouseholdSharePreparation.prepare(zoneID: zoneID, title: state.name,
                    fetch: { try await database.record(for: id) },
                    verifyZone: { _ = try await database.recordZone(for: zoneID) },
                    save: { try await database.save($0) })
                guard self.store.state?.id == state.id, try await self.myMemberID() == state.me else {
                    throw SyncFailure("家庭或 iCloud 账号已变化，请重新打开家庭页面后再试。")
                }
                return share
            } catch {
                ChatDiagnostics.log("household invite preparation failed: \(error)")
                throw SyncFailure(HouseholdSharePreparation.message(for: error))
            }
        }
        inviteTask = task
        defer { inviteTask = nil }
        return try await task.value
    }

    var cloudContainer: CKContainer { cloud }

    /// Both Copy and Share issue a real invitation for one new member.
    func invitationURL() async throws -> URL {
        if let linkTask { return try await linkTask.value }
        let task = Task { @MainActor in
            guard self.store.isOwner, let state = self.store.state else {
                throw SyncFailure("只有创建家庭的人可以邀请家人。")
            }
            guard !self.needsSyncRecovery else { throw SyncFailure("请先点“恢复家庭同步”，完成后就能邀请家人。") }
            guard !self.syncing, !self.busy else { throw SyncFailure("家庭资料正在同步，请稍后再邀请。") }
            await self.sync()
            guard self.syncIssue == nil, self.lastSync != nil, self.syncStore?.pendingCount == 0 else {
                throw SyncFailure("家庭资料还没有同步完成，请先在家庭页面完成同步。")
            }
            let link = try await HouseholdSharePreparation.invitation(fetch: { try await self.share() }, save: { share in
                guard self.store.state?.id == state.id, try await self.myMemberID() == state.me else {
                    throw SyncFailure("家庭或账号已变化，请重新打开家庭页面。")
                }
                return try HouseholdSharePreparation.checked(try await self.cloud.privateCloudDatabase.save(share))
            })
            guard self.store.state?.id == state.id, try await self.myMemberID() == state.me else {
                throw SyncFailure("家庭或账号已变化，未交付邀请链接。")
            }
            ChatDiagnostics.log("household single-use invitation ready")
            return link
        }
        linkTask = task
        defer { linkTask = nil }
        do { return try await task.value }
        catch {
            ChatDiagnostics.log("household invitation generation failed: \(ChatDiagnostics.describe(error))")
            throw SyncFailure(HouseholdSharePreparation.message(for: error))
        }
    }

    struct Recovery {
        let household: UUID
        let account: String
        let head: SyncCloudHead
    }

    func recoveryPreview() async throws -> Recovery {
        guard !busy, !syncing, let state = store.state, let syncStore,
              try await myMemberID() == state.me else { throw SyncFailure("请等待同步空闲，并确认仍使用原来的 iCloud 账号。") }
        let (account, head) = try await syncStore.reconnectPreview()
        return Recovery(household: state.id, account: account, head: head)
    }

    func recoverSync(_ preview: Recovery) async throws {
        guard !busy, !syncing, let state = store.state, state.id == preview.household,
              let container, let syncStore else {
            throw SyncFailure("家庭或账号已变化，请重新确认恢复。")
        }
        busy = true
        defer { busy = false }
        guard try await myMemberID() == state.me, store.state?.id == preview.household, !syncing else {
            throw SyncFailure("家庭或同步状态已变化，请重新确认恢复。")
        }
        try backUpBeforeSharing(container)
        try await syncStore.reconnect(account: preview.account, head: preview.head)
        lastSync = nil
        needsSyncRecovery = false
        await sync()
        guard syncIssue == nil, lastSync != nil else { throw SyncFailure(syncIssue ?? "同步尚未完成，请联网后重试。") }
        ChatDiagnostics.log("household recovery completed; pending=\(syncStore.pendingCount)")
    }

    func openInvitation(_ url: URL) async {
        do {
            let checked = try HouseholdShareLink.validated(url)
            let metadata = try await cloud.shareMetadata(for: checked)
            await accept(metadata)
        } catch {
            notice = "无法打开家庭邀请，请让家人重新生成一条邀请链接。"
            ChatDiagnostics.log("household invitation lookup failed: \(ChatDiagnostics.describe(error))")
        }
    }

    // MARK: Join

    /// Called when this person opens an invitation link.
    func accept(_ metadata: CKShare.Metadata) async {
        guard let container else { pendingInvite = metadata; return }
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let zone = metadata.share.recordID.zoneID
            let id = try HouseholdInvitationIdentity.householdID(container: metadata.containerIdentifier, zoneName: zone.zoneName)
            if let current = store.state {
                guard current.id == id, current.zoneName == zone.zoneName,
                      current.role == .owner || current.zoneOwner == zone.ownerName else {
                    throw SyncFailure("这台手机已经在另一个家庭里了。请先退出当前家庭，再加入。")
                }
                // Reopening the same link resumes a pending import instead of resetting local data.
                await sync()
                return
            }
            let me = try await myMemberID()
            try backUpBeforeSharing(container)
            _ = try await cloud.accept(metadata)
            guard try await myMemberID() == me else {
                throw SyncFailure("iCloud 账号在加入期间发生变化，请切回原账号后重新打开邀请。")
            }
            let name = (metadata.share[CKShare.SystemFieldKey.title] as? String) ?? "我们家"
            let state = HouseholdState(id: id, name: name, role: .member, zoneName: zone.zoneName,
                                       zoneOwner: zone.ownerName, me: me, joinedAt: .now)
            let given = metadata.share.currentUserParticipant?.userIdentity.nameComponents
                .map { PersonNameComponentsFormatter.localizedString(from: $0, style: .short) }
            // What was already on this phone waits until the household's things have arrived, then is merged.
            let existing = Set(try ModelContext(container).fetch(FetchDescriptor<CatalogProduct>()).map(\.id))
            store.begin(state, me: HouseholdMember(id: me, name: (given?.isEmpty == false ? given! : "家人"),
                                                   isOwner: false, joinedAt: .now), staging: existing, joining: true)
            needsName = true
            makeSyncStore(state)
            await sync()
            await subscribe()
        } catch {
            notice = "没能加入家庭：\(error.localizedDescription)"
            ChatDiagnostics.log("household accept failed: \(error)")
        }
    }

    /// After the first sync: the same thing recorded by both is merged into the household's; the rest is sorted.
    static func finishJoining(_ container: ModelContainer, store: HouseholdStore) throws -> Summary {
        let context = ModelContext(container)
        let products = try context.fetch(FetchDescriptor<CatalogProduct>())
        let lots = try context.fetch(FetchDescriptor<InventoryLot>())
        let templates = try context.fetch(FetchDescriptor<PersonalProductTemplate>())
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
        try context.save()
        store.unstage(staged)
        store.classifyNew(container: container)
        let remaining = try context.fetch(FetchDescriptor<CatalogProduct>())
        let personal = remaining.filter { store.sharing[$0.id]?.scope == .personal }.map(\.canonicalName)
        return Summary(shared: remaining.count - personal.count, personal: personal, merged: merged)
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

    /// "提醒他一下" from this phone: recorded on the task and carried to the person responsible.
    func nudge(_ task: UUID) throws {
        guard let base, let value = base.tasks.reminder(id: task), let sharing = value.sharing, sharing.isShared else {
            throw SyncFailure("这件事没有交给家人。")
        }
        let target = sharing.assignee ?? sharing.reminded.first
        let name = store.names.thirdPerson.name(target) ?? "家人"
        let me = store.names.thirdPerson.name(store.state?.me) ?? "家人"
        try base.tasks.nudge(task, detail: "\(me)提醒\(name)一下")
        notice = "已经提醒\(store.names.name(target) ?? "家人")了，对方手机会收到。"
        Task { await sync() }
    }

    func addRule(_ text: String, forMe: Bool) {
        let rule = HouseholdRule(text: text, createdBy: store.state?.me)
        if forMe { store.setMyRule(rule, id: rule.id) } else { store.setRule(rule, id: rule.id); Task { await sync() } }
    }

    func removeRule(_ id: UUID) {
        if store.myRules.contains(where: { $0.id == id }) { store.setMyRule(nil, id: id); return }
        store.setRule(nil, id: id)
        Task { await sync() }
    }

    func setQuiet(_ quiet: QuietHours?) {
        store.setQuiet(quiet)
        base?.tasks.rescheduleAll()
        Task { await sync() }
    }

    func sync() async {
        if syncStore?.needsReconnect == true {
            needsSyncRecovery = true
            syncIssue = "需要恢复家庭同步，本机资料已保留。"
            return
        }
        guard let syncStore, let state = store.state, !syncStore.busy, !syncing,
              syncStore.enabled || store.joining else { return }
        syncing = true; defer { syncing = false }
        do {
            // Check identity before testing whether a shared zone disappeared. A different account
            // naturally has a different zone list; that must never be interpreted as removal.
            guard try await myMemberID() == state.me else {
                throw SyncFailure("当前 iCloud 账号与加入家庭时不同，请切回原账号后同步。")
            }
            if state.role == .member, !store.joining, await householdEnded() { return }
            try await HouseholdJoinRecovery.synchronize(store: store, sync: syncStore) {
                guard let container = self.container else { throw SyncFailure("本机资料尚未准备好。") }
                self.summary = try Self.finishJoining(container, store: self.store)
            }
            lastSync = .now
            syncIssue = nil
            ChatDiagnostics.log("household sync completed; pending=\(syncStore.pendingCount); joining=\(store.joining)")
            await subscribe()
        } catch {
            needsSyncRecovery = syncStore.needsReconnect
            syncIssue = store.joining ? "已接受邀请，家庭资料尚未同步完成；联网后会继续。"
                : ((error as? SyncFailure)?.message ?? "家庭同步暂未完成，请检查网络和 iCloud；本机资料已保留。")
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
        let environment = Bundle.main.object(forInfoDictionaryKey: "ButlerCloudEnvironment") as? String ?? "Unknown"
        let key = "household.subscribed.\(environment).\(id)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        do {
            if state.role == .owner {
                let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: id)
                subscription.notificationInfo = info
                let result = try await cloud.privateCloudDatabase.modifySubscriptions(saving: [subscription], deleting: [])
                guard let saved = result.saveResults[id] else { throw SyncFailure("家庭通知订阅回执缺失。") }
                _ = try saved.get()
            } else {
                let subscription = CKDatabaseSubscription(subscriptionID: id)
                subscription.notificationInfo = info
                let result = try await cloud.sharedCloudDatabase.modifySubscriptions(saving: [subscription], deleting: [])
                guard let saved = result.saveResults[id] else { throw SyncFailure("家庭通知订阅回执缺失。") }
                _ = try saved.get()
            }
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            ChatDiagnostics.log("household subscribe failed: \(error)")
        }
    }

    private func unsubscribe(_ state: HouseholdState) async {
        let id = "household-\(state.id.uuidString)"
        UserDefaults.standard.removeObject(forKey: "household.subscribed.\(id)")
        let environment = Bundle.main.object(forInfoDictionaryKey: "ButlerCloudEnvironment") as? String ?? "Unknown"
        UserDefaults.standard.removeObject(forKey: "household.subscribed.\(environment).\(id)")
        let database = state.role == .owner ? cloud.privateCloudDatabase : cloud.sharedCloudDatabase
        _ = try? await database.modifySubscriptions(saving: [], deleting: [id])
    }

    // MARK: Leave

    /// A member leaves; the owner dissolves. Either way everyone keeps a copy as their own.
    func leave() async throws {
        guard !busy, !syncing else { throw SyncFailure("正在同步家庭资料，请稍后再退出。") }
        guard let state = store.state, let zoneID else { return }
        busy = true; defer { busy = false }
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        let database = state.role == .owner ? cloud.privateCloudDatabase : cloud.sharedCloudDatabase
        _ = try await database.deleteRecord(withID: shareID)
        await unsubscribe(state)
        endLocally()
    }

    private func endLocally() {
        try? syncStore?.pause()
        if let root, let state = store.state {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("household-\(state.id.uuidString).json"))
        }
        syncStore = nil
        lastSync = nil
        syncIssue = nil
        needsSyncRecovery = false
        store.end()
        // Tasks this phone was not reminding about stay as records; what it reminds about is decided again.
        base?.tasks.rescheduleAll()
    }
}
