import Foundation

// The butler's one sentence at the top of home, and the buttons under it.
//
// The model chooses which thing to raise, writes the sentence, and picks the buttons for that particular
// situation. What a button can do is a closed set (`BriefEffect`) that the app validates and carries out
// only when the owner taps; the model never changes anything itself.

/// The primary object acted on by the card's quick-action buttons, not its entire subject.
enum BriefTarget: Hashable, Codable {
    case lot(UUID)
    case task(UUID)

    var key: String {
        switch self {
        case .lot(let id): "lot:" + id.uuidString.lowercased()
        case .task(let id): "task:" + id.uuidString.lowercased()
        }
    }

    init?(key: String) {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "lot": self = .lot(id)
        case "task": self = .task(id)
        default: return nil
        }
    }

    /// The conversation that belongs to this one thing, so what the owner says here can't collide with anything else.
    var scope: ChatScope {
        switch self {
        case .lot(let id): .lot(id)
        case .task(let id): .task(id)
        }
    }

    var agendaTarget: AgendaEntry.Target {
        switch self {
        case .lot(let id): .lot(id)
        case .task(let id): .reminder(id)
        }
    }
}

/// What a button does when tapped.
enum BriefEffect: Hashable, Codable {
    case closeLot(InventoryLotState)
    /// Some were used: the number left goes down by this many (at least 1 must remain).
    case usedSome(Int)
    /// Stop raising this for a while. 0 means the rest of today.
    case snooze(days: Int)
    case completeTask
    case remindLater(minutes: Int)
    case openDetail

    var forLots: Bool {
        switch self {
        case .closeLot, .usedSome: true
        case .snooze, .openDetail: true
        case .completeTask, .remindLater: false
        }
    }

    var forTasks: Bool {
        switch self {
        case .completeTask, .remindLater, .snooze, .openDetail: true
        case .closeLot, .usedSome: false
        }
    }

    /// Changes stock or a task: medicine asks once more before doing it.
    var changesData: Bool {
        switch self {
        case .closeLot, .usedSome, .completeTask: true
        case .snooze, .remindLater, .openDetail: false
        }
    }
}

struct BriefAction: Hashable, Codable, Identifiable {
    let label: String
    let effect: BriefEffect
    var id: String { label + "|" + String(describing: effect) }
}

struct ButlerBrief: Equatable, Codable {
    enum Source: String, Codable { case local, model }

    var greeting: String
    var text: String
    var basis: String
    var target: BriefTarget?
    /// Quick actions for target; the separate conversation entry discusses the whole card.
    var actions: [BriefAction]
    var source: Source
}

// MARK: - Candidates

/// One thing that might deserve the butler's attention right now.
struct BriefCandidate: Equatable {
    enum Kind: String { case expired, dueTask = "due_task", expiringSoon = "expiring_soon", lowStock = "low_stock" }

    let target: BriefTarget
    let kind: Kind
    let name: String
    /// Plain description for the model and for the local sentence, e.g. "已过期 4 天".
    let detail: String
    let quantity: Int?
    let unit: String?
    let daysLeft: Int?
    let location: String?
    let isMedicine: Bool

    var dictionary: [String: Any] {
        var out: [String: Any] = ["key": target.key, "kind": kind.rawValue, "name": name, "detail": detail, "medicine": isMedicine]
        if let quantity { out["quantity"] = quantity }
        if let unit { out["unit"] = unit }
        if let daysLeft { out["days_left"] = daysLeft }
        if let location { out["location"] = location }
        return out
    }
}

enum BriefCandidates {
    /// Most pressing first: overdue food, tasks that have come due, food about to expire, things running low.
    static func make(facts: [LotFacts], agenda: HomeAgenda, now: Date, snoozed: Set<String> = [],
                     calendar: Calendar = .current, limit: Int = 5) -> [BriefCandidate] {
        let byID = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [BriefCandidate] = []

        for entry in agenda.needsAttention where entry.kind == .expired {
            guard case .lot(let id) = entry.target, let lot = byID[id] else { continue }
            out.append(candidate(lot, .expired, detail: lot.dateStatusLabel))
        }
        var seenTasks = Set<UUID>()
        for entry in agenda.pending(on: agenda.today, at: now) {
            guard case .reminder(let id) = entry.target, seenTasks.insert(id).inserted else { continue }
            out.append(BriefCandidate(target: .task(id), kind: .dueTask, name: entry.title,
                                      detail: "已到时间，还没完成" + (entry.start.map { "（\($0.clockTime)）" } ?? ""),
                                      quantity: nil, unit: nil, daysLeft: nil, location: nil, isMedicine: false))
        }
        for lot in facts.filter({ !$0.quantityOnly && ($0.daysLeft ?? 99) >= 0 && ($0.daysLeft ?? 99) <= 3 })
            .sorted(by: { ($0.daysLeft ?? 0, $0.name) < ($1.daysLeft ?? 0, $1.name) }) {
            let when = lot.daysLeft == 0 ? "今天到期" : lot.daysLeft == 1 ? "明天到期" : "\(lot.daysLeft ?? 0) 天后到期"
            out.append(candidate(lot, .expiringSoon, detail: lot.governingDateKind == .plannedUseBy ? "该吃完了（\(when)）" : when))
        }
        for entry in agenda.needsAttention where entry.kind == .lowStock {
            guard case .lot(let id) = entry.target, let lot = byID[id] else { continue }
            out.append(candidate(lot, .lowStock, detail: "只剩 \(lot.quantity) \(lot.unit)"))
        }
        return Array(out.filter { !snoozed.contains($0.target.key) }.prefix(limit))
    }

    private static func candidate(_ lot: LotFacts, _ kind: BriefCandidate.Kind, detail: String) -> BriefCandidate {
        BriefCandidate(target: .lot(lot.id), kind: kind, name: lot.name, detail: detail, quantity: lot.quantity, unit: lot.unit,
                       daysLeft: lot.daysLeft, location: lot.storageLocation, isMedicine: lot.isMedicine)
    }

    /// Changes whenever the candidates, the part of the day or the day change, so a fresh sentence is only asked for when needed.
    static func signature(_ candidates: [BriefCandidate], now: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: now)
        let part = hour >= 18 || hour < 5 ? "night" : hour >= 12 ? "afternoon" : "morning"
        let text = ([now.isoDay, part] + candidates.map { "\($0.target.key)|\($0.kind.rawValue)|\($0.detail)|\($0.quantity ?? -1)" }).joined(separator: ";")
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }
}

// MARK: - Local sentence (when the model can't be reached)

enum BriefLocal {
    static func compose(candidates: [BriefCandidate], lotCount: Int, basis: String, now: Date,
                        calendar: Calendar = .current) -> ButlerBrief {
        let hour = calendar.component(.hour, from: now)
        let greeting = DailyBrief.greeting(hour: hour)
        guard let top = candidates.first else {
            let text = lotCount == 0 ? "家里还没记东西。买了什么跟我说一句，我来记着到期。"
                : "暂时没有新的提醒，其他安排和记录都在下面。"
            return ButlerBrief(greeting: greeting, text: text, basis: basis, target: nil, actions: [], source: .local)
        }
        var text: String
        var actions: [BriefAction]
        switch top.kind {
        case .expired:
            text = "\(top.name)\(top.detail)，今天处理掉吧。"
            actions = [BriefAction(label: "扔掉了", effect: .closeLot(.discarded)),
                       BriefAction(label: "已吃完", effect: .closeLot(.depleted)),
                       BriefAction(label: "先放放", effect: .snooze(days: 0))]
            if top.isMedicine { actions.removeAll { $0.effect == .closeLot(.depleted) } }
        case .dueTask:
            text = "「\(top.name)」到时间了，做了吗？"
            actions = [BriefAction(label: "做完了", effect: .completeTask),
                       BriefAction(label: "10 分钟后再提醒", effect: .remindLater(minutes: 10))]
        case .expiringSoon:
            text = "\(top.name)\(top.detail)，尽快用掉吧。"
            actions = [BriefAction(label: "已吃完", effect: .closeLot(.depleted)),
                       BriefAction(label: "明天再说", effect: .snooze(days: 0))]
        case .lowStock:
            text = "\(top.name)只剩 \(top.quantity ?? 0) \(top.unit ?? "")了，记得买。"
            actions = [BriefAction(label: "知道了", effect: .snooze(days: 1))]
        }
        // The rest that also needs a look, in a few words, so the card says everything at a glance.
        let others = candidates.dropFirst().map(\.name).reduce(into: [String]()) { if !$1.isEmpty, !$0.contains($1) { $0.append($1) } }
        if !others.isEmpty {
            let shown = others.prefix(2).joined(separator: "、")
            text += "另外\(shown)\(others.count > 2 ? "等 \(others.count) 样" : "")也要留意。"
        }
        return ButlerBrief(greeting: greeting, text: text, basis: basis, target: top.target, actions: actions, source: .local)
    }

    static func basis(lotCount: Int, taskCount: Int, usesCalendar: Bool) -> String {
        var parts = ["家里的 \(lotCount) 样东西"]
        if taskCount > 0 { parts.append("\(taskCount) 条提醒") }
        if usesCalendar { parts.append("日历") }
        return "依据：" + parts.joined(separator: " · ")
    }
}

// MARK: - The model's reply

enum BriefModelReply {
    private struct Raw: Decodable {
        struct Action: Decodable { let label: String; let effect: String; let value: Int? }
        let target: String?
        let text: String
        let actions: [Action]?
    }

    /// Reads and checks the model's JSON. Anything outside the closed set, or aimed at a thing that isn't a candidate,
    /// is dropped; if the sentence or the target is unusable the whole reply is refused and the local one is used.
    static func parse(_ reply: String, candidates: [BriefCandidate]) -> (text: String, target: BriefTarget, actions: [BriefAction])? {
        guard let json = extractJSON(reply), let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(Raw.self, from: data),
              let key = raw.target, let target = BriefTarget(key: key),
              let candidate = candidates.first(where: { $0.target == target }) else { return nil }
        let text = raw.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...120).contains(text.count) else { return nil }

        var actions: [BriefAction] = []
        for item in raw.actions ?? [] where actions.count < 3 {
            let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...9).contains(label.count), label != "其他", !label.hasPrefix("其他"),
                  let effect = effect(item.effect, value: item.value, candidate: candidate),
                  !actions.contains(where: { $0.label == label || $0.effect == effect }) else { continue }
            actions.append(BriefAction(label: label, effect: effect))
        }
        return (text, target, actions)
    }

    static func effect(_ name: String, value: Int?, candidate: BriefCandidate) -> BriefEffect? {
        let isLot: Bool = { if case .lot = candidate.target { true } else { false } }()
        let effect: BriefEffect
        switch name {
        case "close_depleted": effect = .closeLot(.depleted)
        case "close_discarded": effect = .closeLot(.discarded)
        case "close_gifted": effect = .closeLot(.gifted)
        case "adjust_quantity":
            guard let used = value, let quantity = candidate.quantity, used >= 1, used < quantity else { return nil }
            effect = .usedSome(used)
        case "snooze":
            guard let days = value, (0...30).contains(days) else { return nil }
            effect = .snooze(days: days)
        case "complete_task": effect = .completeTask
        case "snooze_task":
            guard let minutes = value, (5...240).contains(minutes) else { return nil }
            effect = .remindLater(minutes: minutes)
        case "open_detail": effect = .openDetail
        default: return nil
        }
        return (isLot ? effect.forLots : effect.forTasks) ? effect : nil
    }

    /// The reply should be bare JSON, but tolerate a code fence or a stray sentence around it.
    static func extractJSON(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return String(text[start...end])
    }

    /// What is sent to the model.
    static func instructions() -> String {
        """
        你是家庭管家“小当家”。下面给你此刻家里最需要关心的几件事（JSON）。挑其中最值得现在对用户说的一件作为重点（按钮只针对它），用一到两句口语化的中文对他说，总共不超过 60 个字：先说这件事和该怎么办，如果还有别的要留意的事，可以顺带提一句（不用给它按钮）。像熟悉这个家的人，不要用“建议您”，不要堆数字。再根据重点这件事的实际情况，给 2 到 3 个按钮，让他点一下就能处理。

        按钮的 effect 只能从下面选，label 是按钮上的字（2 到 6 个字）：
        - close_depleted：这件东西吃完/用完了，从库存里去掉
        - close_discarded：扔掉了
        - close_gifted：送人了
        - adjust_quantity，value=用掉的个数：用掉了一部分（至少 1，且小于现有数量）
        - snooze，value=天数：先放放，这么多天后再提这件事（0 表示今天先不提，明天再说；最多 30）
        - complete_task：任务已经做完（只用于任务）
        - snooze_task，value=分钟：过一会儿再提醒（只用于任务，5 到 240）
        - open_detail：打开详情看看

        weather 若存在，只是值得留意的新鲜天气线索，不是必须说出的提醒。先判断它是否会影响当前事情或用户接下来的活动：有明确关系时，最多把一句具体关心自然融进 text，与其他正文同等呈现；没有关系就完全不提。不要为了凑内容每天提醒穿衣、带伞，不把温差本身当成必须加衣的理由，也不把原始 hint 生硬拼在正文前后。没有 weather 时不编造天气。不要转述温度数值、风速、降雨概率等原始气象数据；这些在天气面板查看。不能凭天气创造库存、任务或自动修改规则。

        按钮要贴合这件事，不要每次都给同一组：过期很久的食物，重点是处理掉；快到期但还能吃的，重点是今晚或明天吃掉，可以给“再放放”一两天；药品要谨慎，不要替用户决定扔；任务到点了，重点是做完或稍后再提醒；快用完的东西，给“知道了”，不必催促。不要给“其他”按钮，App 会自己加。

        只输出一个 JSON，不要任何别的文字：
        {"target":"<key>","text":"…","actions":[{"label":"…","effect":"…","value":数字或null}]}
        """
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd EEEE HH:mm"
        return formatter.string(from: date)
    }

    static func request(candidates: [BriefCandidate], greeting: String, now: Date, calendar: Calendar = .current, weather: WeatherSnapshot? = nil) -> String {
        var payload: [String: Any] = [
            "now": stamp(now),
            "greeting": greeting,
            "items": candidates.map(\.dictionary),
        ]
        if let weather, let hint = weather.hint(at: now) {
            payload["weather"] = ["place": weather.place.name, "condition": weather.conditionLabel,
                                  "temperature_c": weather.temperature, "feels_like_c": weather.feelsLike,
                                  "read_at": weather.fetchedAt.ISO8601Format(), "hint": hint]
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Snoozed

/// Things the owner said "先放放" to: kept out of the butler's sentence until the time given. They stay in the list.
struct BriefSnoozes {
    static let key = "briefSnoozes"

    static func snooze(_ target: BriefTarget, until: Date, defaults: UserDefaults = .standard) {
        var all = load(defaults)
        all[target.key] = until.timeIntervalSince1970
        defaults.set(all, forKey: key)
    }

    /// 0 days: until tomorrow morning; otherwise until the start of that many days from today.
    static func snooze(_ target: BriefTarget, days: Int, now: Date = .now, calendar: Calendar = .current,
                       defaults: UserDefaults = .standard) {
        let startOfToday = calendar.startOfDay(for: now)
        let until = calendar.date(byAdding: .day, value: max(days, 1), to: startOfToday) ?? now.addingTimeInterval(86_400)
        snooze(target, until: until, defaults: defaults)
    }

    /// The keys still snoozed at `now`; expired ones are forgotten.
    static func active(now: Date = .now, defaults: UserDefaults = .standard) -> Set<String> {
        let all = load(defaults)
        let live = all.filter { $0.value > now.timeIntervalSince1970 }
        if live.count != all.count { defaults.set(live, forKey: key) }
        return Set(live.keys)
    }

    private static func load(_ defaults: UserDefaults) -> [String: Double] {
        defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    }
}
