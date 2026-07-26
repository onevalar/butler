//
//  DataManager.swift
//  Butler
//
//  Created by 安宇佳 on 2026/1/6.
//

import Foundation
import SwiftData
import Observation
import WidgetKit

// MARK: - Input Source

/// Represents the source of item input
enum InputSource: Sendable {
    /// User typed or spoke the item name
    case voice(transcript: String)
    /// User scanned/photographed the item
    case camera(imageID: String)
    /// User manually entered all details
    case manual
}

// MARK: - Parsed Item Input

/// Represents parsed information from voice or camera input
struct ParsedItemInput: Sendable {
    let name: String
    let quantity: Int
    let unit: String?         // e.g., "瓶", "盒", "袋"
    let suggestedType: ItemType
    let expiryDate: Date?
    let storageHint: String?  // e.g., "冷冻", "冷藏"
    let confidence: Double    // AI confidence level (0-1)
}

// MARK: - Data Manager

/// Service layer that handles all item CRUD operations and business logic
/// Implements the "Butler Engine" logic rules (R1, R2)
@MainActor
@Observable
final class DataManager {
    
    // MARK: - Properties
    
    private let modelContext: ModelContext
    
    /// Recent undo action (for 5-second undo feature)
    private(set) var lastAction: UndoableAction?
    private var undoTimer: Timer?
    
    // MARK: - Initialization
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        
        // Potential: Sync all items on first load to ensure Spotlight is up to date
        // Note: For large datasets, this should be handled background or incrementally
        Task {
            let allItems = fetchItems(includeArchived: true)
            SpotlightManager.shared.indexItems(allItems)
        }
    }
    
    // MARK: - CRUD Operations
    
    /// Add a new item with smart logic based on type and input source
    @discardableResult
    func addItem(from input: ParsedItemInput, source: InputSource) -> Item {
        let item = Item(
            name: input.name,
            quantity: input.quantity,
            unit: input.unit,
            type: input.suggestedType,
            storageLocation: input.storageHint
        )
        
        // Apply Butler Engine Logic
        applyInputLogic(to: item, input: input, source: source)
        
        modelContext.insert(item)
        saveChanges()

        // Sync to Spotlight and schedule notification
        SpotlightManager.shared.indexItem(item)
        NotificationManager.shared.scheduleExpiryNotification(for: item)

        return item
    }
    
    /// Update an existing item
    func updateItem(_ item: Item, name: String? = nil, quantity: Int? = nil, 
                    type: ItemType? = nil, expiryDate: Date? = nil,
                    notes: String? = nil, storageLocation: String? = nil) {
        if let name { item.name = name }
        if let quantity { item.quantity = quantity }
        if let type { item.type = type }
        if let expiryDate {
            item.expiryDate = expiryDate
            item.isEstimated = false
            if item.status == .actionRequired {
                item.status = .active
            }
        }
        if let notes { item.notes = notes }
        if let storageLocation { item.storageLocation = storageLocation }

        item.updatedAt = Date()
        saveChanges()

        // Sync update to Spotlight and reschedule notification
        SpotlightManager.shared.indexItem(item)
        NotificationManager.shared.scheduleExpiryNotification(for: item)
    }
    
    /// Verify and confirm an item's expiry date
    func verifyExpiryDate(_ item: Item, date: Date, imageID: String? = nil) {
        item.expiryDate = date
        item.isEstimated = false
        item.status = .active
        if let imageID {
            item.localImageID = imageID
        }
        item.updatedAt = Date()
        saveChanges()

        // Update Spotlight and reschedule notification
        SpotlightManager.shared.indexItem(item)
        NotificationManager.shared.scheduleExpiryNotification(for: item)
    }
    
    /// Mark item as consumed
    func consumeItem(_ item: Item) {
        let previousStatus = item.status
        let previousQuantity = item.quantity

        item.status = .consumed
        item.updatedAt = Date()
        saveChanges()

        // Remove from Spotlight and cancel notification (item is no longer active)
        SpotlightManager.shared.deindexItem(item)
        NotificationManager.shared.cancelNotification(for: item)

        setUndoAction(.consume(item: item, previousStatus: previousStatus, previousQuantity: previousQuantity))
    }

    /// Mark item as discarded
    func discardItem(_ item: Item) {
        let previousStatus = item.status

        item.status = .discarded
        item.updatedAt = Date()
        saveChanges()

        // Remove from Spotlight and cancel notification (item is no longer active)
        SpotlightManager.shared.deindexItem(item)
        NotificationManager.shared.cancelNotification(for: item)

        setUndoAction(.discard(item: item, previousStatus: previousStatus))
    }
    
    /// Decrement item quantity
    func decrementQuantity(_ item: Item, by amount: Int = 1) {
        let previousQuantity = item.quantity
        item.quantity = max(0, item.quantity - amount)

        if item.quantity == 0 {
            item.status = .consumed
            SpotlightManager.shared.deindexItem(item)
            NotificationManager.shared.cancelNotification(for: item)
        } else {
            SpotlightManager.shared.indexItem(item)
        }

        item.updatedAt = Date()
        saveChanges()

        setUndoAction(.decrementQuantity(item: item, previousQuantity: previousQuantity))
    }

    /// Permanently delete an item
    func deleteItem(_ item: Item) {
        SpotlightManager.shared.deindexItem(item)
        NotificationManager.shared.cancelNotification(for: item)
        modelContext.delete(item)
        saveChanges()
    }
    
    // MARK: - Query Operations
    
    /// Fetch all items with optional filtering
    func fetchItems(
        status: ItemStatus? = nil,
        type: ItemType? = nil,
        urgencyLevel: UrgencyLevel? = nil,
        includeArchived: Bool = false
    ) -> [Item] {
        let descriptor = FetchDescriptor<Item>(
            sortBy: [SortDescriptor(\.expiryDate, order: .forward)]
        )
        
        do {
            var items = try modelContext.fetch(descriptor)
            
            // Apply filters
            if let status {
                items = items.filter { $0.status == status }
            }
            
            if let type {
                items = items.filter { $0.type == type }
            }
            
            if let urgencyLevel {
                items = items.filter { $0.urgencyLevel == urgencyLevel }
            }
            
            if !includeArchived {
                items = items.filter { $0.isActive }
            }
            
            return items
        } catch {
            print("Failed to fetch items: \(error)")
            return []
        }
    }
    
    /// Fetch items requiring action (The Inbox)
    func fetchActionRequiredItems() -> [Item] {
        fetchItems(status: .actionRequired)
    }
    
    /// Fetch items by urgency zone (for Dashboard Grid)
    func fetchItemsByUrgency() -> (critical: [Item], warning: [Item], safe: [Item]) {
        let activeItems = fetchItems().filter { $0.status == .active }
        
        let critical = activeItems.filter { $0.urgencyLevel == .critical || $0.urgencyLevel == .expired }
        let warning = activeItems.filter { $0.urgencyLevel == .warning }
        let safe = activeItems.filter { $0.urgencyLevel == .safe || $0.urgencyLevel == .unknown }
        
        return (critical, warning, safe)
    }
    
    /// Get a dynamic greeting based on inventory status
    func getDynamicGreeting() -> String {
        let actionRequired = fetchActionRequiredItems()
        let (critical, warning, _) = fetchItemsByUrgency()
        
        if !actionRequired.isEmpty {
            return "有 \(actionRequired.count) 件物品需要补全信息"
        } else if !critical.isEmpty {
            return "注意：\(critical.count) 件物品即将过期"
        } else if !warning.isEmpty {
            return "提醒：\(warning.count) 件物品本周过期"
        } else {
            return "一切安好，库存充足 ✨"
        }
    }
    
    // MARK: - Butler Engine Logic
    
    /// Apply the Butler Engine input logic rules
    /// - R1: Food/Medicine without explicit date -> ActionRequired
    /// - R2: General items without date -> Auto-fill default duration
    private func applyInputLogic(to item: Item, input: ParsedItemInput, source: InputSource) {
        let hasExplicitDate = input.expiryDate != nil
        let hasStorageHint = input.storageHint != nil
        
        if hasExplicitDate {
            // User or AI provided explicit date
            item.expiryDate = input.expiryDate
            item.isEstimated = false
            item.status = .active
        } else if item.type.isSensitive {
            // R1: Sensitive items (Food/Medicine) without date
            // Check for storage hints that might extend shelf life
            if hasStorageHint && isExtendedStorageHint(input.storageHint) {
                // User said "放冷冻" or similar - apply extended default
                let extendedDuration = extendedDuration(for: item.type, hint: input.storageHint)
                item.expiryDate = Date().addingTimeInterval(extendedDuration)
                item.isEstimated = true
                item.status = .active
            } else {
                // No date, no extension hint -> ActionRequired
                item.expiryDate = nil
                item.isEstimated = true
                item.status = .actionRequired
            }
        } else {
            // R2: Non-sensitive items (General) without date
            // Auto-fill with default duration
            item.expiryDate = Date().addingTimeInterval(item.type.defaultDuration)
            item.isEstimated = true
            item.status = .active
        }
        
        // Set image evidence if from camera
        if case .camera(let imageID) = source {
            item.localImageID = imageID
        }
    }
    
    /// Check if storage hint indicates extended shelf life
    private func isExtendedStorageHint(_ hint: String?) -> Bool {
        guard let hint = hint?.lowercased() else { return false }
        let extendedKeywords = ["冷冻", "冻", "freezer", "frozen"]
        return extendedKeywords.contains { hint.contains($0) }
    }
    
    /// Calculate extended duration based on storage hint
    private func extendedDuration(for type: ItemType, hint: String?) -> TimeInterval {
        guard isExtendedStorageHint(hint) else {
            return type.defaultDuration
        }
        
        // Frozen storage extends shelf life
        switch type {
        case .fresh:
            return 90 * 24 * 60 * 60  // 3 months frozen
        case .pantry:
            return 365 * 24 * 60 * 60 // 1 year frozen
        case .medicine:
            return type.defaultDuration // Medicine shouldn't be frozen usually
        case .general:
            return type.defaultDuration
        }
    }
    
    // MARK: - Undo Support
    
    /// Set an undoable action with 5-second timeout
    private func setUndoAction(_ action: UndoableAction) {
        undoTimer?.invalidate()
        lastAction = action
        
        undoTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.clearUndoAction()
            }
        }
    }
    
    /// Clear the current undo action
    func clearUndoAction() {
        undoTimer?.invalidate()
        undoTimer = nil
        lastAction = nil
    }
    
    /// Undo the last action if available
    func undoLastAction() -> Bool {
        guard let action = lastAction else { return false }
        
        switch action {
        case .consume(let item, let previousStatus, let previousQuantity):
            item.status = previousStatus
            item.quantity = previousQuantity
            SpotlightManager.shared.indexItem(item)
            NotificationManager.shared.scheduleExpiryNotification(for: item)

        case .discard(let item, let previousStatus):
            item.status = previousStatus
            SpotlightManager.shared.indexItem(item)
            NotificationManager.shared.scheduleExpiryNotification(for: item)

        case .decrementQuantity(let item, let previousQuantity):
            item.quantity = previousQuantity
            if item.status == .consumed {
                item.status = .active
            }
            SpotlightManager.shared.indexItem(item)
            NotificationManager.shared.scheduleExpiryNotification(for: item)
        }

        saveChanges()
        clearUndoAction()
        return true
    }
    
    /// Consolidate saving and external sync (Widgets)
    private func saveChanges() {
        try? modelContext.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
    
    /// Check if undo is available
    var canUndo: Bool {
        lastAction != nil
    }
}

// MARK: - Undoable Action

/// Represents an action that can be undone
enum UndoableAction {
    case consume(item: Item, previousStatus: ItemStatus, previousQuantity: Int)
    case discard(item: Item, previousStatus: ItemStatus)
    case decrementQuantity(item: Item, previousQuantity: Int)
}
