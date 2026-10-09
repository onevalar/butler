import Foundation

/// Browsing always returns individual lots, including separate purchases of the same product.
enum InventoryOrder: String, CaseIterable {
    case attention = "需要留意优先"
    case name = "按名称"
    case newest = "最近添加"
}

enum InventoryCatalog {
    static func items(_ facts: [LotFacts], query: String = "", category: ItemCategory? = nil,
                      place: String? = nil, order: InventoryOrder = .attention) -> [LotFacts] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return facts.filter { lot in
            guard lot.state == .active, category == nil || category == lot.category,
                  place == nil || place == StorageLocation.groupName(for: lot.storageLocation) else { return false }
            let text = [lot.name, lot.brand ?? "", lot.category.title, lot.storageLocation ?? "", lot.profile?.searchText ?? ""]
                .joined(separator: " ")
            return words.allSatisfy { text.localizedStandardContains($0) }
        }.sorted { a, b in
            switch order {
            case .attention:
                if InventoryGroups.urgencyOrder(a, b) { return true }
                if InventoryGroups.urgencyOrder(b, a) { return false }
            case .newest:
                if a.startedAt != b.startedAt { return a.startedAt > b.startedAt }
            case .name: break
            }
            let comparison = a.name.localizedStandardCompare(b.name)
            return comparison == .orderedSame ? a.id.uuidString < b.id.uuidString : comparison == .orderedAscending
        }
    }

    static func symbol(for lot: LotFacts) -> String {
        if lot.isMedicine || lot.category == .medicine { return "pills.fill" }
        let names: [(String, [String])] = [
            ("waterbottle.fill", ["饮用水", "纯净水", "矿泉水", "苏打水", "牛奶", "酸奶"]),
            ("cup.and.saucer.fill", ["咖啡", "茶", "杯"]),
            ("carrot.fill", ["蔬菜", "青菜", "萝卜"]),
            ("leaf.fill", ["苹果", "香蕉", "水果", "草莓"]),
            ("fish.fill", ["鱼", "虾"]),
            ("takeoutbag.and.cup.and.straw.fill", ["零食", "饼干", "面包"]),
            ("drop.fill", ["洗衣", "洗发", "洗手", "沐浴", "清洁"]),
            ("headphones", ["耳机"]), ("laptopcomputer", ["电脑"]),
            ("iphone", ["手机"]), ("umbrella.fill", ["雨伞"]),
            ("tshirt.fill", ["衣", "外套", "衬衫"])
        ]
        return names.first { $0.1.contains(where: lot.name.contains) }?.0 ?? (lot.category == .food ? "fork.knife" : lot.category.symbol)
    }

    static func status(for lot: LotFacts) -> String? {
        if lot.isDurable {
            return lot.profile?.availability == nil || lot.profile?.availability == "ready" ? nil : lot.profile?.availabilityLabel
        }
        if lot.quantityOnly { return lot.isRunningLow ? "已用完" : nil }
        guard let days = lot.daysLeft, let date = lot.governingDate else { return "未记录日期" }
        if days < 0 { return lot.dateStatusLabel }
        let ending: String
        switch lot.governingDateKind {
        case .packageExpiry: ending = "到期"
        case .estimatedExpiry: ending = "预计到期"
        case .plannedUseBy: ending = "前用完"
        case nil: ending = "到期"
        }
        return (days == 0 ? "今天" : days == 1 ? "明天" : date.monthDay) + ending
    }
}
