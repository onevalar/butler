import Foundation

/// Plain "what do I have" questions answered on the phone at once, without waiting for the model.
/// Deliberately narrow: only a short question about one category, one place, one thing, or what's
/// about to expire. Anything that needs judgement ("修自行车要用什么") goes to the model.
enum LocalInventoryQuery {
    struct Answer: Equatable {
        let text: String
        let title: String
        let lots: [LotFacts]

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.text == rhs.text && lhs.title == rhs.title && lhs.lots.map(\.id) == rhs.lots.map(\.id)
        }
    }

    private static let asks = ["有什么", "有哪些", "有没有", "都有啥", "有啥", "在哪", "放哪", "快过期", "快到期", "要过期", "列一下", "列出"]

    /// Removed from the sentence one by one; what is left must be the one thing asked about.
    private static let fillers = [
        "我想看看", "我想看", "我想知道", "帮我看看", "帮我看一下", "帮我查查", "帮我查一下", "帮我列一下", "帮我",
        "看一下", "看看", "查一下", "查查", "列一下", "列出来", "列出", "给我", "我家", "家里", "家中", "现在",
        "有什么", "有哪些", "有没有", "都有啥", "有啥", "还有", "都有", "哪些", "什么",
        "在哪里", "在哪儿", "在哪", "放哪里了", "放哪了", "放哪", "放在哪", "里面", "里头",
        "东西", "我的", "我", "都", "里", "的", "呢", "吗", "了", "一下", "啊", "呀",
    ]

    private static let categoryWords: [(String, ItemCategory)] = [
        ("衣服", .clothing), ("衣物", .clothing), ("衣裳", .clothing), ("穿", .clothing),
        ("吃", .food), ("食品", .food), ("食物", .food),
        ("药品", .medicine), ("药", .medicine),
        ("工具", .tools), ("日用品", .household),
        ("数码", .electronics), ("电器", .electronics), ("家电", .electronics), ("电子产品", .electronics),
    ]

    /// Only the shape of the sentence, cheap enough to check on every keystroke.
    static func isCandidate(_ text: String) -> Bool {
        let value = normalized(text)
        return value.count <= 20 && asks.contains { value.contains($0) }
    }

    static func answer(_ text: String, facts: [LotFacts]) -> Answer? {
        let value = normalized(text)
        guard isCandidate(value) else { return nil }
        let soon = ["快过期", "快到期", "要过期"].contains { value.contains($0) }
        var rest = value
        for phrase in ["快过期", "快到期", "要过期"] + fillers { rest = rest.replacingOccurrences(of: phrase, with: "") }
        if soon {
            guard rest.isEmpty || rest == "冰箱" else { return nil }
            let fridge = rest == "冰箱"
            let lots = facts.filter { lot in
                guard !lot.quantityOnly, let days = lot.daysLeft, days <= 7 else { return false }
                return !fridge || isFridge(lot.storageLocation)
            }.sorted(by: InventoryGroups.urgencyOrder)
            let title = fridge ? "冰箱里快到期的" : "快到期的"
            return Answer(text: lots.isEmpty ? "这周没有快到期的东西。" : "这些快到期了：", title: title, lots: lots)
        }
        guard !rest.isEmpty, rest.count <= 8 else { return nil }
        if let category = categoryWords.first(where: { $0.0 == rest })?.1 {
            let lots = facts.filter { $0.category == category }.sorted(by: InventoryGroups.urgencyOrder)
            return Answer(text: lots.isEmpty ? "家里还没记过\(category.title)。" : "家里有 \(lots.count) 样\(category.title)：",
                          title: category.title, lots: lots)
        }
        if rest == "冰箱" {
            let lots = facts.filter { isFridge($0.storageLocation) }.sorted(by: InventoryGroups.urgencyOrder)
            return Answer(text: lots.isEmpty ? "冰箱里还没记东西。" : "冰箱里有 \(lots.count) 样：", title: "冰箱里", lots: lots)
        }
        let places = Set(facts.compactMap(\.storageLocation)).filter { !$0.isEmpty && ($0 == rest || ($0.count >= 2 && rest.contains($0)) || (rest.count >= 2 && $0.contains(rest))) }
        if !places.isEmpty {
            let lots = facts.filter { $0.storageLocation.map(places.contains) == true }.sorted(by: InventoryGroups.urgencyOrder)
            let name = places.count == 1 ? places.first! : rest
            return Answer(text: "\(name)里有 \(lots.count) 样：", title: "\(name)里", lots: lots)
        }
        let named = facts.filter { lot in
            lot.name.localizedCaseInsensitiveContains(rest)
                || (lot.name.count >= 2 && rest.localizedCaseInsensitiveContains(lot.name))
                || (lot.brand.map { !$0.isEmpty && rest.localizedCaseInsensitiveContains($0) } ?? false)
        }.sorted(by: InventoryGroups.urgencyOrder)
        // Nothing by that name: the model may know a stand-in, so let it answer.
        guard !named.isEmpty else { return nil }
        return Answer(text: "找到 \(named.count) 样：", title: rest, lots: named)
    }

    static func collection(_ answer: Answer) -> ItemCollection? {
        guard !answer.lots.isEmpty else { return nil }
        return ItemCollection(title: answer.title, items: answer.lots.map { .init(id: $0.id, name: $0.name, reason: "") })
    }

    private static func isFridge(_ location: String?) -> Bool {
        guard let location else { return false }
        return ["冷藏", "冷冻", "冰箱"].contains { location.contains($0) }
    }

    static func normalized(_ text: String) -> String {
        text.filter { !" \n\t？?。！!，,、~～".contains($0) }
    }
}

/// "去掉自攻螺丝" said while a list is showing: take that line off the list (the thing stays at home).
enum ShownListEdit {
    private static let verbs = ["去掉", "删掉", "拿掉", "移除", "不要", "划掉", "去除"]
    private static let tails = ["这一样", "这一项", "这个", "不用带", "不带", "不用", "就行", "吧", "了"]

    static func isCandidate(_ text: String) -> Bool {
        let value = LocalInventoryQuery.normalized(text)
        return value.count <= 24 && verbs.contains { value.hasPrefix($0) }
    }

    /// The entries to remove, or nil when the sentence doesn't clearly name lines on this list.
    static func removals(_ text: String, from collection: ItemCollection) -> [ItemCollection.Entry]? {
        var value = LocalInventoryQuery.normalized(text)
        guard let verb = verbs.first(where: { value.hasPrefix($0) }) else { return nil }
        value.removeFirst(verb.count)
        for tail in tails where value.hasSuffix(tail) { value.removeLast(tail.count) }
        let names = value.split(whereSeparator: { "和跟与及".contains($0) }).map(String.init).filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        var hits: [ItemCollection.Entry] = []
        for name in names {
            let matches = collection.items.filter { $0.name.localizedCaseInsensitiveContains(name) || (name.count >= 2 && name.localizedCaseInsensitiveContains($0.name)) }
            // Every named thing must be on the list, and name exactly one line, or the model decides.
            guard matches.count == 1 else { return nil }
            hits.append(matches[0])
        }
        return hits
    }
}
