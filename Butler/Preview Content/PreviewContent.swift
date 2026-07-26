//
//  PreviewContent.swift
//  Butler
//
//  Created by 安宇佳 on 2026/1/6.
//

import Foundation
import SwiftData

// MARK: - Preview Container

/// A shared model container for SwiftUI previews
@MainActor
enum PreviewContainer {
    
    /// In-memory model container for previews
    static let shared: ModelContainer = {
        do {
            let container = try ButlerStore.makePreviewContainer()
            
            // Insert preview data
            PreviewData.insertSampleItems(into: container.mainContext)
            
            return container
        } catch {
            fatalError("Failed to create preview container: \(error)")
        }
    }()
    
    /// Convenience accessor for the main context
    static var mainContext: ModelContext {
        shared.mainContext
    }
}

// MARK: - Preview Data

/// Mock data generator for UI previews and testing
@MainActor
enum PreviewData {
    
    // MARK: - Sample Items
    
    /// Generate sample items for various scenarios
    static func insertSampleItems(into context: ModelContext) {
        // Insert all sample items
        sampleItems.forEach { context.insert($0) }
        try? context.save()
    }
    
    /// All sample items for preview
    static var sampleItems: [Item] {
        actionRequiredItems + criticalItems + warningItems + safeItems
    }
    
    // MARK: - Action Required Items (The Inbox)
    
    /// Items that need user attention (no verified expiry date)
    static var actionRequiredItems: [Item] {
        [
            {
                let item = Item(
                    name: "牛奶",
                    quantity: 3,
                    type: .fresh,
                    status: .actionRequired
                )
                item.isEstimated = true
                item.notes = "语音录入，需要拍照确认保质期"
                return item
            }(),
            {
                let item = Item(
                    name: "感冒药",
                    quantity: 1,
                    type: .medicine,
                    status: .actionRequired
                )
                item.isEstimated = true
                item.notes = "需要确认有效期"
                return item
            }(),
        ]
    }
    
    // MARK: - Critical Items (Red Zone: < 3 days)
    
    /// Items expiring within 3 days
    static var criticalItems: [Item] {
        [
            {
                let item = Item(
                    name: "酸奶",
                    quantity: 2,
                    type: .fresh,
                    status: .active,
                    expiryDate: Date().addingTimeInterval(1 * 24 * 60 * 60), // Tomorrow
                    isEstimated: false
                )
                item.localImageID = "yogurt_001"
                return item
            }(),
            {
                let item = Item(
                    name: "面包",
                    quantity: 1,
                    type: .fresh,
                    status: .active,
                    expiryDate: Date().addingTimeInterval(2 * 24 * 60 * 60), // 2 days
                    isEstimated: false
                )
                return item
            }(),
            {
                let item = Item(
                    name: "鸡蛋",
                    quantity: 6,
                    type: .fresh,
                    status: .active,
                    expiryDate: Date().addingTimeInterval(-1 * 24 * 60 * 60), // Expired yesterday
                    isEstimated: false
                )
                item.notes = "已过期！"
                return item
            }(),
        ]
    }
    
    // MARK: - Warning Items (Yellow Zone: < 7 days)
    
    /// Items expiring within 7 days
    static var warningItems: [Item] {
        [
            {
                let item = Item(
                    name: "豆腐",
                    quantity: 2,
                    type: .fresh,
                    status: .active,
                    expiryDate: Date().addingTimeInterval(5 * 24 * 60 * 60),
                    isEstimated: false
                )
                item.storageLocation = "冷藏"
                return item
            }(),
            {
                let item = Item(
                    name: "火腿肠",
                    quantity: 4,
                    type: .pantry,
                    status: .active,
                    expiryDate: Date().addingTimeInterval(6 * 24 * 60 * 60),
                    isEstimated: false
                )
                return item
            }(),
        ]
    }
    
    // MARK: - Safe Items (Green Zone: >= 7 days)
    
    /// Items with plenty of time before expiry
    static var safeItems: [Item] {
        [
            {
                let item = Item(
                    name: "速冻饺子",
                    quantity: 2,
                    type: .fresh,
                    status: .active,
                    expiryDate: Date().addingTimeInterval(90 * 24 * 60 * 60), // 3 months
                    isEstimated: false
                )
                item.storageLocation = "冷冻"
                return item
            }(),
            {
                let item = Item(
                    name: "大米",
                    quantity: 1,
                    type: .pantry,
                    status: .active,
                    expiryDate: Date().addingTimeInterval(180 * 24 * 60 * 60),
                    isEstimated: true
                )
                item.notes = "10斤装"
                return item
            }(),
            {
                let item = Item(
                    name: "洗衣液",
                    quantity: 1,
                    type: .general,
                    status: .active,
                    expiryDate: Date().addingTimeInterval(365 * 24 * 60 * 60),
                    isEstimated: true
                )
                return item
            }(),
            {
                let item = Item(
                    name: "抽纸",
                    quantity: 5,
                    type: .general,
                    status: .active,
                    expiryDate: Date().addingTimeInterval(365 * 24 * 60 * 60),
                    isEstimated: true
                )
                item.notes = "R2规则自动归档"
                return item
            }(),
            {
                let item = Item(
                    name: "布洛芬",
                    quantity: 1,
                    type: .medicine,
                    status: .active,
                    expiryDate: Date().addingTimeInterval(300 * 24 * 60 * 60),
                    isEstimated: false
                )
                item.localImageID = "ibuprofen_001"
                item.notes = "退烧药"
                return item
            }(),
        ]
    }
    
    // MARK: - Archived Items
    
    /// Items that have been consumed or discarded
    static var archivedItems: [Item] {
        [
            {
                let item = Item(
                    name: "可乐",
                    quantity: 0,
                    type: .pantry,
                    status: .consumed
                )
                item.expiryDate = Date().addingTimeInterval(30 * 24 * 60 * 60)
                return item
            }(),
            {
                let item = Item(
                    name: "过期牛奶",
                    quantity: 1,
                    type: .fresh,
                    status: .discarded
                )
                item.expiryDate = Date().addingTimeInterval(-7 * 24 * 60 * 60)
                return item
            }(),
        ]
    }
    
    // MARK: - Single Preview Items
    
    /// A single action required item for component previews
    static var singleActionRequired: Item {
        actionRequiredItems[0]
    }
    
    /// A single critical item for component previews
    static var singleCritical: Item {
        criticalItems[0]
    }
    
    /// A single warning item for component previews
    static var singleWarning: Item {
        warningItems[0]
    }
    
    /// A single safe item for component previews
    static var singleSafe: Item {
        safeItems[0]
    }
    
    // MARK: - Preview DataManager
    
    /// A DataManager configured with preview data
    static var dataManager: DataManager {
        DataManager(modelContext: PreviewContainer.mainContext)
    }
}

// MARK: - Preview Helpers

extension Item {
    /// Create a sample item for isolated previews
    static func preview(
        name: String = "示例物品",
        quantity: Int = 1,
        type: ItemType = .general,
        status: ItemStatus = .active,
        daysUntilExpiry: Int? = 7
    ) -> Item {
        let item = Item(
            name: name,
            quantity: quantity,
            type: type,
            status: status
        )
        
        if let days = daysUntilExpiry {
            item.expiryDate = Date().addingTimeInterval(TimeInterval(days * 24 * 60 * 60))
            item.isEstimated = false
        }
        
        return item
    }
}
