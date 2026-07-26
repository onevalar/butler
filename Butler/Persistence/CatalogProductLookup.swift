import Foundation
import SwiftData

struct CatalogProductCandidate: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let canonicalName: String
    let brand: String?
    let defaultUnit: String?
}

struct CatalogProductLookup {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) { self.modelContainer = modelContainer }

    @MainActor
    func exactMatches(for name: String) throws -> [CatalogProductCandidate] {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let products = try context.fetch(FetchDescriptor<CatalogProduct>())
        let normalized = Self.normalize(name)
        return products.filter { !$0.isArchived && Self.normalize($0.canonicalName) == normalized }
            .map { .init(id: $0.id, canonicalName: $0.canonicalName, brand: $0.brand, defaultUnit: $0.defaultUnit) }
    }

    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}
