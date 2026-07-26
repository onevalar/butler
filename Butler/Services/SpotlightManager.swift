//
//  SpotlightManager.swift
//  Butler
//
//  Created by 安宇佳 on 2026/1/6.
//

import Foundation
import CoreSpotlight
import MobileCoreServices

/// Manager for indexing items in iOS System Search (Spotlight)
final class SpotlightManager {
    
    static let shared = SpotlightManager()
    
    private let domainIdentifier = "com.butler.items"
    
    private init() {}
    
    /// Index a single item in Spotlight
    func indexItem(_ item: Item) {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .item)
        attributeSet.title = item.name
        attributeSet.contentDescription = "\(item.type.displayName) • \(item.expiryDescription)\n\(item.quantity) 个"
        
        // Add keywords for fuzzy search
        attributeSet.keywords = [item.name, item.type.displayName, item.storageLocation ?? ""].filter { !$0.isEmpty }
        
        // Use expiry date as a sortable attribute
        if let expiryDate = item.expiryDate {
            attributeSet.contentModificationDate = expiryDate
        }
        
        // Set category icon (simplified - in real app would use custom icons)
        // attributeSet.thumbnailData = ... 
        
        let searchableItem = CSSearchableItem(
            uniqueIdentifier: item.id.uuidString,
            domainIdentifier: domainIdentifier,
            attributeSet: attributeSet
        )
        
        CSSearchableIndex.default().indexSearchableItems([searchableItem]) { error in
            if let error = error {
                print("Spotlight indexing error: \(error.localizedDescription)")
            }
        }
    }
    
    /// Remove an item from Spotlight index
    func deindexItem(_ item: Item) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [item.id.uuidString]) { error in
            if let error = error {
                print("Spotlight de-indexing error: \(error.localizedDescription)")
            }
        }
    }
    
    /// Index multiple items (useful for initial launch or bulk updates)
    func indexItems(_ items: [Item]) {
        items.forEach { indexItem($0) }
    }
    
    /// Clear all app items from Spotlight
    func clearAllIndexes() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { error in
            if let error = error {
                print("Spotlight clear error: \(error.localizedDescription)")
            }
        }
    }
}
