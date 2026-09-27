import Foundation

/// How long Butler suggests using a shelf-stable product within, as a personal plan (never a package date).
enum PlanHorizon: Equatable, Sendable {
    case days(Int)
    case months(Int)

    var phrase: String {
        switch self {
        case .days(let days): "\(days) 天"
        case .months(let months): months % 12 == 0 ? "\(months / 12) 年" : "\(months) 个月"
        }
    }

    func date(from reference: Date, calendar: Calendar) -> Date? {
        switch self {
        case .days(let days): calendar.date(byAdding: .day, value: days, to: reference)
        case .months(let months): calendar.date(byAdding: .month, value: months, to: reference)
        }
    }
}

/// What kind of thing a product is decides which questions are worth asking.
enum ProductKind: Equatable, Sendable {
    /// Packaged perishable (milk, yoghurt, eggs). "放冰箱" means 冷藏; the printed date is asked for, never guessed.
    case fresh
    /// Loose produce with no package date to read: a typical "eat within" plan is suggested instead of asking.
    case produce(PlanHorizon)
    /// Could live in either compartment, and it matters (days vs. months): "放冰箱" must be asked.
    case freezable
    /// Shelf-stable: a plan date is suggested so it doesn't sit forever.
    case pantry(PlanHorizon)
    /// Consumables without a meaningful expiry: only the quantity is tracked.
    case household
    /// Strict mode: nothing is guessed, dates must come from the package.
    case medicine
    case unknown

    var categoryRawValue: String? {
        switch self {
        case .medicine: "medicine"
        case .household: "household"
        default: nil
        }
    }

    var suggestedPlan: PlanHorizon? {
        switch self {
        case .pantry(let horizon), .produce(let horizon): horizon
        default: nil
        }
    }
}

/// Everyday Chinese household vocabulary. Longer words win, so "蚝油" beats "油" and "酸奶" beats "奶".
/// Extend freely: the unit is the default when the user doesn't say one ("买了牛奶" → 1 瓶).
enum ProductLexicon {
    struct Entry: Sendable {
        let word: String
        let unit: String
        let kind: ProductKind
    }

    static func lookup(_ name: String) -> Entry? {
        sorted.first { name.contains($0.word) }
    }

    /// The longest known word that `text` starts with, used to split "酸奶鸡蛋" into two products.
    static func longestWord(prefixing text: Substring, minimumLength: Int) -> String? {
        sorted.first { $0.word.count >= minimumLength && text.hasPrefix($0.word) }?.word
    }

    private static let sorted = entries.sorted { $0.word.count > $1.word.count }

    private static let entries: [Entry] = {
        func fresh(_ words: [(String, String)]) -> [Entry] { words.map { Entry(word: $0.0, unit: $0.1, kind: .fresh) } }
        func freezable(_ words: [(String, String)]) -> [Entry] { words.map { Entry(word: $0.0, unit: $0.1, kind: .freezable) } }
        func produce(_ days: Int, _ words: [(String, String)]) -> [Entry] {
            words.map { Entry(word: $0.0, unit: $0.1, kind: .produce(.days(days))) }
        }
        func pantry(_ horizon: PlanHorizon, _ words: [(String, String)]) -> [Entry] {
            words.map { Entry(word: $0.0, unit: $0.1, kind: .pantry(horizon)) }
        }
        func household(_ words: [(String, String)]) -> [Entry] { words.map { Entry(word: $0.0, unit: $0.1, kind: .household) } }
        func medicine(_ words: [(String, String)]) -> [Entry] { words.map { Entry(word: $0.0, unit: $0.1, kind: .medicine) } }

        return fresh([
            ("牛奶", "瓶"), ("鲜奶", "瓶"), ("酸奶", "杯"), ("奶酪", "块"), ("芝士", "块"), ("黄油", "块"),
            ("鸡蛋", "个"), ("鸭蛋", "个"), ("蛋", "个"), ("豆腐", "块"), ("豆浆", "瓶"),
            ("面包", "个"), ("吐司", "袋"), ("蛋糕", "个"), ("果汁", "瓶"), ("啤酒", "罐"),
        ])
        // Typical fridge life for loose produce, used only as a personal "eat within" suggestion.
        + produce(3, [("草莓", "盒"), ("青菜", "把"), ("菠菜", "把"), ("玉米", "根"), ("包子", "个"), ("馒头", "个")])
        + produce(4, [("生菜", "个"), ("蘑菇", "盒"), ("蔬菜", "份"), ("菜", "份")])
        + produce(5, [("香蕉", "根"), ("桃", "个"), ("葡萄", "串"), ("西瓜", "个"), ("芒果", "个"), ("水果", "份"),
                      ("黄瓜", "根")])
        + produce(7, [("蓝莓", "盒"), ("白菜", "个"), ("西红柿", "个"), ("番茄", "个")])
        + produce(10, [("橘子", "个"), ("猕猴桃", "个")])
        + produce(14, [("苹果", "个"), ("橙子", "个"), ("梨", "个"), ("胡萝卜", "根")])
        + produce(21, [("土豆", "个"), ("洋葱", "个")])
        + freezable([
            ("冰激凌", "个"), ("冰淇淋", "个"), ("雪糕", "支"), ("冰棍", "支"),
            ("饺子", "袋"), ("水饺", "袋"), ("汤圆", "袋"), ("馄饨", "袋"), ("鸡", "只"),
            ("猪肉", "份"), ("牛肉", "份"), ("羊肉", "份"), ("鸡肉", "份"), ("鸡腿", "个"), ("鸡翅", "份"),
            ("排骨", "份"), ("肉", "份"), ("虾", "份"), ("虾仁", "袋"), ("鱼", "条"), ("三文鱼", "份"),
        ])
        + pantry(.months(3), [("方便面", "包"), ("泡面", "包"), ("巧克力", "块"), ("麦片", "袋"), ("奶粉", "罐")])
        + pantry(.months(2), [("饼干", "包"), ("薯片", "包"), ("零食", "包"), ("坚果", "袋"), ("饮料", "瓶"), ("可乐", "瓶")])
        + pantry(.months(6), [
            ("挂面", "包"), ("面条", "包"), ("大米", "袋"), ("米", "袋"), ("面粉", "袋"),
            ("食用油", "桶"), ("油", "瓶"), ("酱油", "瓶"), ("醋", "瓶"), ("蚝油", "瓶"), ("调料", "份"),
            ("咖啡", "包"), ("茶叶", "包"),
        ])
        + pantry(.months(12), [("罐头", "罐"), ("盐", "包"), ("糖", "包")])
        + household([
            ("矿泉水", "瓶"), ("纯净水", "瓶"), ("饮用水", "瓶"), ("苏打水", "瓶"), ("桶装水", "桶"), ("瓶装水", "瓶"),
            ("纸巾", "包"), ("抽纸", "包"), ("卫生纸", "卷"), ("湿巾", "包"), ("洗衣液", "瓶"), ("洗衣粉", "袋"),
            ("洗洁精", "瓶"), ("洗发水", "瓶"), ("沐浴露", "瓶"), ("牙膏", "支"), ("牙刷", "支"),
            ("垃圾袋", "卷"), ("保鲜膜", "卷"), ("电池", "节"), ("肥皂", "块"), ("香皂", "块"),
        ])
        + medicine([
            ("布洛芬", "盒"), ("感冒灵", "盒"), ("感冒药", "盒"), ("退烧药", "盒"), ("阿莫西林", "盒"),
            ("维生素", "瓶"), ("创可贴", "盒"), ("胶囊", "盒"), ("颗粒", "盒"), ("口服液", "盒"),
            ("眼药水", "支"), ("滴眼液", "支"), ("碘伏", "瓶"), ("药", "盒"),
        ])
    }()
}
