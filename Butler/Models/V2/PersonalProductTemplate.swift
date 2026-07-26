import Foundation
import SwiftData

/// A user's reusable defaults for a recurring product. These are suggestions, not facts.
@Model
final class PersonalProductTemplate {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var productID: UUID
    var usualQuantity: Int?
    var defaultUnit: String?
    var defaultStorageLocation: String?
    var usualConsumptionDays: Int?
    var reminderLeadDays: Int?
    var repurchaseThreshold: Int?
    var createdAt: Date
    var updatedAt: Date
    var revision: Int

    init(
        id: UUID = UUID(),
        productID: UUID,
        usualQuantity: Int? = nil,
        defaultUnit: String? = nil,
        defaultStorageLocation: String? = nil,
        usualConsumptionDays: Int? = nil,
        reminderLeadDays: Int? = nil,
        repurchaseThreshold: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        revision: Int = 0
    ) {
        self.id = id
        self.productID = productID
        self.usualQuantity = usualQuantity
        self.defaultUnit = defaultUnit
        self.defaultStorageLocation = defaultStorageLocation
        self.usualConsumptionDays = usualConsumptionDays
        self.reminderLeadDays = reminderLeadDays
        self.repurchaseThreshold = repurchaseThreshold
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
    }
}
