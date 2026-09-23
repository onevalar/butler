import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// Mirrors active lots into iOS system search so "感冒药" finds what is at home.
final class SpotlightManager {
    static let shared = SpotlightManager()
    private init() {}

    private let domainIdentifier = "com.butler.lots"

    func resync(_ lots: [LotFacts]) async {
        let index = CSSearchableIndex.default()
        try? await index.deleteSearchableItems(withDomainIdentifiers: [domainIdentifier])
        let items = lots.map { lot -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .item)
            attributes.title = lot.name
            let place = lot.storageLocation.map { "\($0) · " } ?? ""
            attributes.contentDescription = "\(place)\(lot.quantity) \(lot.unit) · \(lot.timeLeftLabel)"
            attributes.keywords = [lot.name, lot.brand, lot.storageLocation, lot.isMedicine ? "药" : nil].compactMap { $0 }
            return CSSearchableItem(uniqueIdentifier: lot.id.uuidString, domainIdentifier: domainIdentifier, attributeSet: attributes)
        }
        try? await index.indexSearchableItems(items)
    }
}
