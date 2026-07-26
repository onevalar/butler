import Foundation
import SwiftData

enum InventoryLotState: String, Codable, Sendable {
    case active
    case depleted
    case discarded
    case gifted
    case archived
}

/// One owned batch of a product. Lots with different expiry dates remain separate.
@Model
final class InventoryLot {
    @Attribute(.unique) var id: UUID
    var productID: UUID
    var quantity: Int
    var unit: String
    var purchasedAt: Date?
    var packageExpiryDate: Date?
    var estimatedExpiryDate: Date?
    var plannedUseByDate: Date?
    var storageLocation: String?
    var stateRawValue: String
    var createdAt: Date
    var updatedAt: Date
    var revision: Int

    var state: InventoryLotState {
        get { InventoryLotState(rawValue: stateRawValue) ?? .active }
        set { stateRawValue = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        productID: UUID,
        quantity: Int,
        unit: String,
        purchasedAt: Date? = nil,
        packageExpiryDate: Date? = nil,
        estimatedExpiryDate: Date? = nil,
        plannedUseByDate: Date? = nil,
        storageLocation: String? = nil,
        state: InventoryLotState = .active,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        revision: Int = 0
    ) {
        self.id = id
        self.productID = productID
        self.quantity = quantity
        self.unit = unit
        self.purchasedAt = purchasedAt
        self.packageExpiryDate = packageExpiryDate
        self.estimatedExpiryDate = estimatedExpiryDate
        self.plannedUseByDate = plannedUseByDate
        self.storageLocation = storageLocation
        self.stateRawValue = state.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
    }
}
