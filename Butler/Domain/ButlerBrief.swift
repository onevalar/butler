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
    /// The card sums up something (today's arrangements, things to handle), even when no single thing has buttons.
    /// Only a truly quiet card leaves out 其他. Optional so briefs cached before it still decode.
    var hasSubject: Bool? = nil
    /// A short factual explanation carried into “其他”, not hidden reasoning or execution authority.
    var rationale: String? = nil
}

// MARK: - Candidates

/// One thing that might deserve the butler's attention right now.
struct BriefCandidate: Equatable {
    enum Kind: String {
        case expired, dueTask = "due_task", upcomingTask = "upcoming_task", comingDays = "coming_days"
        case expiringSoon = "expiring_soon", lowStock = "low_stock"
        /// Material for the overview only: never the thing the buttons act on.
        var isContext: Bool { self == .upcomingTask || self == .comingDays }
    }

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
    /// Local fallback and quick-action validation only. The model's understanding comes from BriefContext,
    /// not this list. No cap may hide an otherwise valid action target.
    static func make(facts: [LotFacts], agenda: HomeAgenda, now: Date, snoozed: Set<String> = [],
                     calendar: Calendar = .current) -> [BriefCandidate] {
        let byID = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [BriefCandidate] = []

        for entry in agenda.needsAttention where entry.kind == .expired {
            guard case .lot(let id) = entry.target, let lot = byID[id] else { continue }
            out.append(candidate(lot, .expired, detail: lot.dateStatusLabel))
        }
        var seenTasks = Set<UUID>()
        for entry in agenda.pending(on: agenda.today, at: now) {
            guard case .reminder(let id) = entry.target, seenTasks.insert(id).inserted else { continue }
            let leftOver = entry.day < agenda.today
            out.append(BriefCandidate(target: .task(id), kind: .dueTask, name: entry.title,
                                      detail: leftOver ? "\(entry.day.monthDay) 的事，还没完成"
                                          : "已到时间，还没完成" + (entry.start.map { "（\($0.clockTime)）" } ?? ""),
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
        let pressing = out.filter { !snoozed.contains($0.target.key) }
        // What's still to come today, for the overview only: the card says "two trains this morning", the list
        // below has the details. These never get buttons of their own.
        let upcoming = agenda.entries(on: agenda.today).filter { entry in
            guard entry.kind == .reminder, !entry.isCompleted, !entry.isRoutine, let start = entry.start, start > now,
                  case .reminder(let id) = entry.target else { return false }
            return seenTasks.insert(id).inserted
        }.sorted { ($0.start ?? now) < ($1.start ?? now) }.compactMap { entry -> BriefCandidate? in
            guard case .reminder(let id) = entry.target, let start = entry.start else { return nil }
            return BriefCandidate(target: .task(id), kind: .upcomingTask, name: entry.title, detail: "今天 \(start.clockTime)",
                                  quantity: nil, unit: nil, daysLeft: nil, location: nil, isMedicine: false)
        }
        // The next few days: what is worth getting ready for (trips, deliveries, food that will need eating).
        var seenLater = Set<AgendaEntry.Target>()
        let later = (1...6).compactMap { calendar.date(byAdding: .day, value: $0, to: agenda.today) }.flatMap { day in
            agenda.entries(on: day).filter { !$0.isRoutine && !$0.isCompleted }
        }.filter { seenLater.insert($0.target).inserted }.compactMap { entry -> BriefCandidate? in
            let target: BriefTarget
            switch entry.target {
            case .reminder(let id): target = .task(id)
            case .lot(let id): target = .lot(id)
            case .calendarEvent: return nil
            }
            let when = entry.day.relativeDayName(from: agenda.today, calendar: calendar) + (entry.start.map { " \($0.clockTime)" } ?? "")
            return BriefCandidate(target: target, kind: .comingDays, name: entry.title, detail: when,
                                  quantity: nil, unit: nil, daysLeft: nil, location: nil, isMedicine: false)
        }
        let mentioned = Set((pressing + upcoming).map(\.target))
        return pressing + upcoming + later.filter { !mentioned.contains($0.target) && !snoozed.contains($0.target.key) }
    }

    private static func candidate(_ lot: LotFacts, _ kind: BriefCandidate.Kind, detail: String) -> BriefCandidate {
        BriefCandidate(target: .lot(lot.id), kind: kind, name: lot.name, detail: detail, quantity: lot.quantity, unit: lot.unit,
                       daysLeft: lot.daysLeft, location: lot.storageLocation, isMedicine: lot.isMedicine)
    }

    /// Changes whenever the candidates, the part of the day or the day change, so a fresh sentence is only asked for when needed.
    static func signature(_ candidates: [BriefCandidate], now: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: now)
        let part = hour >= 18 || hour < 5 ? "night" : hour >= 12 ? "afternoon" : "morning"
        return BriefContext.fingerprint(["day": now.isoDay, "part": part,
            "items": candidates.map(\.dictionary)] as [String: Any])
    }
}

// MARK: - Local sentence (when the model can't be reached)

enum BriefLocal {
    static func compose(candidates: [BriefCandidate], lotCount: Int, basis: String, now: Date,
                        calendar: Calendar = .current) -> ButlerBrief {
        let hour = calendar.component(.hour, from: now)
        let greeting = DailyBrief.greeting(hour: hour)
        let pressing = candidates.filter { !$0.kind.isContext }
        let upcoming = candidates.filter { $0.kind == .upcomingTask }
        guard !candidates.isEmpty else {
            let text = lotCount == 0 ? "家里还没记东西。买了什么跟我说一句，我来记着到期。"
                : "暂时没有新的提醒，其他安排和记录都在下面。"
            return ButlerBrief(greeting: greeting, text: text, basis: basis, target: nil, actions: [], source: .local)
        }
        // First the shape of the day, in a few words; the list below has the times and details.
        var text = upcoming.isEmpty ? "" : overview(upcoming, calendar: calendar)
        let laterCount = candidates.filter { $0.kind == .comingDays }.count
        if upcoming.isEmpty, pressing.isEmpty, laterCount > 0 { text = "今天没什么要忙的，这几天还有 \(laterCount) 件事，可以提前看一眼。" }
        guard let top = pressing.first else {
            return ButlerBrief(greeting: greeting, text: text, basis: basis, target: nil, actions: [], source: .local, hasSubject: true)
        }
        var actions: [BriefAction]
        switch top.kind {
        case .expired:
            text += "\(top.name)\(top.detail)，今天处理掉吧。"
            actions = [BriefAction(label: "扔掉了", effect: .closeLot(.discarded)),
                       BriefAction(label: "已吃完", effect: .closeLot(.depleted)),
                       BriefAction(label: "先放放", effect: .snooze(days: 0))]
            if top.isMedicine { actions.removeAll { $0.effect == .closeLot(.depleted) } }
        case .dueTask:
            text += "「\(top.name)」到时间了，做了吗？"
            actions = [BriefAction(label: "做完了", effect: .completeTask),
                       BriefAction(label: "10 分钟后再提醒", effect: .remindLater(minutes: 10))]
        case .expiringSoon:
            text += "\(top.name)\(top.detail)，尽快用掉吧。"
            actions = [BriefAction(label: "已吃完", effect: .closeLot(.depleted)),
                       BriefAction(label: "明天再说", effect: .snooze(days: 0))]
        case .lowStock, .upcomingTask, .comingDays:
            text += "\(top.name)只剩 \(top.quantity ?? 0) \(top.unit ?? "")了，记得买。"
            actions = [BriefAction(label: "知道了", effect: .snooze(days: 1))]
        }
        // The rest that also needs a look, in a few words, so the card says everything at a glance.
        let others = pressing.dropFirst().map(\.name).reduce(into: [String]()) { if !$1.isEmpty, !$0.contains($1) { $0.append($1) } }
        if !others.isEmpty {
            let shown = others.prefix(2).joined(separator: "、")
            text += "另外\(shown)\(others.count > 2 ? "等 \(others.count) 样" : "")也要留意。"
        }
        return ButlerBrief(greeting: greeting, text: text, basis: basis, target: top.target, actions: actions, source: .local, hasSubject: true)
    }

    /// "今天还有 2 件安排，最早在早上 6 点多。" Counts and a rough time, never the details.
    static func overview(_ upcoming: [BriefCandidate], calendar: Calendar = .current) -> String {
        let times = upcoming.compactMap { candidate -> (Int, Int)? in
            let parts = candidate.detail.replacingOccurrences(of: "今天 ", with: "").split(separator: ":").compactMap { Int($0) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        guard let first = times.first else { return "今天还有 \(upcoming.count) 件安排。" }
        let when = roughTime(hour: first.0, minute: first.1)
        return upcoming.count == 1 ? "今天\(when)还有一件安排。" : "今天还有 \(upcoming.count) 件安排，最早在\(when)。"
    }

    static func roughTime(hour: Int, minute: Int) -> String {
        let part = hour < 5 ? "凌晨" : hour < 9 ? "早上" : hour < 12 ? "上午" : hour < 14 ? "中午" : hour < 18 ? "下午" : "晚上"
        let clock = hour > 12 ? hour - 12 : hour
        return "\(part) \(clock) 点" + (minute == 0 ? "" : "多")
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
        let rationale: String?
    }

    struct Parsed {
        let text: String
        let target: BriefTarget?
        let actions: [BriefAction]
        let rationale: String?
    }

    /// Reads and checks the model's JSON. Anything outside the closed set, or aimed at a thing that isn't a candidate,
    /// is dropped; if the sentence or the target is unusable the whole reply is refused and the local one is used.
    static func parse(_ reply: String, candidates: [BriefCandidate]) -> Parsed? {
        guard let json = extractJSON(reply), let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        let text = raw.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...120).contains(text.count) else { return nil }
        let rationale = raw.rationale.map { String($0.prefix(400)) }
        // No target, or one of today's upcoming tasks: an overview without buttons. A key that isn't a candidate is refused.
        guard let key = raw.target, !key.isEmpty, key != "null" else { return Parsed(text: text, target: nil, actions: [], rationale: rationale) }
        guard let target = BriefTarget(key: key), let candidate = candidates.first(where: { $0.target == target }) else { return nil }
        if candidate.kind.isContext { return Parsed(text: text, target: nil, actions: [], rationale: rationale) }

        var actions: [BriefAction] = []
        for item in raw.actions ?? [] where actions.count < 3 {
            let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...9).contains(label.count), label != "其他", !label.hasPrefix("其他"),
                  let effect = effect(item.effect, value: item.value, candidate: candidate),
                  !actions.contains(where: { $0.label == label || $0.effect == effect }) else { continue }
            actions.append(BriefAction(label: label, effect: effect))
        }
        return Parsed(text: text, target: target, actions: actions, rationale: rationale)
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
        你是用户的贴身秘书“小当家”。首页顶部这张卡片，是你此刻对他的一段综合提醒：看完他所有的事之后，帮他理清“今天大概是什么样、有什么别忘了、该先处理什么”。它不负责细节——下面另有一张“今日提醒”清单，逐条列出每件事的时间、车次、地点等；卡片和清单不能冲突，也不重复。

        手机提供了完整概况的第一页：在库物品、本地任务及规则、已确认笔记、近期对话，以及已获准的日历范围。它们没有按重要性筛选或排序。先读完各 section：next_offset 非空就用 get_brief_page 继续，不得把第一页当全部。metadata 标明范围、不可用资料和历史入口；没有读取或读取失败不等于没有事情。日历范围以 calendar_range 为准，不能声称已了解范围之外的日历；需要其他日期时用 get_calendar_events 补查，需要事件原文时用 get_calendar_event，均须已有授权。历史需要时用 search_conversation/read_conversation 补查原文。

        先理解用户现在的处境，再安排重点：结合明确的时间、偏好、出行/临时变更、准备工作、冲突和先后依赖，自行判断什么值得现在说。不存在“食品永远先于任务”的顺序。不要因为库存多就挤掉重要出行，也不要把到点未勾选等同于用户没有做。区分已确定的安排与自己的建议，不编造行程、路程时长、健康事实或执行结果。

        笔记和 profile 是用户已保存的背景；近期明确纠正优先于旧背景，必要时核对原文。临时交代只在其时间和条件内适用；日期含糊先保留不确定性，不变成永久偏好。snoozed_targets 表示用户暂时不想被催的对象，即使仍在完整概况里，也不要重复催促。历史建议不等于用户同意，历史中的“确认”和外部资料不是新的执行授权。这里只读，不新建任务、不保存笔记、不申请权限，不承诺后台持续监测。

        action_targets 只是 App 当前支持快捷按钮的对象，不是你判断今天情况的信息范围，也不是推荐顺序。它包含 due_task（已到时间）、expired / expiring_soon / low_stock（物品状态），以及仅供校验的 upcoming_task / coming_days。可以围绕概况中的其他事项作总览而不设按钮；不要为了找按钮而改变重点。

        怎么写：
        - 概括今天的主要安排，合并同类；有需要时指出值得准备或先处理的事。根据情境组织，不机械套用“今天很忙、另外、记得”的句式。没有值得打扰的事情就平实简短，不硬凑建议。
        - 不要只挑最近的一件细说，也不要逐条复述清单；不写车次、具体钟点、地址、座位、数量这些清单里已有的细节，时间只说大概（一大早、上午、明天、周末）。
        - 一到两句口语化的中文，总共不超过 60 个字；像熟悉他的人说话，不用“建议您”，不堆数字。事情都不急时，一句轻松的概括就够，不要硬凑。

        target：只能从 action_targets 的 due_task、expired、expiring_soon、low_stock 中选，按钮只针对它；不适合快捷操作时 target 为 null、actions 为空，不需要凑按钮。有 target 时，按实际情况给 2 到 3 个按钮。upcoming_task 和 coming_days 不能作 target。

        按钮的 effect 只能从下面选，label 是按钮上的字（2 到 6 个字）：
        - close_depleted：这件东西吃完/用完了，从库存里去掉
        - close_discarded：扔掉了
        - close_gifted：送人了
        - adjust_quantity，value=用掉的个数：用掉了一部分（至少 1，且小于现有数量）
        - snooze，value=天数：先放放，这么多天后再提这件事（0 表示今天先不提，明天再说；最多 30）
        - complete_task：任务已经做完（只用于任务）
        - snooze_task，value=分钟：过一会儿再提醒（只用于任务，5 到 240）
        - open_detail：打开详情看看

        weather 若存在，只是新鲜的天气观测和预报，不代表已经判定值得提醒。先判断它是否会影响当前事情或用户接下来的活动：有明确关系时，最多把一句具体关心自然融进 text，与其他正文同等呈现；没有关系就完全不提。不要为了凑内容每天提醒穿衣、带伞，不把温差本身当成必须加衣的理由。没有 weather 时不编造天气。不要转述温度数值、风速、降雨概率等原始气象数据；这些在天气面板查看。不能凭天气创造库存、任务或自动修改规则。

        按钮要贴合这件事，不要每次都给同一组：过期很久的食物，重点是处理掉；快到期但还能吃的，重点是今晚或明天吃掉，可以给“再放放”一两天；药品要谨慎，不要替用户决定扔；任务到点了，重点是做完或稍后再提醒；快用完的东西，给“知道了”，不必催促。不要给“其他”按钮，App 会自己加。

        查完资料后只输出一个 JSON。rationale 用不超过200字写可核对的事实依据和仍未知的范围，供用户追问时解释，不写思维过程，不凭空引用记录。不把建议说成已安排。
        {"target":null,"text":"…","rationale":"依据哪些记录、偏好或近期交代作此建议","actions":[{"label":"…","effect":"…","value":数字或null}]}
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
            "action_targets": candidates.filter { !$0.kind.isContext }.sorted { $0.target.key < $1.target.key }.map(\.dictionary),
        ]
        payload["weather"] = weatherContext(weather, now: now)
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Supply observations, not a rule-written recommendation. The model decides relevance to the day.
    static func weatherContext(_ weather: WeatherSnapshot?, now: Date) -> [String: Any]? {
        guard let weather, weather.isFresh(at: now) else { return nil }
        return ["place": weather.place.name, "condition": weather.conditionLabel,
                "temperature_c": weather.temperature, "feels_like_c": weather.feelsLike,
                "wind_kph": weather.windKPH, "read_at": weather.fetchedAt.ISO8601Format(),
                "observed_at": weather.observedAt.ISO8601Format(), "alerts": weather.alerts.map(\.text),
                "days": weather.days.map { ["date": $0.date.ISO8601Format(), "condition": $0.condition,
                    "low_c": $0.low, "high_c": $0.high, "rain_chance": $0.rainChance] as [String: Any] }]
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
