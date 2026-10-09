import Foundation
import SwiftData

/// A product and its batches/defaults travel together, so a partial import cannot orphan a lot.
/// Photos and local audit/confirmation records never enter this projection.
@MainActor final class ButlerSyncData: SyncLocalData {
    struct Inventory: Codable {
        var product: ButlerBackup.Product
        var lots: [ButlerBackup.Lot]
        var templates: [ButlerBackup.Template]
    }
    let container: ModelContainer
    let notes: LocalMemoryStore
    let tasks: ReminderStore
    private let revisionFile: URL
    /// Products that travel through the household zone instead; this device's own sync leaves them out.
    var householdProducts: () -> Set<UUID> = { [] }
    /// Tasks shared in the household travel through its zone too.
    var householdTasks: () -> Set<UUID> = { [] }
    init(container: ModelContainer, notes: LocalMemoryStore, tasks: ReminderStore, revisionFile: URL) {
        self.container = container; self.notes = notes; self.tasks = tasks; self.revisionFile = revisionFile
    }
    nonisolated deinit {}
    private func profile(_ data: Data?, photo: Data? = nil) throws -> Data? {
        guard let data else { return nil }
        var value = try JSONDecoder().decode(ItemProfile.self, from: data)
        value.photo = photo
        try value.validate()
        // Canonical empty profile: retaining a local photo must not generate a sync echo.
        if photo == nil, value.category == .other, value.attributes.isEmpty, value.tags.isEmpty, value.availability == "ready" { return nil }
        return try SyncRecord.encode(value)
    }
    static func portable(_ task: TimedReminder) -> TimedReminder {
        var task = task; task.revision = 0; task.syncReceived = nil; return task
    }
    func snapshot() throws -> [SyncRecord.Key: Data] {
        let shared = householdProducts()
        var result: [SyncRecord.Key: Data] = [:]
        for (id, inventory) in try inventories(where: { !shared.contains($0) }) {
            result[.init(kind: .inventory, id: id)] = try SyncRecord.encode(inventory)
        }
        for note in try notes.recordsForSync() {
            var value = note; value.revision = 0
            result[.init(kind: .note, id: note.id)] = try SyncRecord.encode(value)
        }
        let sharedTasks = householdTasks()
        for task in try tasks.tasksForSync() where !sharedTasks.contains(task.id) {
            result[.init(kind: .task, id: task.id)] = try SyncRecord.encode(Self.portable(task))
        }
        return result
    }
    /// Each product with its batches and defaults, in the portable form both syncs use.
    func inventories(where include: (UUID) -> Bool) throws -> [UUID: Inventory] {
        let context = ModelContext(container)
        let products = try context.fetch(FetchDescriptor<CatalogProduct>())
        let lots = try context.fetch(FetchDescriptor<InventoryLot>())
        let templates = try context.fetch(FetchDescriptor<PersonalProductTemplate>())
        let ids = Set(products.map(\.id))
        guard lots.allSatisfy({ ids.contains($0.productID) }), templates.allSatisfy({ ids.contains($0.productID) }) else {
            throw SyncFailure("库存存在缺失的商品关联，停止同步而非丢弃批次。")
        }
        var result: [UUID: Inventory] = [:]
        for p in products where include(p.id) {
            let product = ButlerBackup.Product(id: p.id, canonicalName: p.canonicalName, brand: p.brand,
                categoryRawValue: p.categoryRawValue, barcode: p.barcode, defaultUnit: p.defaultUnit,
                typicalShelfLifeDays: p.typicalShelfLifeDays, postOpeningLifeDays: p.postOpeningLifeDays,
                createdAt: p.createdAt, updatedAt: p.updatedAt, revision: 0, isArchived: p.isArchived)
            let batches: [ButlerBackup.Lot] = try lots.filter { $0.productID == p.id }.sorted { $0.id.uuidString < $1.id.uuidString }.map {
                .init(id: $0.id, productID: $0.productID, quantity: $0.quantity, unit: $0.unit, purchasedAt: $0.purchasedAt,
                    packageExpiryDate: $0.packageExpiryDate, estimatedExpiryDate: $0.estimatedExpiryDate, plannedUseByDate: $0.plannedUseByDate,
                    storageLocation: $0.storageLocation, stateRawValue: $0.stateRawValue, createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt, revision: 0, profileData: try profile($0.profileData))
            }
            let defaults: [ButlerBackup.Template] = templates.filter { $0.productID == p.id }.sorted { $0.id.uuidString < $1.id.uuidString }.map {
                .init(id: $0.id, productID: $0.productID, usualQuantity: $0.usualQuantity, defaultUnit: $0.defaultUnit,
                    defaultStorageLocation: $0.defaultStorageLocation, usualConsumptionDays: $0.usualConsumptionDays,
                    reminderLeadDays: $0.reminderLeadDays, repurchaseThreshold: $0.repurchaseThreshold,
                    createdAt: $0.createdAt, updatedAt: $0.updatedAt, revision: 0)
            }
            result[p.id] = Inventory(product: product, lots: batches, templates: defaults)
        }
        return result
    }
    func nextRevision() throws -> Int {
        let context = ModelContext(container)
        let revisions = try context.fetch(FetchDescriptor<CatalogProduct>()).map(\.revision)
            + context.fetch(FetchDescriptor<InventoryLot>()).map(\.revision)
            + context.fetch(FetchDescriptor<PersonalProductTemplate>()).map(\.revision)
            + tasks.taskSnapshot().map(\.revision) + notes.records.map(\.revision)
        let previous: Int
        if FileManager.default.fileExists(atPath: revisionFile.path) {
            previous = try JSONDecoder().decode(Int.self, from: Data(contentsOf: revisionFile))
        } else { previous = 0 }
        let maximum = max(previous, revisions.max() ?? 0)
        guard maximum >= 0, maximum < Int.max else { throw SyncFailure("本机版本记录无效。") }
        try FileManager.default.createDirectory(at: revisionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SyncRecord.encode(maximum + 1).write(to: revisionFile, options: .atomic)
        return maximum + 1
    }
    func replace(_ key: SyncRecord.Key, expected: Data?, with payload: Data?) throws {
        // The household zone owns shared things; this device's own sync never overwrites them.
        if key.kind == .inventory, householdProducts().contains(key.id) { return }
        if key.kind == .task, householdTasks().contains(key.id) { return }
        guard try snapshot()[key] == expected else { throw SyncFailure("本机资料刚发生变化，未覆盖。") }
        let revision = try nextRevision()
        switch key.kind {
        case .chat, .itemPhoto, .chatPhoto:
            throw SyncFailure("聊天和图片只能通过各自单独确认的同步接收。")
        case .member, .rule:
            throw SyncFailure("家庭成员和规则只通过家庭同步接收。")
        case .note:
            if let payload {
                var value = try JSONDecoder().decode(LocalMemory.self, from: payload)
                guard value.id == key.id, !value.title.isEmpty, value.title.count <= 200, value.text.count <= 8000,
                      value.quantity.map({ $0 >= 0 }) ?? true else { throw SyncFailure("云端笔记格式无效。") }
                value.revision = revision
                try notes.receiveSyncedNote(value)
            } else { try notes.delete(key.id) }
        case .task:
            var value = try payload.map { try JSONDecoder().decode(TimedReminder.self, from: $0) }
            value?.revision = revision
            try tasks.receiveSyncedTask(key.id, value: value)
        case .inventory:
            let value = try payload.map { try JSONDecoder().decode(Inventory.self, from: $0) }
            try replaceInventory(key.id, value, revision: revision)
        }
        WidgetSnapshotPublisher.shared.refresh()
        NotificationCenter.default.post(name: .init("butlerBriefSourcesChanged"), object: nil)
    }
    func replaceInventory(_ id: UUID, _ value: Inventory?, revision: Int) throws {
        let context = ModelContext(container); context.autosaveEnabled = false
        let products = try context.fetch(FetchDescriptor<CatalogProduct>())
        let lots = try context.fetch(FetchDescriptor<InventoryLot>())
        let templates = try context.fetch(FetchDescriptor<PersonalProductTemplate>())
        if let value {
            guard value.product.id == id, !value.product.canonicalName.isEmpty,
                  value.lots.count <= 1000, Set(value.lots.map(\.id)).count == value.lots.count,
                  value.templates.count <= 1,
                  value.lots.allSatisfy({ $0.productID == id && $0.quantity >= 0 && InventoryLotState(rawValue: $0.stateRawValue) != nil }),
                  value.templates.allSatisfy({ $0.productID == id }),
                  !lots.contains(where: { $0.productID != id && value.lots.map(\.id).contains($0.id) }),
                  !templates.contains(where: { $0.productID != id && value.templates.map(\.id).contains($0.id) }) else {
                throw SyncFailure("云端库存关联或字段无效，未修改本机。")
            }
            // Validate all profiles before mutating the context; reject remote photos.
            for lot in value.lots {
                if let data = lot.profileData {
                    let decoded = try JSONDecoder().decode(ItemProfile.self, from: data)
                    guard decoded.photo == nil else { throw SyncFailure("首版不接收图片同步。") }; try decoded.validate()
                }
            }
            let p = value.product
            let product = products.first { $0.id == id } ?? CatalogProduct(id: id, canonicalName: p.canonicalName)
            if !products.contains(where: { $0.id == id }) { context.insert(product) }
            product.canonicalName = p.canonicalName; product.brand = p.brand; product.categoryRawValue = p.categoryRawValue
            product.barcode = p.barcode; product.defaultUnit = p.defaultUnit; product.typicalShelfLifeDays = p.typicalShelfLifeDays
            product.postOpeningLifeDays = p.postOpeningLifeDays; product.isArchived = p.isArchived
            product.createdAt = p.createdAt; product.updatedAt = p.updatedAt; product.revision = revision
            for l in value.lots {
                let lot = lots.first { $0.id == l.id } ?? InventoryLot(id: l.id, productID: id, quantity: l.quantity, unit: l.unit)
                if !lots.contains(where: { $0.id == l.id }) { context.insert(lot) }
                let photo = lot.itemProfile?.photo
                lot.quantity = l.quantity; lot.unit = l.unit; lot.purchasedAt = l.purchasedAt
                lot.packageExpiryDate = l.packageExpiryDate; lot.estimatedExpiryDate = l.estimatedExpiryDate
                lot.plannedUseByDate = l.plannedUseByDate; lot.storageLocation = l.storageLocation; lot.stateRawValue = l.stateRawValue
                lot.createdAt = l.createdAt; lot.updatedAt = l.updatedAt; lot.revision = revision
                // A remote removal of the profile must not discard the local-only photo.
                if l.profileData == nil, let photo {
                    var retained = ItemProfile(category: .other); retained.photo = photo
                    lot.profileData = try SyncRecord.encode(retained)
                } else { lot.profileData = try profile(l.profileData, photo: photo) }
            }
            for t in value.templates {
                let template = templates.first { $0.id == t.id } ?? PersonalProductTemplate(id: t.id, productID: id)
                if !templates.contains(where: { $0.id == t.id }) { context.insert(template) }
                template.usualQuantity = t.usualQuantity; template.defaultUnit = t.defaultUnit
                template.defaultStorageLocation = t.defaultStorageLocation; template.usualConsumptionDays = t.usualConsumptionDays
                template.reminderLeadDays = t.reminderLeadDays; template.repurchaseThreshold = t.repurchaseThreshold
                template.createdAt = t.createdAt; template.updatedAt = t.updatedAt; template.revision = revision
            }
        }
        for lot in lots where lot.productID == id && !(value?.lots.contains { $0.id == lot.id } ?? false) { context.delete(lot) }
        for template in templates where template.productID == id && !(value?.templates.contains { $0.id == template.id } ?? false) { context.delete(template) }
        if value == nil { for product in products where product.id == id { context.delete(product) } }
        do { try context.save() } catch { context.rollback(); throw error }
    }
}
