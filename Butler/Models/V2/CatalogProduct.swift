import Foundation
import SwiftData

/// A reusable product identity. Inventory-specific facts belong to `InventoryLot`.
@Model
final class CatalogProduct {
    @Attribute(.unique) var id: UUID
    var canonicalName: String
    var brand: String?
    var categoryRawValue: String?
    var barcode: String?
    var defaultUnit: String?
    var typicalShelfLifeDays: Int?
    var postOpeningLifeDays: Int?
    var createdAt: Date
    var updatedAt: Date
    var revision: Int
    var isArchived: Bool

    init(
        id: UUID = UUID(),
        canonicalName: String,
        brand: String? = nil,
        categoryRawValue: String? = nil,
        barcode: String? = nil,
        defaultUnit: String? = nil,
        typicalShelfLifeDays: Int? = nil,
        postOpeningLifeDays: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        revision: Int = 0,
        isArchived: Bool = false
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.brand = brand
        self.categoryRawValue = categoryRawValue
        self.barcode = barcode
        self.defaultUnit = defaultUnit
        self.typicalShelfLifeDays = typicalShelfLifeDays
        self.postOpeningLifeDays = postOpeningLifeDays
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.isArchived = isArchived
    }
}
