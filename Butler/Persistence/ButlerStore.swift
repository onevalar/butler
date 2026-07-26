import Foundation
import SwiftData

enum ButlerStore {
    /// The complete schema for the physical Butler store. Keep legacy Item until V2 parity is proven.
    static let schema = Schema([
        Item.self,
        CatalogProduct.self,
        InventoryLot.self,
        FieldEvidence.self,
        InventoryEvent.self,
        PersonalProductTemplate.self,
        LegacyItemLink.self,
    ])

    static func makeContainer() throws -> ModelContainer {
        let configuration: ModelConfiguration

        if let sharedURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.butler"
        ) {
            let databaseURL = sharedURL.appendingPathComponent("Butler.sqlite")
            configuration = ModelConfiguration(schema: schema, url: databaseURL)
        } else {
            // Preserve the legacy default-store location when App Groups are unavailable.
            configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true
            )
        }

        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static func makePreviewContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
