import Foundation
import SwiftData

/// Idempotency marker for the future, explicit Item-to-V2 migration.
@Model
final class LegacyItemLink {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var itemID: UUID
    var productID: UUID
    var lotID: UUID
    var migrationVersion: Int
    var migratedAt: Date

    init(
        id: UUID = UUID(),
        itemID: UUID,
        productID: UUID,
        lotID: UUID,
        migrationVersion: Int,
        migratedAt: Date = Date()
    ) {
        self.id = id
        self.itemID = itemID
        self.productID = productID
        self.lotID = lotID
        self.migrationVersion = migrationVersion
        self.migratedAt = migratedAt
    }
}
