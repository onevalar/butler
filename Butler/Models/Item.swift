//
//  Item.swift
//  Butler
//
//  Created by 安宇佳 on 2026/1/6.
//

import Foundation
import SwiftData
import SwiftUI

// MARK: - Item Status

/// The lifecycle status of an item in Butler
enum ItemStatus: String, Codable, CaseIterable, Sendable {
    /// Actively monitored item with valid expiry information
    case active = "active"
    /// Item requires user attention (e.g., missing expiry date for food/medicine)
    case actionRequired = "actionRequired"
    /// Item has been consumed (kept for history)
    case consumed = "consumed"
    /// Item has been discarded (kept for history)
    case discarded = "discarded"
    
    var displayName: String {
        switch self {
        case .active: return "监控中"
        case .actionRequired: return "待补全"
        case .consumed: return "已消耗"
        case .discarded: return "已丢弃"
        }
    }
    
    var iconName: String {
        switch self {
        case .active: return "checkmark.circle.fill"
        case .actionRequired: return "exclamationmark.circle.fill"
        case .consumed: return "fork.knife"
        case .discarded: return "trash.fill"
        }
    }
}

// MARK: - Item Type

/// The category type of an item
enum ItemType: String, Codable, CaseIterable, Sendable {
    /// Fresh produce with short shelf life
    case fresh = "fresh"
    /// Pantry items with longer shelf life
    case pantry = "pantry"
    /// Medicines requiring strict expiry tracking
    case medicine = "medicine"
    /// General household items
    case general = "general"
    
    var displayName: String {
        switch self {
        case .fresh: return "生鲜"
        case .pantry: return "干货"
        case .medicine: return "药品"
        case .general: return "日用"
        }
    }
    
    var iconName: String {
        switch self {
        case .fresh: return "leaf.fill"
        case .pantry: return "takeoutbag.and.cup.and.straw.fill"
        case .medicine: return "cross.case.fill"
        case .general: return "shippingbox.fill"
        }
    }
    
    var defaultColor: Color {
        switch self {
        case .fresh: return .green
        case .pantry: return .orange
        case .medicine: return .red
        case .general: return .blue
        }
    }
    
    /// Whether this item type is considered "sensitive" and requires explicit expiry date
    /// R1: Food and Medicine items must have verified expiry dates
    var isSensitive: Bool {
        switch self {
        case .fresh, .pantry, .medicine:
            return true
        case .general:
            return false
        }
    }
    
    /// Default duration for items without explicit expiry dates
    /// R2: General items get auto-filled default duration
    var defaultDuration: TimeInterval {
        switch self {
        case .fresh: return 7 * 24 * 60 * 60         // 7 days
        case .pantry: return 180 * 24 * 60 * 60      // 180 days
        case .medicine: return 365 * 24 * 60 * 60    // 1 year
        case .general: return 365 * 24 * 60 * 60     // 1 year (R2 default)
        }
    }
}

// MARK: - Item Model

/// The core data model representing an inventory item in Butler
@Model
final class Item {
    
    // MARK: - Core Properties
    
    /// Unique identifier for the item
    var id: UUID
    
    /// Display name of the item
    var name: String
    
    /// Quantity of the item
    var quantity: Int
    
    /// Category type of the item
    var typeRawValue: String
    
    /// Current lifecycle status
    var statusRawValue: String
    
    // MARK: - Date Properties
    
    /// When the item was added to inventory
    var createdAt: Date
    
    /// When the item was last modified
    var updatedAt: Date
    
    /// The expiration date of the item
    var expiryDate: Date?
    
    /// Whether the expiry date is estimated (AI-generated) or verified (user-confirmed)
    /// R1: If true and item is sensitive, should be marked actionRequired
    var isEstimated: Bool
    
    // MARK: - Evidence Properties
    
    /// Local image ID for evidence storage (photo of packaging, label, etc.)
    var localImageID: String?
    
    /// Optional notes from user or AI
    var notes: String?

    /// Storage location (e.g., "冷冻", "冷藏", "常温")
    var storageLocation: String?

    /// Unit of measurement (e.g., "瓶", "盒", "袋"). Nil defaults to "个" in display.
    var unit: String?

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        name: String,
        quantity: Int = 1,
        unit: String? = nil,
        type: ItemType = .general,
        status: ItemStatus = .active,
        expiryDate: Date? = nil,
        isEstimated: Bool = true,
        localImageID: String? = nil,
        notes: String? = nil,
        storageLocation: String? = nil
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.typeRawValue = type.rawValue
        self.statusRawValue = status.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
        self.expiryDate = expiryDate
        self.isEstimated = isEstimated
        self.localImageID = localImageID
        self.notes = notes
        self.storageLocation = storageLocation
    }
    
    // MARK: - Computed Properties (Type-safe enums)
    
    /// The item type as an enum
    var type: ItemType {
        get { ItemType(rawValue: typeRawValue) ?? .general }
        set { typeRawValue = newValue.rawValue }
    }
    
    /// The item status as an enum
    var status: ItemStatus {
        get { ItemStatus(rawValue: statusRawValue) ?? .active }
        set { statusRawValue = newValue.rawValue }
    }
    
    // MARK: - Helper Computed Properties
    
    /// Number of days remaining until expiry (-1 if no expiry date)
    var daysRemaining: Int? {
        guard let expiryDate else { return nil }
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date())
        let expiry = calendar.startOfDay(for: expiryDate)
        let components = calendar.dateComponents([.day], from: now, to: expiry)
        return components.day
    }
    
    /// Urgency level based on days remaining
    var urgencyLevel: UrgencyLevel {
        guard let days = daysRemaining else { return .unknown }
        
        if days < 0 {
            return .expired
        } else if days <= 3 {
            return .critical  // Red zone
        } else if days <= 7 {
            return .warning   // Yellow zone
        } else {
            return .safe      // Green zone
        }
    }
    
    /// Color representing the item's urgency status
    var statusColor: Color {
        // Special case for actionRequired items
        if status == .actionRequired {
            return .orange
        }
        
        return urgencyLevel.color
    }
    
    /// Formatted expiry date string
    var formattedExpiry: String {
        guard let expiryDate else {
            return "未设置到期日"
        }
        
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        return formatter.string(from: expiryDate)
    }
    
    /// User-friendly description of time remaining
    var expiryDescription: String {
        guard let days = daysRemaining else {
            return "未知"
        }
        
        if days < 0 {
            return "已过期 \(abs(days)) 天"
        } else if days == 0 {
            return "今天过期"
        } else if days == 1 {
            return "明天过期"
        } else if days <= 7 {
            return "\(days) 天后过期"
        } else if days <= 30 {
            let weeks = days / 7
            return "约 \(weeks) 周后过期"
        } else {
            let months = days / 30
            return "约 \(months) 个月后过期"
        }
    }
    
    /// Whether this item is in an active/monitored state
    var isActive: Bool {
        status == .active || status == .actionRequired
    }
    
    /// Whether this item has been archived (consumed or discarded)
    var isArchived: Bool {
        status == .consumed || status == .discarded
    }
    
    /// Whether this item needs user attention
    var needsAttention: Bool {
        status == .actionRequired || urgencyLevel == .critical || urgencyLevel == .expired
    }
}

// MARK: - Urgency Level

/// Represents the urgency level of an item based on expiry
enum UrgencyLevel: Int, Comparable, Sendable {
    case expired = 0
    case critical = 1   // < 3 days (Red zone)
    case warning = 2    // < 7 days (Yellow zone)
    case safe = 3       // >= 7 days (Green zone)
    case unknown = 4    // No expiry date
    
    var color: Color {
        switch self {
        case .expired: return .red.opacity(0.8)
        case .critical: return .red
        case .warning: return .yellow
        case .safe: return .green
        case .unknown: return .gray
        }
    }
    
    var displayName: String {
        switch self {
        case .expired: return "已过期"
        case .critical: return "即将过期"
        case .warning: return "注意"
        case .safe: return "安全"
        case .unknown: return "未知"
        }
    }
    
    static func < (lhs: UrgencyLevel, rhs: UrgencyLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
