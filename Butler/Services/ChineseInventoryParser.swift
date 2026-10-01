import Foundation

/// A deterministic, on-device reader for everyday Chinese shopping talk.
/// "今天囤了点酸奶，牛奶两瓶放冰箱了" → items, and for every fact whether the user actually said it.
/// It never invents package dates; vague words become clearly-marked guesses or questions.
enum ChineseInventoryParser {
    struct Item: Equatable, Sendable {
        var name: String
        var quantity: Int
        /// The words the user used for the amount; nil when Butler defaulted to 1.
        var quantityRaw: String?
        /// A spoken amount Butler can't store yet ("五百克"), kept so the default is explainable.
        var amountNote: String?
        var unit: String
        var unitStated: Bool
        var kind: ProductKind
        var storage: StorageHint?
        var packageExpiry: HeardDate?
        var estimatedExpiry: HeardDate?
        var plannedUseBy: HeardDate?
    }

    struct HeardDate: Equatable, Sendable {
        let date: Date
        let raw: String
        /// The words were vague ("尽快") and Butler picked the concrete day.
        let isGuess: Bool
    }

    struct StorageHint: Equatable, Sendable {
        /// 冷冻 / 冷藏 / 常温 / 零食柜 …, or `StorageLocation.ambiguousFridge` for a bare "冰箱".
        let location: String
        let raw: String
    }

    struct Result: Sendable {
        var items: [Item]
        /// The user talked about finishing or throwing something away, which this reader doesn't record.
        var mentionsUsingUp: Bool
    }

    static func parse(_ text: String, referenceDate: Date, calendar: Calendar) -> Result {
        var items: [Item] = []
        var mentionsUsingUp = false
        var previousClauseItems: [Int] = []
        /// The last thing named in a "用完了" remark, so "牛奶喝完了又买了两瓶" knows what the two are.
        var lastMentioned: String?

        for clause in clauses(of: normalize(text)) {
            var clauseItems: [Int] = []
            var pending = Details()

            for part in parts(of: clause) {
                var working = remove(noise, from: part)
                let details = extractDetails(from: &working, referenceDate: referenceDate, calendar: calendar)
                let usingUp = matches(usingUpPattern, working)
                if usingUp {
                    mentionsUsingUp = true
                    working = remove(usingUpPattern, from: working)
                }
                let spoken = stripFillers(working)

                var targets: [Int] = []
                func add(_ newItem: Item) {
                    var item = newItem
                    pending.apply(to: &item)
                    items.append(item)
                    clauseItems.append(items.count - 1)
                    targets.append(items.count - 1)
                }

                if let amount = bareAmount(spoken) {
                    // An amount whose name came earlier: "感冒药买了两盒", "牛奶喝完了又买了两瓶".
                    if let last = clauseItems.last, items[last].quantityRaw == nil, items[last].amountNote == nil {
                        amount.apply(to: &items[last])
                        targets = [last]
                    } else if !usingUp, let name = lastMentioned, let item = makeItem(name: name, amount: amount) {
                        add(item)
                    }
                } else {
                    for piece in lexiconSegments(spoken) ?? [spoken] {
                        guard let parsed = parseItem(piece) else { continue }
                        if usingUp {
                            lastMentioned = parsed.name
                        } else if parsed.quantityRaw == nil, parsed.amountNote == nil,
                                  let existing = items.firstIndex(where: { sameThing($0.name, parsed.name) }) {
                            targets.append(existing)
                        } else {
                            add(parsed)
                        }
                    }
                }

                guard !details.isEmpty else { continue }
                if details.appliesToAll {
                    targets = clauseItems.isEmpty ? Array(items.indices) : clauseItems
                } else if targets.isEmpty {
                    if let last = clauseItems.last {
                        targets = [last]
                    } else {
                        pending.merge(details)
                        continue
                    }
                }
                for index in targets { details.apply(to: &items[index]) }
            }

            if clauseItems.isEmpty, !pending.isEmpty {
                for index in previousClauseItems { pending.apply(to: &items[index]) }
            }
            if !clauseItems.isEmpty { previousClauseItems = clauseItems }
        }
        return Result(items: items, mentionsUsingUp: mentionsUsingUp)
    }

    // MARK: - Splitting

    private static func normalize(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            // Full-width digits and letters → ASCII so "３瓶" reads like "3瓶".
            if (0xFF10...0xFF19).contains(scalar.value) || (0xFF21...0xFF5A).contains(scalar.value),
               let ascii = Unicode.Scalar(scalar.value - 0xFEE0) {
                result.unicodeScalars.append(ascii)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func clauses(of text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "。！!？?；;，,\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Items inside one clause: "一瓶牛奶、三包方便面和一个冰激凌", "牛奶 鸡蛋", "一瓶牛奶三包方便面".
    private static func parts(of clause: String) -> [String] {
        var marked = replace(conjunctionPattern, in: clause, with: "|")
        marked = replace(repeatedVerbPattern, in: marked, with: "|$0")
        marked = replace(countBoundaryPattern, in: marked, with: "|")
        let pieces = marked.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let reordered = reorderNameFirst(pieces) { return reordered }

        // "牛奶两瓶": the amount was split off after the name; glue it back.
        var merged: [String] = []
        for piece in pieces {
            if matches(bareAmountPattern, piece), let last = merged.last, !matches(leadingAmountPattern, last) {
                merged[merged.count - 1] = last + piece
            } else {
                merged.append(piece)
            }
        }
        return merged
    }

    // MARK: - Items

    private static func parseItem(_ text: String) -> Item? {
        guard !text.isEmpty else { return nil }
        var quantity = 1
        var quantityRaw: String?
        var amountNote: String?
        var statedUnit: String?
        var name = text

        if let groups = capture(dozenPattern, text) {
            quantity = groups[1] == "半" ? 6 : 12
            quantityRaw = (groups[1] ?? "一") + "打"
            statedUnit = "个"
            name = groups[2] ?? ""
        } else if let groups = capture(trailingDozenPattern, text) {
            quantity = groups[2] == "半" ? 6 : 12
            quantityRaw = (groups[2] ?? "一") + "打"
            statedUnit = "个"
            name = groups[1] ?? ""
        } else if let groups = capture(vagueAmountPattern, text) {
            statedUnit = groups[2]
            name = groups[3] ?? ""
        } else if let groups = capture(leadingAmountPattern, text),
                  let count = groups[1], let unit = groups[2], let number = chineseInteger(count) {
            (quantity, quantityRaw, amountNote, statedUnit) = amount(number, count: count, unit: unit)
            name = groups[3] ?? ""
        } else if let groups = capture(trailingAmountPattern, text),
                  let count = groups[2], let unit = groups[3], let number = chineseInteger(count) {
            (quantity, quantityRaw, amountNote, statedUnit) = amount(number, count: count, unit: unit)
            name = groups[1] ?? ""
        }

        return makeItem(name: stripFillers(name),
                        amount: Amount(quantity: quantity, raw: quantityRaw, note: amountNote, unit: statedUnit))
    }

    private static func makeItem(name: String, amount: Amount) -> Item? {
        guard isPlausibleName(name), (1...999).contains(amount.quantity) else { return nil }
        let entry = ProductLexicon.lookup(name)
        // "给宝宝" / "为家里" are who it's for, not what was bought.
        if entry == nil, name.hasPrefix("给") || name.hasPrefix("为") { return nil }
        return Item(
            name: name, quantity: amount.quantity, quantityRaw: amount.raw, amountNote: amount.note,
            unit: amount.unit ?? entry?.unit ?? "份", unitStated: amount.unit != nil,
            kind: entry?.kind ?? .unknown
        )
    }

    private struct Amount {
        let quantity: Int
        let raw: String?
        let note: String?
        let unit: String?

        func apply(to item: inout Item) {
            item.quantity = quantity
            item.quantityRaw = raw
            item.amountNote = note
            if let unit {
                item.unit = unit
                item.unitStated = true
            }
        }
    }

    private static func bareAmount(_ text: String) -> Amount? {
        guard let groups = capture(bareAmountPattern, text), let count = groups[1], let unit = groups[2],
              let number = chineseInteger(count) else { return nil }
        let parsed = amount(number, count: count, unit: unit)
        return Amount(quantity: parsed.quantity, raw: parsed.raw, note: parsed.note, unit: parsed.unit)
    }

    /// "酸奶鸡蛋面包" said without pauses → three products, when every piece is a known word.
    /// Two-word flavours ("草莓酸奶", "牛奶面包") stay one product.
    private static func lexiconSegments(_ text: String) -> [String]? {
        guard text.count >= 4, !matches(leadingAmountPattern, text) else { return nil }
        var rest = Substring(text)
        var words: [String] = []
        while !rest.isEmpty {
            guard let word = ProductLexicon.longestWord(prefixing: rest, minimumLength: 2) else { return nil }
            words.append(word)
            rest = rest.dropFirst(word.count)
        }
        if words.count == 2, let base = words.last, flavourBases.contains(base) { return nil }
        return words.count >= 2 ? words : nil
    }

    /// "牛奶一瓶鸡蛋十个面包两袋": names come first, each followed by its amount.
    private static func reorderNameFirst(_ pieces: [String]) -> [String]? {
        var tokens: [String] = []
        for piece in pieces {
            if let groups = capture(leadingAmountPattern, piece), let count = groups[1], let unit = groups[2] {
                tokens.append(count + unit)
                if let rest = groups[3], !rest.isEmpty { tokens.append(rest) }
            } else {
                tokens.append(piece)
            }
        }
        guard tokens.count >= 4, tokens.count.isMultiple(of: 2) else { return nil }
        for (index, token) in tokens.enumerated() where matches(bareAmountPattern, token) != !index.isMultiple(of: 2) {
            return nil
        }
        return stride(from: 0, to: tokens.count, by: 2).map { tokens[$0] + tokens[$0 + 1] }
    }

    /// Weights and volumes aren't stored yet (whole packages only), so they become "1 份" with a note.
    private static func amount(_ number: Int, count: String, unit: String)
        -> (quantity: Int, raw: String?, note: String?, unit: String?) {
        if weightUnits.contains(unit.lowercased()) { return (1, nil, count + unit, nil) }
        return (number, count + unit, nil, unit)
    }

    private static func isPlausibleName(_ name: String) -> Bool {
        guard (1...16).contains(name.count), !stopNames.contains(name) else { return false }
        return name.contains { $0.isLetter }
    }

    private static func sameThing(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let shorter = a.count < b.count ? a : b
        return shorter.count >= 2 && (a.contains(b) || b.contains(a))
    }

    private static func stripFillers(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed, !result.isEmpty {
            changed = false
            for word in leadingFillers where result.hasPrefix(word) && result.count > word.count {
                result.removeFirst(word.count)
                changed = true
                break
            }
            if leadingFillers.contains(result) || trailingFillers.contains(result) { return "" }
            for word in trailingFillers where result.hasSuffix(word) && result.count > word.count {
                result.removeLast(word.count)
                changed = true
                break
            }
            result = result.trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    // MARK: - Details (where it is, when it goes off, when to finish it)

    private struct Details {
        var storage: StorageHint?
        var package: HeardDate?
        var estimated: HeardDate?
        var planned: HeardDate?
        var appliesToAll = false

        var isEmpty: Bool { storage == nil && package == nil && estimated == nil && planned == nil }

        mutating func merge(_ other: Details) {
            storage = storage ?? other.storage
            package = package ?? other.package
            estimated = estimated ?? other.estimated
            planned = planned ?? other.planned
        }

        func apply(to item: inout Item) {
            if let storage {
                // A specific compartment is never downgraded to a bare "冰箱".
                let hasSpecific = item.storage.map { $0.location != StorageLocation.ambiguousFridge } ?? false
                if !(hasSpecific && storage.location == StorageLocation.ambiguousFridge) { item.storage = storage }
            }
            item.packageExpiry = item.packageExpiry ?? package
            item.estimatedExpiry = item.estimatedExpiry ?? estimated
            item.plannedUseBy = item.plannedUseBy ?? planned
        }
    }

    private static func extractDetails(from text: inout String, referenceDate: Date, calendar: Calendar) -> Details {
        var details = Details()

        for (pattern, location) in storagePatterns {
            guard let groups = take(pattern, from: &text) else { continue }
            if details.storage == nil {
                details.storage = StorageHint(location: location, raw: groups[0] ?? location)
                details.appliesToAll = groups[1] != nil || groups[3] != nil
            }
        }

        let day = { (offset: Int) in calendar.date(byAdding: .day, value: offset, to: referenceDate) }

        if let groups = take(relativeExpiryPattern, from: &text), let word = groups[1],
           let date = day(relativeDays[word] ?? 0) {
            details.package = HeardDate(date: date, raw: groups[0] ?? word, isGuess: false)
        } else if let groups = take(daysUntilExpiryPattern, from: &text),
                  let count = groups[2].flatMap({ chineseInteger($0) }), let date = day(count) {
            details.package = HeardDate(date: date, raw: groups[0] ?? "", isGuess: false)
        } else if let groups = take(labeledDatePattern, from: &text) ?? take(monthDayExpiryPattern, from: &text),
                  let month = groups[groups.count - 2].flatMap({ chineseInteger($0) }),
                  let dayOfMonth = groups[groups.count - 1].flatMap({ chineseInteger($0) }),
                  let date = monthDay(month, dayOfMonth, reference: referenceDate, calendar: calendar) {
            details.package = HeardDate(date: date, raw: groups[0] ?? "", isGuess: false)
        }

        if let groups = take(shelfLifePattern, from: &text),
           let date = span(groups[2], unit: groups[3], from: referenceDate, calendar: calendar) {
            details.estimated = HeardDate(date: date, raw: groups[0] ?? "", isGuess: false)
        }

        if let groups = take(planWithinPattern, from: &text),
           let date = span(groups[1], unit: groups[2], from: referenceDate, calendar: calendar) {
            details.planned = HeardDate(date: date, raw: groups[0] ?? "", isGuess: false)
        } else if let groups = take(planThisWeekPattern, from: &text) {
            let weekday = calendar.component(.weekday, from: referenceDate)
            if let date = day((8 - weekday) % 7) {
                details.planned = HeardDate(date: date, raw: groups[0] ?? "这周", isGuess: false)
            }
        } else if let groups = take(planDayPattern, from: &text), let word = groups[1],
                  let date = day(relativeDays[word] ?? 0) {
            details.planned = HeardDate(date: date, raw: groups[0] ?? word, isGuess: false)
        } else if let groups = take(planSoonPattern, from: &text), let date = day(2) {
            details.planned = HeardDate(date: date, raw: groups[0] ?? "尽快", isGuess: true)
        }
        return details
    }

    private static func span(_ count: String?, unit: String?, from reference: Date, calendar: Calendar) -> Date? {
        guard let count, let unit else { return nil }
        let isHalf = count == "半"
        guard let number = isHalf ? 1 : chineseInteger(count) else { return nil }
        switch unit {
        case "天", "日": return calendar.date(byAdding: .day, value: isHalf ? 0 : number, to: reference)
        case "周", "星期": return calendar.date(byAdding: .day, value: isHalf ? 3 : number * 7, to: reference)
        case "月": return calendar.date(byAdding: isHalf ? .day : .month, value: isHalf ? 15 : number, to: reference)
        case "年": return calendar.date(byAdding: isHalf ? .month : .year, value: isHalf ? 6 : number, to: reference)
        default: return nil
        }
    }

    private static func monthDay(_ month: Int, _ day: Int, reference: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year], from: reference)
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components),
              calendar.component(.month, from: date) == month else { return nil }
        // A month-day more than a month in the past almost always means next year.
        if let cutoff = calendar.date(byAdding: .day, value: -30, to: reference), date < cutoff {
            return calendar.date(byAdding: .year, value: 1, to: date)
        }
        return date
    }

    // MARK: - Numbers

    static func chineseInteger(_ value: String) -> Int? {
        if let number = Int(value) { return number }
        let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
                                        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        var total = 0, current = 0, sawAny = false
        for character in value {
            sawAny = true
            if let digit = digits[character] {
                current = digit
            } else if character == "十" {
                total += (current == 0 ? 1 : current) * 10; current = 0
            } else if character == "百" {
                total += (current == 0 ? 1 : current) * 100; current = 0
            } else {
                return nil
            }
        }
        return sawAny ? total + current : nil
    }

    // MARK: - Vocabulary

    private static let number = "[0-9零一二两三四五六七八九十百]+"
    private static let countUnits = [
        "瓶", "包", "盒", "袋", "罐", "支", "条", "片", "只", "块", "桶", "个", "杯", "枚", "颗", "粒",
        "箱", "提", "板", "听", "串", "把", "根", "份", "卷", "排", "扎", "捆", "碗", "筒", "套", "管",
        "双", "对", "节", "棵",
    ]
    private static let weightUnits: Set<String> = ["千克", "公斤", "毫升", "kg", "ml", "克", "斤", "升", "g"]
    private static let unit = (Array(weightUnits) + countUnits).sorted { $0.count > $1.count }.joined(separator: "|")

    private static let relativeDays = ["今天": 0, "今晚": 0, "明天": 1, "后天": 2, "大后天": 3]

    private static let flavourBases: Set<String> = [
        "酸奶", "牛奶", "蛋糕", "饼干", "面包", "冰激凌", "冰淇淋", "雪糕", "饺子", "水饺", "包子", "馄饨",
        "麦片", "巧克力", "果汁", "醋",
    ]

    private static let leadingFillers = [
        "嗯", "呃", "额", "那个", "这个", "就是", "我们", "我", "今天", "昨天", "前天", "刚才", "刚刚", "早上", "上午", "中午", "下午", "晚上",
        "刚去", "刚", "去", "在", "从", "又", "还", "也", "就", "先", "再", "顺便", "另外", "然后",
        "一共", "总共", "家里", "给家里", "超市里", "超市", "菜市场", "便利店", "网上", "淘宝", "京东", "盒马",
        "药店", "商场", "楼下", "新买了", "又买了", "买回来了", "买回来", "买了", "买", "囤了", "囤", "入了",
        "拿了", "带了", "带回来", "添了", "补了", "订了", "下单了", "收到了", "收到", "放了",
    ].sorted { $0.count > $1.count }
    private static let trailingFillers = ["回来了", "回来", "回家了", "了", "的", "吧", "啊", "呀", "哦", "呢", "嘛"]
    private static let stopNames: Set<String> = [
        "东西", "什么", "一些", "这些", "那些", "别的", "其他", "啥", "吃的", "喝的", "用的", "点东西", "些东西",
    ]

    private static let conjunctionPattern = regex("和(?!路雪|牛)|跟|与|以及|还有|加上|外加|再加上|再加|另外还有|、|\\s+")
    private static let repeatedVerbPattern = regex("(?<=.)(又|还|再|也)?(买了|囤了|拿了|入了|带了)")
    private static let countBoundaryPattern = regex(
        "(?<![0-9零一二两三四五六七八九十百几好])(?=(?:\(number)|几|好几)(?:\(unit)))")
    private static let bareAmountPattern = regex("^(\(number))(\(unit))$")
    private static let leadingAmountPattern = regex("^(\(number))(\(unit))(.*)$")
    private static let trailingAmountPattern = regex("^(.+?)(\(number))(\(unit))$")
    private static let dozenPattern = regex("^(一|半)?打(.+)$")
    /// "鸡蛋一打". The 一/半 is required so "小苏打" stays baking soda.
    private static let trailingDozenPattern = regex("^(.+?)(一|半)打$")
    private static let vagueAmountPattern = regex("^(好几|一些|一点儿|一点|几|些|点儿|点)(\(unit))?(.+)$")

    private static let noise = regex("(还没有|还没|没有|没)(吃|喝|用|开|拆|动)(过)?(呢)?")
    private static let usingUpPattern = regex(
        "吃完|喝完|用完|吃光|喝光|用光|吃掉了|喝掉了|用掉了|扔掉了|丢掉了|扔了|丢了|快坏了|坏了|快过期了|过期了|送人了")

    private static let storagePatterns: [(NSRegularExpression, String)] = [
        ("冷冻室|冷冻层|冷冻柜|冰柜|冷冻|冻起来|冻上", "冷冻"),
        ("冷藏室|冷藏层|保鲜层|冷藏", "冷藏"),
        ("冰箱", StorageLocation.ambiguousFridge),
        ("常温|阴凉处", "常温"),
        ("零食柜", "零食柜"), ("药箱", "药箱"), ("橱柜|柜子", "橱柜"), ("储物间", "储物间"),
    ].map { words, location in
        (regex("(都|全都|全部|全)?(先|已经|刚)?(都|全)?(?:放|塞|存|搁|收|扔)?(?:进了|到了|在了|进|在|到)?(?:\(words))(?:里面|里头|里|中)?(?:了)?"),
         location)
    }

    private static let relativeExpiryPattern = regex("(大后天|今天|明天|后天)(?:就)?(?:要)?(?:过期|到期)")
    private static let daysUntilExpiryPattern = regex("(还有|再过)?(\(number))(?:天|日)(?:后|以后|之后)?(?:就)?(?:要)?(?:过期|到期)")
    private static let labeledDatePattern = regex("(?:保质期|有效期)(?:到|至)?(\(number))月(\(number))(?:日|号)")
    private static let monthDayExpiryPattern = regex("(\(number))月(\(number))(?:日|号)(?:就)?(?:要)?(?:过期|到期)")
    private static let shelfLifePattern = regex("(保质期|有效期)(?:是|有|只有)?(\(number)|半)(?:个)?(天|星期|周|月|年)")
    private static let planWithinPattern = regex(
        "(\(number)|半)(?:个)?(天|星期|周|月)(?:内|之内|以内)(?:要)?(?:吃|喝|用)(?:掉|完|光)?")
    private static let planThisWeekPattern = regex("(这周|本周|这星期|这个星期)(?:内|之内)?(?:要)?(?:吃|喝|用)(?:掉|完|光)?")
    private static let planDayPattern = regex("(今天|今晚|明天|后天)(?:就)?(?:要)?(?:吃|喝|用)(?:掉|完|光)")
    private static let planSoonPattern = regex("(尽快|赶紧|早点|抓紧)(?:吃|喝|用)?(?:掉|完|光)?")

    // MARK: - Regex helpers

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants; a typo must fail loudly in tests.
        try! NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func capture(_ regex: NSRegularExpression, _ text: String) -> [String?]? {
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
    }

    /// Like `capture`, but also cuts the matched words out of `text`.
    private static func take(_ regex: NSRegularExpression, from text: inout String) -> [String?]? {
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let groups = (0..<match.numberOfRanges).map { index -> String? in
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
        text = ns.replacingCharacters(in: match.range, with: "")
        return groups
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                       withTemplate: template)
    }

    private static func remove(_ regex: NSRegularExpression, from text: String) -> String {
        replace(regex, in: text, with: "")
    }
}
