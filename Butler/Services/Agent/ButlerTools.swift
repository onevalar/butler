import Foundation
import Observation
import SwiftData

/// A change the assistant proposed. Nothing is written until the owner taps confirm.
struct PendingChange: Identifiable, Codable {
    enum Kind: Codable {
        case add(InventoryActions.NewItem)
        case setQuantity(LotFacts, Int)
        case close(LotFacts, InventoryLotState)
        case setDate(LotFacts, LotDateKind, Date?)
        case move(LotFacts, String)
        case tracking(LotFacts, quantityOnly: Bool)
        case itemProfile(LotFacts, ItemProfile)
        case undoInventory(LotFacts, UUID)
        case note(LocalMemory)
        case reminder(TimedReminder)
        case cancelReminder(TimedReminder)
        case taskPlan(TimedReminder, expectedRevision: Int?)
        case taskAction(UUID, TaskAction, expectedRevision: Int)
        case settings([ButlerSettingChange])
        case weatherLocation(WeatherLocation, before: WeatherLocation)
    }

    var id = UUID()
    let kind: Kind
    /// One line the owner reads on the card, e.g. "新增 牛奶 ×2 瓶".
    let title: String
    let detail: String?
    /// What the judgment layer said. nil = not checked (no Jev key, or Jev unavailable).
    var check: JevCheck? = nil
}

enum JevCheck: Equatable, Codable {
    case passed
    /// Jev disagreed, the model kept its proposal; the owner decides on the card.
    case concern(String)
}

/// The assistant's hands: reads and proposes changes to the owner's real inventory and notes.
@MainActor @Observable
final class ButlerTools {
    let container: ModelContainer
    let notes: LocalMemoryStore
    let reminders: ReminderStore
    let jev: any ConditionJudge
    private(set) var pending: [PendingChange] = [] { didSet { pendingDidChange?(pending) } }
    var pendingDidChange: (([PendingChange]) -> Void)?
    func restorePending(_ values: [PendingChange]) { pending = values }
    /// The saved conversation, provided by the chat that owns these tools.
    var conversation: (() -> ConversationArchive)?
    var currentContext: (() -> String)?
    var weather: WeatherStore = .shared
    var inputPhotos: [Data] = []
    var displayedCollection: ItemCollection?
    var conversationScope: ChatScope = .general
    var relatedScopes: Set<ChatScope> = []
    var settingsDefaults: UserDefaults = .standard
    /// What the owner said this turn (and just before), given to Jev as the request.
    private var request = ""
    private var previous: String?
    /// Jev can't see photos, so it can't judge whether a date came from a package in the picture.
    private var hasPhotos = false
    /// Proposals Jev already pushed back on this turn. Proposing the same thing again means the
    /// model kept it; it then goes to the card with Jev's concern shown.
    private var raisedConcerns: Set<String> = []

    init(container: ModelContainer, notes: LocalMemoryStore, reminders: ReminderStore, jev: any ConditionJudge) {
        self.container = container
        self.notes = notes
        self.reminders = reminders
        self.jev = jev
    }

    nonisolated deinit {}

    func clearPending() { pending = [] }

    /// A reminder understood on the phone (when the model couldn't be reached), shown for confirmation like any other.
    func proposeReminder(_ reminder: TimedReminder) {
        add(.reminder(reminder), title: "提醒：\(reminder.text)", detail: reminder.whenLabel)
    }

    func beginTurn(request: String, previous: String?, hasPhotos: Bool = false) {
        self.hasPhotos = hasPhotos
        self.request = hasPhotos ? request + "（用户附了照片）" : request
        self.previous = previous
        raisedConcerns = []
        relatedScopes = []
        displayedCollection = nil
    }

    func removePending(_ id: UUID) { pending.removeAll { $0.id == id } }

    // MARK: - Tool definitions

    var toolJSON: String {
        var tools = Self.inventoryTools + "," + Self.contextTools + "," + Self.pendingTools + "," + Self.itemTools + "," + Self.weatherTools
        if conversation != nil { tools += "," + Self.conversationTools }
        if jev.isAvailable { tools += "," + Self.jevTool }
        return "[" + tools + "]"
    }

    static let legacyInventoryTools = #"""
    {"type":"function","name":"search_inventory","description":"查询家里现有物品（真实库存）。query为空字符串时查询全部在库批次，但最多返回80条；按名称、品牌或存放位置的关键词匹配。include_finished=true 时额外查询最近30天已处理记录，最多返回30条。count是匹配的在库批次数，returned_count是实际返回数；complete/truncated说明查询范围内是否返回完整，有截断时应缩小关键词补查。返回每件的 lot_id、剩余数量、单位、位置、日期和剩余天数；不同单位的数量不可直接相加。","strict":true,"parameters":{"type":"object","properties":{"query":{"type":"string"},"include_finished":{"type":"boolean"}},"required":["query","include_finished"],"additionalProperties":false}},
    {"type":"function","name":"propose_add_items","description":"提出新增购买的物品，等用户确认后才入库。每件一条。package_expiry 只能填用户明确说出或包装上的日期(YYYY-MM-DD)，否则 null；planned_use_by 是用户想在哪天前吃完/用完的计划，没说就 null。storage 是用户说的存放位置（冷藏/冷冻/常温/卫生间/储物柜等），没说就 null。track：quantity 表示只记数量、不管过期（饮用水、纸巾、洗护清洁用品等用户不在乎过期的东西），expiry 表示要跟踪到期（食物、药等）。","strict":true,"parameters":{"type":"object","properties":{"items":{"type":"array","minItems":1,"maxItems":20,"items":{"type":"object","properties":{"name":{"type":"string"},"quantity":{"type":"integer","minimum":1,"maximum":999},"unit":{"type":"string"},"storage":{"type":["string","null"]},"package_expiry":{"type":["string","null"]},"planned_use_by":{"type":["string","null"]},"track":{"type":"string","enum":["expiry","quantity"]}},"required":["name","quantity","unit","storage","package_expiry","planned_use_by","track"],"additionalProperties":false}}},"required":["items"],"additionalProperties":false}},
    {"type":"function","name":"propose_set_quantity","description":"把某件物品的剩余数量设置为指定值（不是扣减）。设为0等于用完。lot_id 必须来自本轮程序预取的真实库存或 search_inventory。","strict":true,"parameters":{"type":"object","properties":{"lot_id":{"type":"string"},"quantity":{"type":"integer","minimum":0,"maximum":999}},"required":["lot_id","quantity"],"additionalProperties":false}},
    {"type":"function","name":"propose_close","description":"把某件物品标记为处理掉：used_up 用完/吃完，discarded 丢掉，gifted 送人。","strict":true,"parameters":{"type":"object","properties":{"lot_id":{"type":"string"},"reason":{"type":"string","enum":["used_up","discarded","gifted"]}},"required":["lot_id","reason"],"additionalProperties":false}},
    {"type":"function","name":"propose_set_date","description":"设置或清除某件物品的日期。kind=package_expiry 包装有效期（只能用用户明确给出的日期），kind=planned_use_by 计划吃完/用完的日期。date 为 YYYY-MM-DD，null 表示清除。","strict":true,"parameters":{"type":"object","properties":{"lot_id":{"type":"string"},"kind":{"type":"string","enum":["package_expiry","planned_use_by"]},"date":{"type":["string","null"]}},"required":["lot_id","kind","date"],"additionalProperties":false}},
    {"type":"function","name":"propose_move","description":"更改某件物品的存放位置。","strict":true,"parameters":{"type":"object","properties":{"lot_id":{"type":"string"},"location":{"type":"string"}},"required":["lot_id","location"],"additionalProperties":false}},
    {"type":"function","name":"propose_set_tracking","description":"切换某样东西的记录方式：quantity 只记数量、不再追问和提醒过期；expiry 恢复跟踪到期日期。对同一种东西的所有批次生效。","strict":true,"parameters":{"type":"object","properties":{"lot_id":{"type":"string"},"track":{"type":"string","enum":["expiry","quantity"]}},"required":["lot_id","track"],"additionalProperties":false}},
    {"type":"function","name":"propose_reminder","description":"设一个定时提醒：到点时手机弹出通知。用于“11点提醒我热饭”“每天晚上9点提醒我吃药”“周六早上提醒我买菜”。time 为本地时间 YYYY-MM-DD HH:mm；repeat：none 只提醒一次，daily 每天这个时间，weekly 每周这一天这个时间。text 是通知里显示的话，简短具体。","strict":true,"parameters":{"type":"object","properties":{"text":{"type":"string"},"time":{"type":"string"},"repeat":{"type":"string","enum":["none","daily","weekly"]}},"required":["text","time","repeat"],"additionalProperties":false}},
    {"type":"function","name":"list_reminders","description":"查看已经设好、还没到点（或重复）的定时提醒。","strict":true,"parameters":{"type":"object","properties":{},"additionalProperties":false}},
    {"type":"function","name":"propose_cancel_reminder","description":"取消一个定时提醒，id 来自 list_reminders。","strict":true,"parameters":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}},
    {"type":"function","name":"search_notes","description":"查询用户告诉过你的习惯、偏好和其他需要记住的事（例如常去哪家店买、放在哪里、家里的布局）。query 为空返回全部笔记。程序预取的笔记有容量上限，以complete/truncated判断是否完整；资料不足时可按关键词调用本工具补查。","strict":true,"parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}},
    {"type":"function","name":"propose_note","description":"新增或更正一条需要长期记住的事（习惯、偏好、布局、提醒自己的话）。id=null 新建；更正时传原 id，保留没被纠正的内容。库存物品本身不要写成笔记。","strict":true,"parameters":{"type":"object","properties":{"id":{"type":["string","null"]},"title":{"type":"string"},"text":{"type":"string"}},"required":["id","title","text"],"additionalProperties":false}}
    """#

    static let conversationTools = #"""
    {"type":"function","name":"conversation_overview","description":"看以前对话记录的概况：总共多少轮、每天聊了几轮和话题开头、哪些已在你的上下文里、摘要覆盖到哪。用于决定要不要、以及从哪里开始读原始记录。","strict":true,"parameters":{"type":"object","properties":{},"additionalProperties":false}},
    {"type":"function","name":"search_conversation","description":"在以前的全部对话里找内容。query 多个关键词用空格分开，命中任意一个即返回；可用 from_date/to_date (YYYY-MM-DD) 限定日期，query 为空字符串时列出该日期范围内的对话。返回 turn 编号和片段，新的在前。","strict":true,"parameters":{"type":"object","properties":{"query":{"type":"string"},"from_date":{"type":["string","null"]},"to_date":{"type":["string","null"]},"limit":{"type":"integer","minimum":1,"maximum":50}},"required":["query","from_date","to_date","limit"],"additionalProperties":false}},
    {"type":"function","name":"read_conversation","description":"读取以前对话的完整原文（按时间顺序，每页约1.2万字）。可按 turn 编号范围或日期范围读；返回 next_cursor 时表示还有，下次传 cursor 继续读。回顾、总结、核对以前说过什么时，读够原文再回答，不要只凭摘要。","strict":true,"parameters":{"type":"object","properties":{"from_turn":{"type":["integer","null"]},"to_turn":{"type":["integer","null"]},"from_date":{"type":["string","null"]},"to_date":{"type":["string","null"]},"cursor":{"type":["integer","null"]}},"required":["from_turn","to_turn","from_date","to_date","cursor"],"additionalProperties":false}}
    """#

    static let jevTool = #"""
    {"type":"function","name":"judge_with_jev","description":"请 Jev 条件判断模型对候选逐个判断一个是/否问题，返回每个候选为“是”的概率(0-1)。适合：用户说的是哪件物品、是纠正还是新增、两条记录是否同一样东西。结果是参考，不是授权；失败时自己判断并继续。","strict":true,"parameters":{"type":"object","properties":{"request":{"type":"string"},"question":{"type":"string"},"candidates":{"type":"array","minItems":1,"maxItems":8,"items":{"type":"object","properties":{"id":{"type":"string"},"text":{"type":"string"}},"required":["id","text"],"additionalProperties":false}}},"required":["request","question","candidates"],"additionalProperties":false}}
    """#

    // MARK: - Execution

    /// Read-only, bounded data for this turn. Bypasses judgment, proposals and cached results.
    /// A failed store is reported explicitly while the other selected store can still succeed.
    func prefetch(inventory: Bool, notes: Bool) async throws -> [PrefetchedToolResult] {
        try Task.checkCancellation()
        var results: [PrefetchedToolResult] = []
        let selected = [("search_inventory", inventory), ("search_notes", notes)]
        for (name, enabled) in selected where enabled {
            try Task.checkCancellation()
            let isInventory = name == "search_inventory"
            let arguments = isInventory ? #"{"query":"","include_finished":false}"# : #"{"query":""}"#
            let call = LocalToolCall(id: "prefetch_" + UUID().uuidString, name: name, arguments: arguments)
            let source = isInventory ? "local_inventory" : "local_notes"
            let scope = isInventory ? Self.inventoryScope(query: "", includeFinished: false) : Self.notesScope
            let output: String
            do {
                let value = isInventory
                    ? try await searchInventory("", includeFinished: false, limit: 40, byteBudget: 12_000, useJev: false)
                    : try prefetchedNotes()
                try Task.checkCancellation()
                output = try encode(value)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                output = try encode([
                    "source": source, "queried_at": Self.queryTimestamp, "scope": scope,
                    "error": error.localizedDescription, "count": NSNull(), "returned_count": 0,
                    "complete": false, "truncated": false,
                ] as [String: Any])
            }
            results.append(PrefetchedToolResult(call: call, output: output))
        }
        try Task.checkCancellation()
        return results
    }

    func execute(_ call: LocalToolCall) async -> String {
        insistedConcern = nil
        defer { insistedConcern = nil }
        do {
            let data = Data(call.arguments.utf8)
            if let output = try await executeWeatherTool(call.name, data: data) { return output }
            if let output = try executeItemTool(call.name, data: data) { return output }
            if let output = try executePendingTool(call.name, data: data) { return output }
            if let output = try executeContextTool(call.name, data: data) { return output }
            switch call.name {
            case "search_inventory":
                struct Args: Decodable { var query: String; var include_finished: Bool }
                let args = try JSONDecoder().decode(Args.self, from: data)
                return try encode(await searchInventory(args.query, includeFinished: args.include_finished))
            case "propose_add_items":
                struct Item: Decodable {
                    var name: String; var quantity: Int; var unit: String
                    var storage: String?; var package_expiry: String?; var planned_use_by: String?
                    var track: String?
                    var profile: ItemProfileInput?
                }
                struct Args: Decodable { var items: [Item] }
                let args = try JSONDecoder().decode(Args.self, from: data)
                let items = try args.items.map { item in
                    var new = try newItem(name: item.name, quantity: item.quantity, unit: item.unit, storage: item.storage,
                                          packageExpiry: try Self.date(item.package_expiry),
                                          plannedUseBy: try Self.date(item.planned_use_by))
                    new.profile = try item.profile?.profile(photos: inputPhotos)
                    new.quantityOnly = item.track == "quantity" || new.profile?.category.durable == true
                    if new.quantityOnly { new.packageExpiry = nil; new.plannedUseBy = nil }
                    return new
                }
                let review = await reviewAdd(items)
                if let rejected = gate("add|" + call.arguments, review) { return rejected }
                for item in items { proposeAdd(item, check: review.check) }
            case "propose_set_quantity":
                struct Args: Decodable { var lot_id: String; var quantity: Int }
                let args = try JSONDecoder().decode(Args.self, from: data)
                let lot = try activeLot(args.lot_id)
                guard (0...999).contains(args.quantity) else { throw ToolError("数量需要在 0 到 999 之间") }
                var extra: [JevClient.Question] = []
                let used = lot.quantity - args.quantity
                if args.quantity != lot.quantity, used >= 0, used != args.quantity {
                    extra = [.init(id: "m.remain", question: Self.meaningQuestion,
                                   candidate: "\(lot.name) 现在还剩 \(args.quantity) \(lot.unit)"),
                             .init(id: "m.used", question: Self.meaningQuestion,
                                   candidate: "\(lot.name) 用掉了 \(args.quantity) \(lot.unit)，还剩 \(used) \(lot.unit)")]
                }
                let review = await reviewTarget(lot, extra: extra) { answers in
                    guard let remain = answers["m.remain"], let usedP = answers["m.used"], usedP > remain + 0.2 else { return nil }
                    return "“\(args.quantity)”更可能是用掉的数量：\(lot.name) 原有 \(lot.quantity)，用掉 \(args.quantity) 后应剩 \(used)"
                }
                if let rejected = gate("qty|\(lot.id)|\(args.quantity)", review) { return rejected }
                if args.quantity == 0 {
                    add(.close(lot, .depleted), title: "\(lot.name) 用完了", detail: "原有 \(lot.quantity) \(lot.unit)", check: review.check)
                } else {
                    add(.setQuantity(lot, args.quantity), title: "\(lot.name) 剩 \(args.quantity) \(lot.unit)",
                        detail: "原来 \(lot.quantity) \(lot.unit)", check: review.check)
                }
            case "propose_close":
                struct Args: Decodable { var lot_id: String; var reason: String }
                let args = try JSONDecoder().decode(Args.self, from: data)
                let lot = try activeLot(args.lot_id)
                let (state, verb): (InventoryLotState, String) = switch args.reason {
                case "discarded": (.discarded, "丢掉")
                case "gifted": (.gifted, "送人")
                default: (.depleted, "用完了")
                }
                let review = await reviewTarget(lot)
                if let rejected = gate("close|\(lot.id)|\(args.reason)", review) { return rejected }
                add(.close(lot, state), title: "\(lot.name) \(verb)", detail: "\(lot.quantity) \(lot.unit)", check: review.check)
            case "propose_set_date":
                struct Args: Decodable { var lot_id: String; var kind: String; var date: String? }
                let args = try JSONDecoder().decode(Args.self, from: data)
                let lot = try activeLot(args.lot_id)
                let kind: LotDateKind = args.kind == "package_expiry" ? .packageExpiry : .plannedUseBy
                let date = try Self.date(args.date)
                let label = kind == .packageExpiry ? "包装有效期" : "计划吃完"
                var extra: [JevClient.Question] = []
                if kind == .packageExpiry, let date, !hasPhotos {
                    extra = [.init(id: "d.stated", question: Self.statedDateQuestion,
                                   candidate: "\(lot.name) 包装有效期 \(date.isoDay)")]
                }
                let review = await reviewTarget(lot, extra: extra) { answers in
                    guard let stated = answers["d.stated"], stated < 0.3 else { return nil }
                    return "这个包装有效期看起来不是用户明确说出的，不要推测包装日期"
                }
                if let rejected = gate("date|\(lot.id)|\(args.kind)|\(args.date ?? "")", review) { return rejected }
                add(.setDate(lot, kind, date), title: "\(lot.name) \(label)",
                    detail: date.map { "改为 \($0.monthDay)" } ?? "清除这个日期", check: review.check)
            case "propose_move":
                struct Args: Decodable { var lot_id: String; var location: String }
                let args = try JSONDecoder().decode(Args.self, from: data)
                let lot = try activeLot(args.lot_id)
                let location = args.location.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !location.isEmpty, location.count <= 40 else { throw ToolError("位置不能为空") }
                let review = await reviewTarget(lot)
                if let rejected = gate("move|\(lot.id)|\(location)", review) { return rejected }
                add(.move(lot, location), title: "\(lot.name) 放到 \(location)",
                    detail: lot.storageLocation.map { "原来在 \($0)" }, check: review.check)
            case "propose_set_tracking":
                struct Args: Decodable { var lot_id: String; var track: String }
                let args = try JSONDecoder().decode(Args.self, from: data)
                let lot = try activeLot(args.lot_id)
                let quantityOnly = args.track == "quantity"
                guard quantityOnly != lot.quantityOnly else { throw ToolError("已经是这种记录方式了") }
                add(.tracking(lot, quantityOnly: quantityOnly),
                    title: quantityOnly ? "\(lot.name) 只记数量" : "\(lot.name) 开始跟踪到期",
                    detail: quantityOnly ? "不再问过期日期，也不发到期提醒" : "之后会问日期并按日期提醒")
            case "conversation_overview":
                guard let archive = conversation?() else { throw ToolError("没有对话记录") }
                return try encode(archive.overview())
            case "search_conversation":
                struct Args: Decodable { var query: String; var from_date: String?; var to_date: String?; var limit: Int? }
                let args = try JSONDecoder().decode(Args.self, from: data)
                guard let archive = conversation?() else { throw ToolError("没有对话记录") }
                return try encode(archive.search(args.query, from: try Self.date(args.from_date),
                                                 to: try Self.date(args.to_date), limit: args.limit ?? 10))
            case "read_conversation":
                struct Args: Decodable { var from_turn: Int?; var to_turn: Int?; var from_date: String?; var to_date: String?; var cursor: Int? }
                let args = try JSONDecoder().decode(Args.self, from: data)
                guard let archive = conversation?() else { throw ToolError("没有对话记录") }
                return try encode(archive.read(fromTurn: args.from_turn, toTurn: args.to_turn,
                                               from: try Self.date(args.from_date), to: try Self.date(args.to_date),
                                               cursor: args.cursor))
            case "propose_reminder":
                struct Args: Decodable { var text: String; var time: String; var `repeat`: String }
                let args = try JSONDecoder().decode(Args.self, from: data)
                let text = args.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= 200 else { throw ToolError("提醒内容不能为空") }
                guard let date = Self.dateTime(args.time) else { throw ToolError("时间格式需要是 YYYY-MM-DD HH:mm") }
                let repeats = TimedReminder.Repeat(rawValue: args.`repeat`) ?? .none
                guard repeats != .none || date > Date.now.addingTimeInterval(30) else {
                    throw ToolError("这个时间已经过了（现在是 \(Self.nowLabel)），请和用户确认时间")
                }
                let reminder = TimedReminder(text: text, fireDate: date, repeats: repeats)
                add(.reminder(reminder), title: "提醒：\(text)", detail: reminder.whenLabel)
            case "list_reminders":
                return try encode(["now": Self.nowLabel, "reminders": reminders.upcoming.map {
                    ["id": $0.id.uuidString, "text": $0.text, "when": $0.whenLabel] as [String: Any]
                }] as [String: Any])
            case "propose_cancel_reminder":
                struct Args: Decodable { var id: String }
                let raw = try JSONDecoder().decode(Args.self, from: data).id
                guard let reminder = reminders.upcoming.first(where: { $0.id.uuidString == raw }) else {
                    throw ToolError("找不到这个提醒，请先 list_reminders")
                }
                add(.cancelReminder(reminder), title: "取消提醒：\(reminder.text)", detail: reminder.whenLabel)
            case "search_notes":
                struct Args: Decodable { var query: String }
                let query = try JSONDecoder().decode(Args.self, from: data).query
                let records = query.trimmingCharacters(in: .whitespaces).isEmpty
                    ? notes.records : notes.records.filter { ($0.title + "\n" + $0.text).localizedStandardContains(query) }
                return try encode(records.map { ["id": $0.id.uuidString, "title": $0.title, "text": $0.text] })
            case "propose_note":
                struct Args: Decodable { var id: String?; var title: String; var text: String }
                let args = try JSONDecoder().decode(Args.self, from: data)
                let existing = try args.id.map { raw -> LocalMemory in
                    guard let uuid = UUID(uuidString: raw), let found = notes.records.first(where: { $0.id == uuid }) else {
                        throw ToolError("找不到这条笔记，请先 search_notes")
                    }
                    return found
                }
                guard !args.title.trimmingCharacters(in: .whitespaces).isEmpty,
                      !args.text.trimmingCharacters(in: .whitespaces).isEmpty else { throw ToolError("标题和内容不能为空") }
                let memory = LocalMemory(id: existing?.id ?? UUID(), title: args.title, text: args.text,
                                         quantity: existing?.quantity, revision: (existing?.revision ?? 0) + 1)
                add(.note(memory), title: (existing == nil ? "记住：" : "更正：") + args.title, detail: args.text)
            case "judge_with_jev":
                guard jev.isAvailable else { throw ToolError("Jev 未启用或未配置，请继续处理，不要调用 Jev") }
                struct Args: Decodable { var request: String; var question: String; var candidates: [JevClient.Candidate] }
                let args = try JSONDecoder().decode(Args.self, from: data)
                let answers = try await jev.judge(request: args.request, questions: args.candidates.map {
                    JevClient.Question(id: $0.id, question: args.question, candidate: $0.text)
                })
                return try encode(["source": "jev", "judgments": args.candidates.compactMap { candidate in
                    answers[candidate.id].map { ["id": candidate.id, "probability": $0] as [String: Any] }
                }] as [String: Any])
            default:
                return #"{"error":"unknown_tool"}"#
            }
            return "{\"status\":\"waiting_for_user_confirmation\",\"pending_changes\":\(pending.count),\"saved\":false}"
        } catch let error as ToolError {
            return (try? encode(["error": error.message, "saved": false] as [String: Any])) ?? #"{"error":"invalid"}"#
        } catch let error as ReminderSchedule.InvalidRule {
            return (try? encode(["error": error.localizedDescription, "saved": false] as [String: Any])) ?? #"{"error":"invalid_rule"}"#
        } catch let error as JevClient.JevError {
            return (try? encode(["error": "jev_failed", "detail": error.localizedDescription,
                                 "hint": "自己判断并继续"] as [String: Any])) ?? #"{"error":"jev_failed"}"#
        } catch {
            return #"{"error":"invalid_arguments","saved":false}"#
        }
    }

    /// Applies every pending change in order. Returns one line per change for the chat and the model.
    func confirmAll(ids: Set<UUID>? = nil) -> [String] {
        let selected = pending.filter { ids == nil || ids!.contains($0.id) }
        let selectedIDs = Set(selected.map(\.id))
        // Validate all previews before this batch changes revisions itself.
        var stale: Set<UUID> = []
        for change in selected {
            if let preview = change.inventoryPreview {
                if (try? activeLot(preview.id.uuidString).revision) != preview.revision { stale.insert(change.id) }
            }
        }
        let actions = InventoryActions(modelContainer: container)
        var results: [String] = []
        let adds = selected.compactMap { change -> (PendingChange, InventoryActions.NewItem)? in
            if case .add(let item) = change.kind { return (change, item) }
            return nil
        }
        if !adds.isEmpty {
            do {
                let addedIDs = try actions.add(adds.map(\.1), sourceText: "对话中确认")
                relatedScopes.formUnion(addedIDs.map { .lot($0) })
                results += adds.map { "✓ \($0.0.title)" }
            } catch {
                results += adds.map { "✗ \($0.0.title)：\(error.localizedDescription)" }
            }
        }
        for change in selected {
            do {
                guard !stale.contains(change.id) else { throw ToolError("物品已改变，请重新查询并确认") }
                switch change.kind {
                case .add: continue
                case .setQuantity(let lot, let quantity): try actions.adjustQuantity(try fresh(lot), to: quantity)
                case .close(let lot, let state): try actions.close(try fresh(lot), as: state)
                case .setDate(let lot, let kind, let date): try actions.setDate(date, kind: kind, for: try fresh(lot))
                case .move(let lot, let location): try actions.move(try fresh(lot), to: location)
                case .tracking(let lot, let quantityOnly):
                    if lot.isDurable { throw ToolError("耐用品通过物品资料管理，不使用食品跟踪方式") }
                    try actions.setQuantityOnly(quantityOnly, productID: lot.productID)
                case .itemProfile(let lot, let profile): try actions.setProfile(profile, for: try fresh(lot))
                case .undoInventory(let lot, let eventID):
                    let current = try lotFacts(lot.id)
                    guard current.revision == lot.revision else { throw ToolError("物品已改变，请重新查询") }
                    try actions.undo(try inventoryEvent(eventID), for: current)
                case .note(let memory): try notes.upsert(memory)
                case .reminder(let reminder): try reminders.add(reminder)
                case .cancelReminder(let reminder):
                    try requireTaskRevision(reminder.id, reminder.revision)
                    try reminders.remove(reminder.id)
                case .taskPlan(let reminder, let revision):
                    if let revision {
                        try requireTaskRevision(reminder.id, revision)
                        try reminders.update(reminder)
                    } else { try reminders.add(reminder) }
                case .taskAction(let id, let action, let revision):
                    try requireTaskRevision(id, revision)
                    if let task = reminders.reminder(id: id) { try validateTaskAction(action, reminder: task) }
                    switch action {
                    case .complete: try reminders.complete(id)
                    case .pause: try reminders.pause(id)
                    case .resume: try reminders.resume(id)
                    case .reopen: try reminders.reopen(id)
                    case .cancel: try reminders.remove(id)
                    case .delete: try reminders.delete(id, expectedRevision: revision)
                    }
                case .weatherLocation(let selection, let before):
                    try weather.setLocation(selection, expected: before)
                    Task { await weather.refresh(force: true) }
                case .settings(let changes):
                    try ButlerSettingsService.apply(changes, defaults: settingsDefaults, jev: jev as? JevClient)
                }
                results.append("✓ \(change.title)")
            } catch {
                results.append("✗ \(change.title)：\(error.localizedDescription)")
            }
        }
        pending.removeAll { selectedIDs.contains($0.id) }
        return results
    }

    // MARK: - Helpers

    struct ToolError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Set by `gate` when the model re-proposed despite Jev; consumed by the next `add`s of this call.
    private var insistedConcern: String?

    func add(_ kind: PendingChange.Kind, title: String, detail: String?, check: JevCheck? = nil) {
        switch kind {
        case .setQuantity(let lot, _), .close(let lot, _), .setDate(let lot, _, _), .move(let lot, _), .tracking(let lot, _):
            relatedScopes.insert(.lot(lot.id))
        case .itemProfile(let lot, _), .undoInventory(let lot, _): relatedScopes.insert(.lot(lot.id))
        case .reminder(let value), .cancelReminder(let value), .taskPlan(let value, _): relatedScopes.insert(.task(value.id))
        case .taskAction(let id, _, _): relatedScopes.insert(.task(id))
        case .settings, .weatherLocation: relatedScopes.insert(.settings)
        default: break
        }
        pending.append(PendingChange(kind: kind, title: title, detail: detail,
                                     check: insistedConcern.map { .concern($0) } ?? check))
    }

    private func newItem(name: String, quantity: Int, unit: String, storage: String?,
                         packageExpiry: Date?, plannedUseBy: Date?) throws -> InventoryActions.NewItem {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, (1...999).contains(quantity) else { throw ToolError("名称或数量不合理") }
        let candidates = try CatalogProductLookup(modelContainer: container).exactMatches(for: name)
        let linked = candidates.count == 1 ? candidates.first?.id : nil
        return InventoryActions.NewItem(name: name, quantity: quantity, unit: unit.isEmpty ? "份" : unit,
                                        storage: storage?.isEmpty == true ? nil : storage,
                                        packageExpiry: packageExpiry, plannedUseBy: plannedUseBy,
                                        existingProductID: linked)
    }

    private func proposeAdd(_ item: InventoryActions.NewItem, check: JevCheck?) {
        var parts: [String] = []
        if let storage = item.storage { parts.append(storage) }
        if let profile = item.profile { parts.append(profile.searchText); if profile.photo != nil { parts.append("含照片") } }
        else if item.quantityOnly { parts.append("只记数量") }
        if let date = item.packageExpiry { parts.append("包装有效期 \(date.monthDay)") }
        if let date = item.plannedUseBy { parts.append("\(date.monthDay)前吃完") }
        if item.existingProductID != nil { parts.append("家里已有同款") }
        add(.add(item), title: "新增 \(item.name) ×\(item.quantity) \(item.unit)",
            detail: parts.isEmpty ? nil : parts.joined(separator: " · "), check: check)
    }

    // MARK: - Judgment layer (Jev between the model and the data)

    static let targetQuestion = "用户这句话说的是这一件物品吗？"
    static let relevanceQuestion = "这件物品与用户这句话提到或询问的东西有关吗？"
    static let meaningQuestion = "用户这句话的意思是这个结果吗？"
    static let statedDateQuestion = "这个日期是用户在对话里明确说出的吗？"
    static let newPurchaseQuestion = "对于家里已有的这件物品，用户这句话是在说又新买了一份（而不是在说这件本身，或纠正它的信息）吗？"

    private struct Review {
        var checked = false
        var concern: String?
        var check: JevCheck? { checked ? .passed : nil }
    }

    /// Why Jev was skipped this turn, if it failed. Reported to the model, never blocks.
    private var jevFailure: String?

    private var jevRequest: String {
        guard let previous, !previous.isEmpty else { return request }
        return "上一句：\(previous)\n这一句：\(request)"
    }

    /// nil when Jev is off, unconfigured or failed; callers proceed exactly as without Jev.
    private func ask(_ questions: [JevClient.Question]) async -> [String: Double]? {
        guard jev.isAvailable, !request.isEmpty, !questions.isEmpty else { return nil }
        do {
            let answers = try await jev.judge(request: jevRequest, questions: questions)
            jevFailure = nil
            return answers
        } catch {
            jevFailure = error.localizedDescription
            return nil
        }
    }

    /// Checks that `lot` is what the owner means (against same-name siblings) plus any extra questions.
    private func reviewTarget(_ lot: LotFacts, extra: [JevClient.Question] = [],
                              interpret: ([String: Double]) -> String? = { _ in nil }) async -> Review {
        let siblings = (try? siblings(of: lot)) ?? []
        let questions = ([lot] + siblings).map {
            JevClient.Question(id: "t." + $0.id.uuidString, question: Self.targetQuestion, candidate: Self.jevText($0))
        } + extra
        guard let answers = await ask(questions) else { return Review() }
        var review = Review(checked: true)
        let target = answers["t." + lot.id.uuidString] ?? 1
        let best = siblings.map { ($0, answers["t." + $0.id.uuidString] ?? 0) }.max { $0.1 < $1.1 }
        if let (other, p) = best, target < 0.5, p > target + 0.2 {
            review.concern = "用户更可能指的是另一件：\(Self.jevText(other))（lot_id \(other.id.uuidString)）"
        } else if target < 0.3 {
            review.concern = "用户可能不是在说这件（\(Self.jevText(lot))）"
        } else {
            review.concern = interpret(answers)
        }
        return review
    }

    /// For each new item that already exists at home: is it really a new purchase? Is a package date stated?
    private func reviewAdd(_ items: [InventoryActions.NewItem]) async -> Review {
        var questions: [JevClient.Question] = []
        var existing: [Int: [LotFacts]] = [:]
        for (index, item) in items.enumerated() {
            let lots = ((try? activeLots()) ?? []).filter { $0.name == item.name || $0.productID == item.existingProductID }
            existing[index] = Array(lots.prefix(4))
            questions += lots.prefix(4).map {
                .init(id: "n.\(index).\($0.id.uuidString)", question: Self.newPurchaseQuestion,
                      candidate: Self.jevText($0) + "；用户这次提到：\(item.name) ×\(item.quantity) \(item.unit)")
            }
            if let date = item.packageExpiry, !hasPhotos {
                questions.append(.init(id: "d.\(index)", question: Self.statedDateQuestion,
                                       candidate: "\(item.name) 包装有效期 \(date.isoDay)"))
            }
        }
        guard !questions.isEmpty else { return Review() }
        guard let answers = await ask(questions) else { return Review() }
        var review = Review(checked: true)
        for (index, item) in items.enumerated() {
            let lots = existing[index] ?? []
            let newP = lots.map { answers["n.\(index).\($0.id.uuidString)"] ?? 1 }
            if let first = lots.first, let highest = newP.max(), highest < 0.4 {
                review.concern = "用户可能是在说家里已有的 \(Self.jevText(first))（lot_id \(first.id.uuidString)），不是新买；如果是纠正，请修改原记录"
                break
            }
            if let stated = answers["d.\(index)"], stated < 0.3 {
                review.concern = "\(item.name) 的包装有效期看起来不是用户明确说出的，不要推测，改为 null"
                break
            }
        }
        return review
    }

    /// nil = go ahead. Otherwise the tool output telling the model what Jev objected to.
    private func gate(_ signature: String, _ review: Review) -> String? {
        guard let concern = review.concern else { return nil }
        if raisedConcerns.contains(signature) { insistedConcern = concern; return nil }
        raisedConcerns.insert(signature)
        return (try? encode(["status": "needs_review", "saved": false, "jev_concern": concern,
                             "hint": "请按这个判断修正后重新提出；拿不准就直接问用户，不要猜。如果你仍确定原提议正确，可以原样再提一次，卡片上会显示这条提醒让用户决定。"]
                            as [String: Any])) ?? #"{"status":"needs_review","saved":false}"#
    }

    func allLots() throws -> [(InventoryLot, CatalogProduct?)] {
        let context = ModelContext(container)
        let products = Dictionary(try context.fetch(FetchDescriptor<CatalogProduct>()).map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        return try context.fetch(FetchDescriptor<InventoryLot>()).map { ($0, products[$0.productID]) }
    }

    private func activeLots() throws -> [LotFacts] {
        try allLots().filter { $0.0.state == .active }.map { LotFacts(lot: $0.0, product: $0.1) }
    }

    private func siblings(of lot: LotFacts) throws -> [LotFacts] {
        Array(try activeLots().filter { $0.id != lot.id && ($0.productID == lot.productID || $0.name == lot.name) }.prefix(6))
    }

    /// One line Jev can read about a lot.
    static func jevText(_ lot: LotFacts) -> String {
        var parts = [lot.name + (lot.brand.map { "（\($0)）" } ?? ""), "\(lot.quantity) \(lot.unit)"]
        if let storage = lot.storageLocation { parts.append("放在\(storage)") }
        if let profile = lot.profile { parts.append(profile.searchText) }
        parts.append("\(lot.startedAt.monthDay)买的")
        if let date = lot.governingDate {
            parts.append((lot.governingDateKind == .plannedUseBy ? "计划 " : "有效期 ") + date.monthDay)
        }
        return parts.joined(separator: "，")
    }

    func activeLot(_ raw: String) throws -> LotFacts {
        guard let id = UUID(uuidString: raw),
              let (lot, product) = try allLots().first(where: { $0.0.id == id }) else {
            throw ToolError("找不到这件物品，请先用 search_inventory 查到它的 lot_id")
        }
        guard lot.state == .active else { throw ToolError("这件物品已经处理掉了") }
        return LotFacts(lot: lot, product: product)
    }

    /// Re-reads a lot right before writing. A change made in between (by the owner or an earlier
    /// change in this batch) is fine as long as it's the same lot and still active.
    private func fresh(_ lot: LotFacts) throws -> LotFacts {
        try activeLot(lot.id.uuidString)
    }

    private func searchInventory(_ query: String, includeFinished: Bool, limit: Int = 80,
                                 byteBudget: Int? = nil, useJev: Bool = true) async throws -> [String: Any] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lots = try allLots()
        // "牛奶 鸡蛋" or "牛奶、鸡蛋" matches either word.
        let words = query.split(whereSeparator: { " ,，、;；".contains($0) }).map(String.init)
        func matches(_ lot: InventoryLot, _ product: CatalogProduct?) -> Bool {
            guard !words.isEmpty else { return true }
            let haystack = [product?.canonicalName, product?.brand, lot.storageLocation, lot.itemProfile?.searchText, ItemProfile.inferred(name: product?.canonicalName ?? "", legacyCategory: product?.categoryRawValue).category.title].compactMap { $0 }.joined(separator: " ")
            return words.contains { word in
                haystack.localizedStandardContains(word)
                    || (product?.canonicalName).map { !$0.isEmpty && word.localizedStandardContains($0) } == true
            }
        }
        let allActive = lots.filter { $0.0.state == .active }.map { LotFacts(lot: $0.0, product: $0.1) }
            .sorted { ($0.daysLeft ?? .max) < ($1.daysLeft ?? .max) }
        var active = lots.filter { $0.0.state == .active && matches($0.0, $0.1) }
            .map { LotFacts(lot: $0.0, product: $0.1) }
            .sorted { ($0.daysLeft ?? .max) < ($1.daysLeft ?? .max) }
        var items = active.map(Self.describe)
        var semanticExcludedCount = 0
        var result: [String: Any] = [
            "today": Date.now.isoDay, "queried_at": Self.queryTimestamp, "source": "local_inventory",
            "scope": Self.inventoryScope(query: query, includeFinished: includeFinished),
            "count_unit": "inventory_lots", "quantity_semantics": "每个批次的quantity是该批次的剩余数量，单位见unit；不同单位不可直接相加",
        ]

        // Jev between the data and the model: rank what the words matched, or find what they missed.
        // An overview ("" query) has nothing to disambiguate and is left as is.
        if useJev && !words.isEmpty {
            let pool = active.count >= 2 && active.count <= 30 ? active
                : active.isEmpty && allActive.count <= 60 ? allActive : []
            let answers = await ask(pool.map {
                .init(id: $0.id.uuidString, question: Self.relevanceQuestion, candidate: Self.jevText($0))
            })
            if let answers {
                let keywordMissed = active.isEmpty
                let scored = pool.map { ($0, answers[$0.id.uuidString] ?? 0) }
                let kept = active.isEmpty ? scored.filter { $0.1 >= 0.5 } : scored // never drop what the words matched
                active = kept.sorted { $0.1 > $1.1 }.map(\.0)
                items = kept.sorted { $0.1 > $1.1 }.map { lot, p in
                    var item = Self.describe(lot)
                    item["relevance"] = (p * 100).rounded() / 100
                    return item
                }
                result["judged_by"] = "jev"
                if keywordMissed {
                    semanticExcludedCount = pool.count - kept.count
                    result["semantically_filtered"] = true
                    result["semantic_excluded_count"] = semanticExcludedCount
                    result["semantic_candidate_count"] = pool.count
                    result["hint"] = "Jev相关性筛选可能漏项，不能据此断言没有；可查询全部或更换关键词"
                    result["found_by"] = "jev（关键词没有直接命中）"
                    result["scope"] = Self.inventoryScope(query: query, includeFinished: includeFinished,
                                                          matchMethod: "jev_candidate_pool")
                }
            } else if let jevFailure, !pool.isEmpty {
                result["jev"] = "暂时不可用（\(jevFailure)），以下是未经判断的原始结果"
            }
        }
        items = try Self.boundedRecords(items, limit: limit, byteBudget: byteBudget)
        let activeComplete = items.count == active.count && semanticExcludedCount == 0
        result["count"] = active.count
        result["returned_count"] = items.count
        result["complete"] = activeComplete
        result["truncated"] = items.count < active.count
        result["active_complete"] = activeComplete
        result["active_truncated"] = items.count < active.count
        result["items"] = items
        // A specific search is a real reference. Broad overviews/prefetch must not attach
        // every household item to a conversation that may never discuss any of them.
        let referencedItems = words.isEmpty ? items.filter {
            guard let name = $0["name"] as? String, !name.isEmpty else { return false }
            return request.localizedStandardContains(name)
        } : items
        relatedScopes.formUnion(referencedItems.compactMap { ($0["lot_id"] as? String).flatMap(UUID.init).map(ChatScope.lot) })
        if includeFinished {
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
            let finished = lots.filter { $0.0.state != .active && $0.0.updatedAt >= cutoff && matches($0.0, $0.1) }
                .sorted { $0.0.updatedAt > $1.0.updatedAt }
            let returned = finished.prefix(30)
                .map { lot, product in
                    ["lot_id": lot.id.uuidString, "name": product?.canonicalName ?? "未命名",
                     "state": lot.state.rawValue, "when": lot.updatedAt.isoDay] as [String: Any]
                }
            result["finished"] = returned
            if !words.isEmpty {
                relatedScopes.formUnion(returned.compactMap { ($0["lot_id"] as? String).flatMap(UUID.init).map(ChatScope.lot) })
            }
            result["finished_count"] = finished.count
            result["finished_returned_count"] = returned.count
            result["finished_complete"] = finished.count == returned.count
            result["finished_truncated"] = finished.count > returned.count
            result["complete"] = activeComplete && finished.count == returned.count
            result["truncated"] = items.count < active.count || finished.count > returned.count
        }
        return result
    }

    private static var queryTimestamp: String { ISO8601DateFormatter().string(from: .now) }

    private static func inventoryScope(query: String, includeFinished: Bool, matchMethod: String? = nil) -> [String: Any] {
        ["query": query, "active_states": ["active"], "include_finished": includeFinished,
         "match_method": matchMethod ?? (query.isEmpty ? "all_active" : "keyword"),
         "complete_means": "all_matching_records_returned_within_scope",
         "finished_window_days": includeFinished ? 30 : 0,
         "finished_date_field": "updated_at", "conversation_history_included": false,
         "older_finished_included": false]
    }

    private static var notesScope: [String: Any] {
        ["query": "", "records": "current_saved_notes", "conversation_history_included": false,
         "inventory_included": false, "previous_note_revisions_included": false]
    }

    private func prefetchedNotes() throws -> [String: Any] {
        let records = notes.records
        let all = records.map { note -> [String: Any] in
            var record: [String: Any] = ["id": note.id.uuidString, "title": note.title,
                                          "text": note.text, "revision": note.revision]
            if let quantity = note.quantity { record["quantity"] = quantity }
            return record
        }
        let returned = try Self.boundedRecords(all, limit: 20, byteBudget: 8_000)
        return ["source": "local_notes", "queried_at": Self.queryTimestamp, "scope": Self.notesScope,
                "count": records.count, "count_unit": "notes", "returned_count": returned.count,
                "complete": returned.count == records.count, "truncated": returned.count < records.count,
                "notes": returned]
    }

    /// Measures the exact JSON array's UTF-8 bytes, including brackets and commas. A record is
    /// included whole or skipped; a large record must not hide smaller records after it.
    private static func boundedRecords(_ records: [[String: Any]], limit: Int, byteBudget: Int?) throws -> [[String: Any]] {
        guard let byteBudget else { return Array(records.prefix(limit)) }
        var returned: [[String: Any]] = []
        var bytes = 2 // []
        for record in records {
            guard returned.count < limit else { break }
            let recordBytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).count
            let addedBytes = recordBytes + (returned.isEmpty ? 0 : 1)
            guard bytes + addedBytes <= byteBudget else { continue }
            returned.append(record)
            bytes += addedBytes
        }
        return returned
    }

    private static func describe(_ lot: LotFacts) -> [String: Any] {
        var item: [String: Any] = ["lot_id": lot.id.uuidString, "name": lot.name, "quantity": lot.quantity,
                                   "unit": lot.unit, "time_left": lot.timeLeftLabel]
        if let brand = lot.brand { item["brand"] = brand }
        if let storage = lot.storageLocation { item["storage"] = storage }
        if let days = lot.daysLeft { item["days_left"] = days }
        if let kind = lot.governingDateKind { item["governing_date_kind"] = kind.rawValue }
        if let date = lot.governingDate { item["governing_date"] = date.isoDay }
        if lot.isMedicine { item["is_medicine"] = true }
        item["revision"] = lot.revision
        item["category"] = lot.category.rawValue
        item["category_label"] = lot.category.title
        if let profile = lot.profile {
            item["attributes"] = profile.attributes; item["tags"] = profile.tags
            item["availability"] = profile.availability; item["has_photo"] = profile.photo != nil
        }
        item["track"] = lot.quantityOnly ? "quantity" : "expiry"
        item["bought"] = lot.startedAt.isoDay
        return item
    }

    static var nowLabel: String {
        Date.now.isoDay + " " + Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    /// "2026-09-27 11:00" (also accepts a "T" separator) in the phone's time zone.
    static func dateTime(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: raw.replacingOccurrences(of: "T", with: " ").prefix(16).description)
    }

    private static func date(_ raw: String?) throws -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: raw) else { throw ToolError("日期格式需要是 YYYY-MM-DD") }
        return date
    }

    func encode(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}

extension Date {
    /// "2026-09-27" in the device time zone.
    var isoDay: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: self)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
