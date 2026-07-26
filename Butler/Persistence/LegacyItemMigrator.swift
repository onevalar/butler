import Foundation
import SwiftData

struct LegacyItemMigrationResult: Sendable {
    let migratedCount: Int
    let alreadyMigratedCount: Int
}

/// Explicit, idempotent importer from the legacy Item table.
/// Do not call this from app launch until old-store migration tests pass on macOS.
@MainActor
final class LegacyItemMigrator {
    static let migrationVersion = 1

    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func migrateAll() throws -> LegacyItemMigrationResult {
        let modelContext = ModelContext(modelContainer)
        modelContext.autosaveEnabled = false
        let items = try modelContext.fetch(FetchDescriptor<Item>())
        let existingLinks = try modelContext.fetch(FetchDescriptor<LegacyItemLink>())
        let migratedItemIDs = Set(existingLinks.map(\.itemID))
        let pendingItems = items.filter { !migratedItemIDs.contains($0.id) }

        guard !pendingItems.isEmpty else {
            return LegacyItemMigrationResult(
                migratedCount: 0,
                alreadyMigratedCount: items.count
            )
        }

        do {
            for item in pendingItems {
                try migrate(item, in: modelContext)
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }

        return LegacyItemMigrationResult(
            migratedCount: pendingItems.count,
            alreadyMigratedCount: items.count - pendingItems.count
        )
    }

    private func migrate(_ item: Item, in modelContext: ModelContext) throws {
        let operationID = UUID()
        let productID = UUID()
        let lotID = UUID()
        let unit = item.unit ?? "个"
        let quantity = migratedQuantity(for: item)
        let lotState = migratedState(for: item, quantity: quantity)

        let product = CatalogProduct(
            id: productID,
            canonicalName: item.name,
            categoryRawValue: item.typeRawValue,
            defaultUnit: unit,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt
        )

        let lot = InventoryLot(
            id: lotID,
            productID: productID,
            quantity: quantity,
            unit: unit,
            purchasedAt: nil,
            packageExpiryDate: nil,
            estimatedExpiryDate: item.expiryDate,
            plannedUseByDate: nil,
            storageLocation: item.storageLocation,
            state: lotState,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt
        )

        modelContext.insert(product)
        modelContext.insert(lot)

        try insertLegacyEvidence(
            subjectKind: .product,
            subjectID: productID,
            fieldKey: .canonicalName,
            value: item.name,
            operationID: operationID,
            in: modelContext
        )
        try insertLegacyEvidence(
            subjectKind: .product,
            subjectID: productID,
            fieldKey: .category,
            value: item.typeRawValue,
            operationID: operationID,
            in: modelContext
        )
        try insertLegacyEvidence(
            subjectKind: .product,
            subjectID: productID,
            fieldKey: .unit,
            value: unit,
            operationID: operationID,
            in: modelContext
        )
        try insertLegacyEvidence(
            subjectKind: .lot,
            subjectID: lotID,
            fieldKey: .quantity,
            value: quantity,
            operationID: operationID,
            in: modelContext
        )
        try insertLegacyEvidence(
            subjectKind: .lot,
            subjectID: lotID,
            fieldKey: .unit,
            value: unit,
            operationID: operationID,
            in: modelContext
        )
        try insertLegacyEvidence(
            subjectKind: .lot,
            subjectID: lotID,
            fieldKey: .state,
            value: lotState.rawValue,
            operationID: operationID,
            in: modelContext
        )

        if let expiryDate = item.expiryDate {
            try insertLegacyEvidence(
                subjectKind: .lot,
                subjectID: lotID,
                fieldKey: .estimatedExpiryDate,
                value: expiryDate,
                operationID: operationID,
                in: modelContext
            )
        }
        if let storageLocation = item.storageLocation {
            try insertLegacyEvidence(
                subjectKind: .lot,
                subjectID: lotID,
                fieldKey: .storageLocation,
                value: storageLocation,
                operationID: operationID,
                in: modelContext
            )
        }

        let snapshot = LegacyItemSnapshot(item: item)
        let event = InventoryEvent(
            operationID: operationID,
            subjectKind: .lot,
            subjectID: lotID,
            eventTypeRawValue: "legacyImported",
            actor: .legacyMigration,
            payloadJSON: try InventoryOperationCoding.makeJSONEncoder().encode(snapshot)
        )
        let link = LegacyItemLink(
            itemID: item.id,
            productID: productID,
            lotID: lotID,
            migrationVersion: Self.migrationVersion
        )
        modelContext.insert(event)
        modelContext.insert(link)
    }

    private func insertLegacyEvidence<Value: Encodable>(
        subjectKind: EvidenceSubjectKind,
        subjectID: UUID,
        fieldKey: InventoryFieldKey,
        value: Value,
        operationID: UUID,
        in modelContext: ModelContext
    ) throws {
        let evidence = FieldEvidence(
            subjectKind: subjectKind,
            subjectID: subjectID,
            fieldKey: fieldKey.rawValue,
            sourceKind: .legacyUnknown,
            verificationState: .unverified,
            confidence: 0,
            operationID: operationID,
            valueJSON: try InventoryOperationCoding.makeJSONEncoder().encode(value)
        )
        modelContext.insert(evidence)
    }

    private func migratedQuantity(for item: Item) -> Int {
        if item.status == .consumed {
            return 0
        }
        return max(0, item.quantity)
    }

    private func migratedState(for item: Item, quantity: Int) -> InventoryLotState {
        switch item.status {
        case .active, .actionRequired:
            return quantity == 0 ? .depleted : .active
        case .consumed:
            return .depleted
        case .discarded:
            return .discarded
        }
    }
}

private struct LegacyItemSnapshot: Codable {
    let id: UUID
    let name: String
    let quantity: Int
    let unit: String?
    let typeRawValue: String
    let statusRawValue: String
    let createdAt: Date
    let updatedAt: Date
    let expiryDate: Date?
    let isEstimated: Bool
    let localImageID: String?
    let notes: String?
    let storageLocation: String?

    init(item: Item) {
        id = item.id
        name = item.name
        quantity = item.quantity
        unit = item.unit
        typeRawValue = item.typeRawValue
        statusRawValue = item.statusRawValue
        createdAt = item.createdAt
        updatedAt = item.updatedAt
        expiryDate = item.expiryDate
        isEstimated = item.isEstimated
        localImageID = item.localImageID
        notes = item.notes
        storageLocation = item.storageLocation
    }
}
