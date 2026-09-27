import Foundation

/// How soon a lot needs attention. Drives seal color and ordering everywhere.
enum UrgencyTier: Int, Comparable, Sendable {
    case overdue, today, soon, week, calm, undated

    static func < (lhs: UrgencyTier, rhs: UrgencyTier) -> Bool { lhs.rawValue < rhs.rawValue }

    init(daysLeft: Int?) {
        guard let daysLeft else { self = .undated; return }
        switch daysLeft {
        case ..<0: self = .overdue
        case 0: self = .today
        case 1...3: self = .soon
        case 4...7: self = .week
        default: self = .calm
        }
    }
}

/// Everything the UI needs to draw one lot, derived without touching persistence.
struct LotFacts: Identifiable, Sendable {
    let id: UUID
    let productID: UUID
    let name: String
    let brand: String?
    let glyph: Character
    let isMedicine: Bool
    let quantity: Int
    let unit: String
    let storageLocation: String?
    let governingDate: Date?
    let governingDateKind: LotDateKind?
    let daysLeft: Int?
    let packageDaysLeft: Int?
    let tier: UrgencyTier
    let startedAt: Date
    let revision: Int
    let state: InventoryLotState

    /// Things like drinking water or tissues: only how many are left matters, dates are ignored.
    let quantityOnly: Bool
    static let quantityOnlyCategory = "household"

    /// No date of any kind: Butler must ask instead of guessing.
    var needsDate: Bool { governingDate == nil && !quantityOnly }
    /// A quantity-only item that is about to run out.
    var isRunningLow: Bool { quantityOnly && quantity <= 1 }
    /// The user said "冰箱" without saying which compartment.
    var needsCompartment: Bool { storageLocation == StorageLocation.ambiguousFridge }

    init(lot: InventoryLot, product: CatalogProduct?, now: Date = Date(), calendar: Calendar = .current) {
        let name = product?.canonicalName ?? "未命名"
        id = lot.id
        productID = lot.productID
        self.name = name
        brand = product?.brand
        isMedicine = LotGlyph.isMedicine(name: name, category: product?.categoryRawValue)
        quantityOnly = product?.categoryRawValue == LotFacts.quantityOnlyCategory
        glyph = LotGlyph.glyph(for: name, isMedicine: isMedicine)
        quantity = lot.quantity
        unit = lot.unit
        storageLocation = lot.storageLocation
        startedAt = lot.purchasedAt ?? lot.createdAt
        revision = lot.revision
        state = lot.state
        packageDaysLeft = lot.packageExpiryDate.map { LotFacts.days(from: now, to: $0, calendar: calendar) }

        let dated: [(LotDateKind, Date)] = quantityOnly ? [] : [
            lot.packageExpiryDate.map { (.packageExpiry, $0) },
            lot.estimatedExpiryDate.map { (.estimatedExpiry, $0) },
            lot.plannedUseByDate.map { (.plannedUseBy, $0) },
        ].compactMap { $0 }
        let earliest = dated.min { $0.1 < $1.1 }
        governingDate = earliest?.1
        governingDateKind = earliest?.0
        daysLeft = earliest.map { LotFacts.days(from: now, to: $0.1, calendar: calendar) }
        tier = UrgencyTier(daysLeft: daysLeft)
    }

    static func days(from now: Date, to date: Date, calendar: Calendar) -> Int {
        let start = calendar.startOfDay(for: now)
        let end = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    var stateLabel: String {
        switch state {
        case .active: return "在库"
        case .depleted: return "已用完"
        case .discarded: return "已丢弃"
        case .gifted: return "已送人"
        case .archived: return "已归档"
        }
    }

    func matchesSearch(_ query: String) -> Bool {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let soon = text.contains("快过期") || text.contains("快到期")
        for phrase in ["快过期", "快到期", "还有吗", "有没有", "还有", "？", "?"] {
            text = text.replacingOccurrences(of: phrase, with: "")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if soon {
            if text.hasPrefix("的") { text.removeFirst() }
            guard let packageDaysLeft, (0...7).contains(packageDaysLeft) else { return false }
        }
        if text == "药" || text == "药品" { return isMedicine }
        guard !text.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(text)
            || (brand?.localizedCaseInsensitiveContains(text) ?? false)
            || (storageLocation?.localizedCaseInsensitiveContains(text) ?? false)
    }

    /// Keep the meaning of the governing date wherever it is displayed.
    var dateKindLabel: String {
        switch governingDateKind {
        case .packageExpiry: return "包装有效期"
        case .estimatedExpiry: return "预计到期"
        case .plannedUseBy: return "计划用完"
        case nil: return "待补日期"
        }
    }

    var dateStatusLabel: String {
        if quantityOnly { return isRunningLow ? "只剩 \(quantity) \(unit)" : "剩 \(quantity) \(unit)" }
        guard let daysLeft else { return "待补日期" }
        if daysLeft < 0 {
            switch governingDateKind {
            case .packageExpiry: return "已过期 \(-daysLeft) 天"
            case .estimatedExpiry: return "已超过预计日期 \(-daysLeft) 天"
            case .plannedUseBy: return "已超过计划日期 \(-daysLeft) 天"
            case nil: return "待补日期"
            }
        }
        return "\(dateKindLabel) · \(timeLeftLabel)"
    }

    /// Short human phrase for the time left, e.g. "今天", "2 天", "4 个月".
    var timeLeftLabel: String {
        if quantityOnly { return dateStatusLabel }
        guard let daysLeft else { return "待补日期" }
        switch daysLeft {
        case ..<0: return dateStatusLabel
        case 0: return "今天"
        case 1...20: return "\(daysLeft) 天"
        case 21...59: return "\(daysLeft / 7) 周"
        case 60...364: return "\(daysLeft / 30) 个月"
        default: return "1 年+"
        }
    }
}

/// Picks the single character shown on an item's seal.
enum LotGlyph {
    /// Checked in order; more specific words come first.
    private static let table: [(String, Character)] = [
        ("酸奶", "酸"), ("奶酪", "酪"), ("牛奶", "奶"), ("鸡蛋", "蛋"), ("鸭蛋", "蛋"),
        ("方便面", "面"), ("挂面", "面"), ("面条", "面"), ("面包", "包"),
        ("冰激凌", "冰"), ("冰淇淋", "冰"), ("雪糕", "冰"),
        ("饺子", "饺"), ("水饺", "饺"), ("馄饨", "馄"), ("汤圆", "圆"),
        ("蚝油", "蚝"), ("酱油", "酱"), ("醋", "醋"), ("酱", "酱"),
        ("大米", "米"), ("食用油", "油"), ("盐", "盐"), ("糖", "糖"),
        ("咖啡", "咖"), ("茶", "茶"), ("果汁", "汁"), ("啤酒", "酒"),
        ("苹果", "果"), ("香蕉", "蕉"), ("水果", "果"), ("蔬菜", "菜"), ("青菜", "菜"),
        ("虾", "虾"), ("鱼", "鱼"), ("牛肉", "肉"), ("猪肉", "肉"), ("鸡肉", "肉"), ("肉", "肉"),
        ("纯净水", "水"), ("饮用水", "水"), ("矿泉水", "水"), ("苏打水", "水"), ("水", "水"),
        ("纸巾", "纸"), ("卫生纸", "纸"), ("抽纸", "纸"), ("洗衣", "洗"), ("洗发", "洗"),
        ("牙膏", "牙"), ("创可贴", "贴"), ("感冒", "感"),
    ]

    private static let medicineWords = [
        "药", "胶囊", "颗粒", "口服液", "布洛芬", "阿莫西林", "对乙酰氨基酚",
        "退烧", "止咳", "滴眼液", "维生素",
    ]

    static func isMedicine(name: String, category: String?) -> Bool {
        if category == "medicine" { return true }
        return medicineWords.contains { name.contains($0) }
    }

    static func glyph(for name: String, isMedicine: Bool) -> Character {
        if let hit = table.first(where: { name.contains($0.0) }) { return hit.1 }
        if isMedicine { return "药" }
        return name.first(where: { $0.isLetter }) ?? "物"
    }
}

enum StorageLocation {
    /// Stored when the user only said "冰箱"; Butler asks for the compartment later.
    static let ambiguousFridge = "冰箱"
    static let unspecified = "还没说放哪"

    private static let order = ["冷藏", "冷冻", ambiguousFridge, "常温", "零食柜", "厨房", "药箱"]

    static func groupName(for location: String?) -> String {
        guard let location, !location.isEmpty else { return unspecified }
        return location
    }

    static func sortKey(_ group: String) -> (Int, String) {
        if group == unspecified { return (Int.max, group) }
        return (order.firstIndex(of: group) ?? order.count, group)
    }
}

extension EvidenceSourceKind {
    /// Plain-language provenance, written as the butler speaking.
    var label: String {
        switch self {
        case .userStated, .heuristicParser: return "你说的"
        case .userEdited: return "你改过"
        case .ocr: return "拍照识别"
        case .orderImport: return "来自订单"
        case .modelInference: return "我推断的"
        case .habitInference: return "按习惯推断"
        case .systemEstimate: return "我估算的"
        case .legacyUnknown: return "来源不明"
        }
    }

    /// Values Butler guessed rather than heard or saw; shown with a dashed underline.
    var isInference: Bool {
        switch self {
        case .modelInference, .habitInference, .systemEstimate: return true
        default: return false
        }
    }
}
