import Foundation

/// The three ways the 物品 page sorts things into tiles.
enum InventoryLens: String, CaseIterable, Hashable, Codable {
    case category = "分类", place = "位置", expiry = "到期"
}

/// One tile on the 物品 page: a group of things that can be opened on its own page.
struct InventoryGroup: Identifiable, Equatable {
    enum Key: Hashable, Codable {
        case category(ItemCategory)
        case place(String)
        case expiry(ExpiryBucket)
    }

    enum ExpiryBucket: String, CaseIterable, Codable {
        case expired, thisWeek, later, noDate, quantityOnly

        var title: String {
            switch self {
            case .expired: "已过期"
            case .thisWeek: "这周到期"
            case .later: "以后"
            case .noDate: "还没日期"
            case .quantityOnly: "只记数量"
            }
        }
    }

    let key: Key
    let title: String
    let symbol: String
    let lots: [LotFacts]
    /// Up to three names, most pressing first, so a tile shows what's inside without opening it.
    var preview: String { lots.prefix(3).map(\.name).joined(separator: " · ") }
    /// Things in this group that need attention soon (expired, due within 3 days, or running out).
    let urgent: Int
    /// Something is already past its date or running out: the badge is red rather than orange.
    let pressing: Bool

    var id: Key { key }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key && lhs.lots.map(\.id) == rhs.lots.map(\.id) && lhs.urgent == rhs.urgent
    }
}

enum InventoryGroups {
    static func make(_ facts: [LotFacts], lens: InventoryLens) -> [InventoryGroup] {
        switch lens {
        case .category:
            return ItemCategory.allCases.compactMap { group(.category($0), facts: facts) }
        case .place:
            let places = Set(facts.map { StorageLocation.groupName(for: $0.storageLocation) })
            return places.sorted { StorageLocation.sortKey($0) < StorageLocation.sortKey($1) }
                .compactMap { group(.place($0), facts: facts) }
        case .expiry:
            return InventoryGroup.ExpiryBucket.allCases.compactMap { group(.expiry($0), facts: facts) }
        }
    }

    /// The group a tile opens, rebuilt from current facts (it may have changed since the tile was drawn).
    static func group(_ key: InventoryGroup.Key, facts: [LotFacts]) -> InventoryGroup? {
        let lots = facts.filter { contains(key, $0) }.sorted { urgencyOrder($0, $1) }
        guard !lots.isEmpty else { return nil }
        let needing = lots.filter { needsAttention($0) }
        return InventoryGroup(key: key, title: title(key), symbol: symbol(key), lots: lots, urgent: needing.count,
                              pressing: needing.contains { $0.isRunningLow || ($0.daysLeft ?? 1) < 0 })
    }

    static func title(_ key: InventoryGroup.Key) -> String {
        switch key {
        case .category(let category): category.title
        case .place(let place): place
        case .expiry(let bucket): bucket.title
        }
    }

    static func contains(_ key: InventoryGroup.Key, _ lot: LotFacts) -> Bool {
        switch key {
        case .category(let category): return lot.category == category
        case .place(let place): return StorageLocation.groupName(for: lot.storageLocation) == place
        case .expiry(let bucket):
            if lot.quantityOnly { return bucket == .quantityOnly }
            guard let days = lot.daysLeft else { return bucket == .noDate }
            switch bucket {
            case .expired: return days < 0
            case .thisWeek: return (0...7).contains(days)
            case .later: return days > 7
            case .noDate, .quantityOnly: return false
            }
        }
    }

    static func needsAttention(_ lot: LotFacts) -> Bool {
        if lot.quantityOnly { return lot.isRunningLow }
        guard let days = lot.daysLeft else { return false }
        return days <= 3
    }

    static func urgencyOrder(_ a: LotFacts, _ b: LotFacts) -> Bool {
        let left = (a.isRunningLow ? -1 : 0, a.quantityOnly ? Int.max - 1 : (a.daysLeft ?? .max))
        let right = (b.isRunningLow ? -1 : 0, b.quantityOnly ? Int.max - 1 : (b.daysLeft ?? .max))
        if left != right { return left < right }
        return a.name < b.name
    }

    static func symbol(_ key: InventoryGroup.Key) -> String {
        switch key {
        case .category(let category): return category.symbol
        case .expiry(let bucket):
            switch bucket {
            case .expired: return "exclamationmark.triangle"
            case .thisWeek: return "clock"
            case .later: return "calendar"
            case .noDate: return "calendar.badge.exclamationmark"
            case .quantityOnly: return "number"
            }
        case .place(let place):
            let table: [(String, String)] = [
                ("冷冻", "snowflake"), ("冷藏", "refrigerator"), ("冰箱", "refrigerator"), ("药", "cross.case"),
                ("零食", "takeoutbag.and.cup.and.straw"), ("厨房", "fork.knife"), ("卫生间", "drop"), ("浴室", "drop"),
                ("洗手间", "drop"), ("衣柜", "hanger"), ("衣橱", "hanger"), ("阳台", "sun.max"), ("客厅", "sofa"),
                ("卧室", "bed.double"), ("书", "books.vertical"), ("玄关", "door.left.hand.open"), ("门口", "door.left.hand.open"),
                ("工具", "wrench.and.screwdriver"), ("车", "car"), ("抽屉", "archivebox"), ("箱", "shippingbox"),
                ("柜", "cabinet"), ("架", "square.stack.3d.up"), ("常温", "cabinet"),
            ]
            if place == StorageLocation.unspecified { return "questionmark.circle" }
            return table.first { place.contains($0.0) }?.1 ?? "square.grid.2x2"
        }
    }
}
