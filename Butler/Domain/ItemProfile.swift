import Foundation

/// Attributes describe the owned item, not every purchase of the same catalog product.
enum ItemCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case food, medicine, household, clothing, electronics, tools, other
    var id: Self { self }
    var title: String { switch self {
    case .food: "食品"; case .medicine: "药品"; case .household: "日用品"
    case .clothing: "衣物"; case .electronics: "数码家电"; case .tools: "工具"; case .other: "其他物品"
    } }
    var symbol: String { switch self {
    case .food: "carrot"; case .medicine: "pills"; case .household: "shippingbox"
    case .clothing: "tshirt"; case .electronics: "desktopcomputer"; case .tools: "wrench.and.screwdriver"; case .other: "square.grid.2x2"
    } }
    var durable: Bool { [.clothing, .electronics, .tools, .other].contains(self) }
}

struct ItemProfile: Codable, Equatable, Sendable {
    var category: ItemCategory
    var attributes: [String: String] = [:]
    var tags: [String] = []
    /// ready, laundry, lent, repair. Kept distinct from inventory closure.
    var availability: String = "ready"
    var photo: Data?

    var availabilityLabel: String {
        switch availability { case "laundry": "待清洗"; case "lent": "已借出"; case "repair": "维修中"; default: "可使用" }
    }
    var searchText: String {
        ([category.title, availabilityLabel] + tags + attributes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }).joined(separator: " ")
    }
    func validate() throws {
        guard attributes.count <= 16, attributes.allSatisfy({ !$0.key.isEmpty && $0.key.count <= 30 && $0.value.count <= 240 }),
              tags.count <= 20, tags.allSatisfy({ !$0.isEmpty && $0.count <= 40 }),
              ["ready", "laundry", "lent", "repair"].contains(availability), (photo?.count ?? 0) <= 4_000_000 else {
            throw ButlerTools.ToolError("物品资料过长或状态无效，请精简后重试")
        }
    }
    /// Local classification only supplies a default; users may correct it.
    static func inferred(name: String, legacyCategory: String?) -> Self {
        if legacyCategory == "medicine" || LotGlyph.isMedicine(name: name, category: legacyCategory) { return Self(category: .medicine) }
        if let kind = ProductLexicon.lookup(name)?.kind, kind != .unknown { return Self(category: kind == .medicine ? .medicine : kind == .household ? .household : .food) }
        for (category, words) in [
            (ItemCategory.clothing, ["衣", "裤", "裙", "鞋", "袜", "帽", "围巾", "外套", "衬衫"]),
            (.electronics, ["电脑", "手机", "耳机", "充电", "电器", "相机", "键盘"]),
            (.tools, ["螺丝刀", "扳手", "锤", "钳", "雨伞", "手电", "工具"])
        ] where words.contains(where: name.contains) { return Self(category: category) }
        if legacyCategory == LotFacts.quantityOnlyCategory { return Self(category: .household) }
        return Self(category: .other)
    }
}
