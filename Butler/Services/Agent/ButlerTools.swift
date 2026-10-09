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
        /// Who in the household can see a thing (household only).
        case itemSharing(LotFacts, ItemSharing.Scope, hiddenFrom: [UUID])
        case undoInventory(LotFacts, UUID)
        case note(LocalMemory)
        case reminder(TimedReminder)
        case cancelReminder(TimedReminder)
        case taskPlan(TimedReminder, expectedRevision: Int?)
        case taskAction(UUID, TaskAction, expectedRevision: Int)
        /// Who can see a task, who is responsible, who is reminded (household only).
        case taskSharing(UUID, TaskSharing?, expectedRevision: Int)
        case nudge(UUID)
        case householdRule(HouseholdRule, forMe: Bool)
        case removeHouseholdRule(HouseholdRule)
        case quietHours(QuietHours?)
        case settings([ButlerSettingChange])
        case weatherLocation(WeatherLocation, before: WeatherLocation)
        case alarm(ButlerAlarm.Change)
        case appleReminder(AppleReminderChange)
        case calendar(SystemCalendarChange)
        case taskDisplay(TaskDisplayChange)
        case health(HealthChange)
        case home(HomeChange)
        case contacts(ContactChange)
        case travel(TravelChange)
        case sync(SyncChange)
        case webPage(String)
        case folder(FolderChange)
    }

    var requiresAsyncConfirmation: Bool {
        switch kind { case .alarm, .appleReminder, .calendar, .taskDisplay, .health, .home, .contacts, .travel, .sync, .webPage, .folder: true; default: false }
    }

    var requiresSoleConfirmation: Bool {
        switch kind { case .home(let change): change.risky; case .sync, .webPage, .folder: true; default: false }
    }
    var persists: Bool { switch kind { case .health, .home, .contacts, .travel, .sync, .webPage, .folder: false; default: true } }

    var id = UUID()
    let kind: Kind
    /// One line the owner reads on the card, e.g. "新增 牛奶 ×2 瓶".
    let title: String
    let detail: String?
    /// What the judgment layer said. nil = not checked (no Jev key, or Jev unavailable).
    var check: JevCheck? = nil
    /// The request that proposed this exact version; nil means an unlinked legacy proposal.
    var requestTurnID: UUID?

    var relatedScope: ChatScope? {
        switch kind {
        case .setQuantity(let lot, _), .close(let lot, _), .setDate(let lot, _, _), .move(let lot, _), .tracking(let lot, _),
             .itemProfile(let lot, _), .undoInventory(let lot, _), .itemSharing(let lot, _, _): .lot(lot.id)
        case .reminder(let value), .cancelReminder(let value), .taskPlan(let value, _): .task(value.id)
        case .taskAction(let id, _, _), .taskSharing(let id, _, _), .nudge(let id): .task(id)
        case .taskDisplay(let change): .task(change.taskID)
        case .settings, .weatherLocation: .settings
        default: nil
        }
    }

    func result(_ state: ConfirmationResult.State, _ message: String) -> ConfirmationResult {
        ConfirmationResult(proposalID: id, requestTurnID: requestTurnID, title: title, state: state, message: message,
                           relatedScopeKeys: relatedScope.map { [$0.key] })
    }
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
    /// Why Jev was skipped this turn, if it failed. Reported to the model, never blocks.
    var jevFailure: String?
    var currentContext: (() -> String)?
    var weather: WeatherStore = .shared
    @ObservationIgnored lazy var alarms: AlarmStore = .shared
    @ObservationIgnored lazy var appleReminders: AppleReminderStore = .shared
    @ObservationIgnored lazy var systemCalendar: SystemCalendarStore = .shared
    @ObservationIgnored lazy var taskDisplays: TaskDisplayStore = TaskDisplayService.store
    @ObservationIgnored lazy var health: HealthStore = .shared
    @ObservationIgnored lazy var home: HomeStore = .shared
    @ObservationIgnored lazy var contacts: ContactsStore = .shared
    @ObservationIgnored lazy var travel: TravelStore = .shared
    @ObservationIgnored lazy var synchronization: SyncStore? = SyncService.shared.store
    @ObservationIgnored lazy var chatSynchronization: SyncStore? = SyncService.shared.chatStore
    @ObservationIgnored lazy var photoSynchronization: SyncStore? = SyncService.shared.photoStore
    @ObservationIgnored var webPageReader = WebPageReader(transport: AppleWebPageTransport())
    @ObservationIgnored lazy var folders = AppleFolderDevice.store
    var folderSelectionRequest: UUID?
    /// Display-only delivery; never append this payload to model messages or archived receipts.
    var onLocalHealthResult: ((String) -> Void)?
    var inputPhotos: [Data] = []
    var displayedCollection: ItemCollection?
    /// The list the conversation is currently showing, and this turn's edit of it (applied in place).
    var shownList: (() -> ItemCollection?)?
    var shownListEdit: ItemCollection?
    var conversationScope: ChatScope = .general
    var relatedScopes: Set<ChatScope> = []
    var settingsDefaults: UserDefaults = .standard
    /// What the owner said this turn (and just before), given to Jev as the request.
    var request = ""
    var previous: String?
    /// Jev can't see photos, so it can't judge whether a date came from a package in the picture.
    var hasPhotos = false
    /// Proposals Jev already pushed back on this turn. Proposing the same thing again means the
    /// model kept it; it then goes to the card with Jev's concern shown.
    var raisedConcerns: Set<String> = []

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

    private(set) var requestTurnID: UUID?

    func beginTurn(request: String, previous: String?, hasPhotos: Bool = false, turnID: UUID? = nil) {
        requestTurnID = turnID
        self.hasPhotos = hasPhotos
        self.request = hasPhotos ? request + "（用户附了照片）" : request
        self.previous = previous
        raisedConcerns = []
        relatedScopes = []
        displayedCollection = nil
        shownListEdit = nil
    }

    func removePending(_ id: UUID) { pending.removeAll { $0.id == id } }

    func endTurn() { requestTurnID = nil }

    // MARK: - Tool definitions

    var toolJSON: String {
        var tools = Self.inventoryTools + "," + Self.contextTools + "," + Self.pendingTools + "," + Self.itemTools + "," + Self.weatherTools + "," + Self.alarmTools + "," + Self.appleReminderTools + "," + Self.systemCalendarTools + "," + Self.taskDisplayTools + "," + Self.healthTools + "," + Self.homeTools
        tools += "," + Self.contactsTools + "," + Self.travelTools + "," + Self.syncTools + "," + Self.webPageTools + "," + Self.folderTools
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
    {"type":"function","name":"propose_reminder","description":"设一个定时提醒：到点时手机弹出通知。用于“11点提醒我热饭”“每天晚上9点提醒我吃药”“周六早上提醒我买菜”。time 为本地时间 YYYY-MM-DD HH:mm；repeat：none 只提醒一次，daily 每天这个时间，weekly 每周这一天这个时间。text 是通知里显示的话，简短具体。","strict":true,"parameters":{"type":"object","properties":{"text":{"type":"string"},"time":{"type":"string"},"repeat":{"type":"string","enum":["none","daily","weekly"]},"family":\#(TaskFamilyArgs.schemaJSON)},"required":["family","repeat","text","time"],"additionalProperties":false}},
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

    func execute(_ call: LocalToolCall) async -> String {
        insistedConcern = nil
        defer { insistedConcern = nil }
        do {
            let data = Data(call.arguments.utf8)
            if let output = try executeAlarmTool(call.name, data: data) { return output }
            if let output = try await executeAppleReminderTool(call.name, data: data) { return output }
            if let output = try executeSystemCalendarTool(call.name, data: data) { return output }
            if let output = try await executeTaskDisplayTool(call.name, data: data) { return output }
            if let output = try executeHealthTool(call.name, data: data) { return output }
            if let output = try await executeHomeTool(call.name, data: data) { return output }
            if let output = try executeContactsTool(call.name, data: data) { return output }
            if let output = try await executeTravelTool(call.name, data: data) { return output }
            if let output = try await executeSyncTool(call.name, data: data) { return output }
            if let output = try executeWebPageTool(call.name, data: data) { return output }
            if let output = try await executeFolderTool(call.name, data: data) { return output }
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
                struct Args: Decodable { var text: String; var time: String; var `repeat`: String; var family: TaskFamilyArgs? }
                let args = try JSONDecoder().decode(Args.self, from: data)
                let text = args.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= 200 else { throw ToolError("提醒内容不能为空") }
                guard let date = Self.dateTime(args.time) else { throw ToolError("时间格式需要是 YYYY-MM-DD HH:mm") }
                let repeats = TimedReminder.Repeat(rawValue: args.`repeat`) ?? .none
                guard repeats != .none || date > Date.now.addingTimeInterval(30) else {
                    throw ToolError("这个时间已经过了（现在是 \(Self.nowLabel)），请和用户确认时间")
                }
                var reminder = TimedReminder(text: text, fireDate: date, repeats: repeats)
                reminder.sharing = try taskSharing(args.family, existing: nil)
                add(.reminder(reminder), title: "提醒：\(text)", detail: reminder.whenLabel)
            case "list_reminders":
                return try encode(["now": Self.nowLabel, "reminders": reminders.upcoming.map {
                    ["id": $0.id.uuidString, "text": $0.text, "when": $0.whenLabel,
                     "notification_policy": notificationPolicy($0)] as [String: Any]
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
        } catch let error as AlarmFailure {
            return (try? encode(["error": error.localizedDescription, "saved": false] as [String: Any])) ?? #"{"error":"alarm_failed"}"#
        } catch let error as AppleReminderFailure {
            return (try? encode(["error": error.localizedDescription, "saved": false] as [String: Any])) ?? #"{"error":"system_reminder_failed"}"#
        } catch let error as CalendarFailure {
            return (try? encode(["error": error.localizedDescription, "saved": false] as [String: Any])) ?? #"{"error":"calendar_failed"}"#
        } catch let error as HealthFailure {
            return (try? encode(["error": error.message, "saved": false] as [String: Any])) ?? #"{"error":"health_failed"}"#
        } catch let error as HomeFailure {
            return (try? encode(["error": error.message, "saved": false] as [String: Any])) ?? #"{"error":"home_failed"}"#
        } catch let error as ContactFailure {
            return (try? encode(["error": error.message, "saved": false] as [String: Any])) ?? #"{"error":"contacts_failed"}"#
        } catch let error as TravelFailure {
            return (try? encode(["error": error.message, "saved": false] as [String: Any])) ?? #"{"error":"travel_failed"}"#
        } catch let error as SyncFailure {
            return (try? encode(["error": error.message] as [String: Any])) ?? #"{"error":"sync_failed"}"#
        } catch let error as JevClient.JevError {
            return (try? encode(["error": "jev_failed", "detail": error.localizedDescription,
                                 "hint": "自己判断并继续"] as [String: Any])) ?? #"{"error":"jev_failed"}"#
        } catch {
            return #"{"error":"invalid_arguments","saved":false}"#
        }
    }

    /// Applies every pending change in order. Returns one line per change for the chat and the model.
    func confirmAll(ids: Set<UUID>? = nil) -> [String] {
        confirmLocalResults(ids: ids).map(\.message)
    }

    func confirmLocalResults(ids: Set<UUID>? = nil) -> [ConfirmationResult] {
        let batch = pending.filter { ids == nil || ids!.contains($0.id) }
        guard batch.count <= 1 || !batch.contains(where: \.requiresSoleConfirmation) else {
            return batch.map { $0.result(.notStarted, "✗ 高风险家庭操作须单独确认；本批没有执行，提案均已保留。") }
        }
        let selected = pending.filter {
            if $0.requiresAsyncConfirmation { return false }
            return ids == nil || ids!.contains($0.id)
        }
        let selectedIDs = Set(selected.map(\.id))
        // Validate all previews before this batch changes revisions itself.
        var stale: Set<UUID> = []
        for change in selected {
            if let preview = change.inventoryPreview {
                if (try? activeLot(preview.id.uuidString).revision) != preview.revision { stale.insert(change.id) }
            }
        }
        let actions = InventoryActions(modelContainer: container)
        var results: [ConfirmationResult] = []
        let adds = selected.compactMap { change -> (PendingChange, InventoryActions.NewItem)? in
            if case .add(let item) = change.kind { return (change, item) }
            return nil
        }
        if !adds.isEmpty {
            do {
                let addedIDs = try actions.add(adds.map(\.1), sourceText: "对话中确认")
                relatedScopes.formUnion(addedIDs.map { .lot($0) })
                results += zip(adds, addedIDs).map { entry, id in
                    var result = entry.0.result(.succeeded, "✓ \(entry.0.title)")
                    result.relatedScopeKeys = [ChatScope.lot(id).key]
                    return result
                }
            } catch {
                results += adds.map { $0.0.result(.failed, "✗ \($0.0.title)：\(error.localizedDescription)") }
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
                case .itemSharing(let lot, let scope, let hidden):
                    guard HouseholdStore.shared.state != nil else { throw ToolError("还没有建立家庭") }
                    HouseholdService.shared.setScope(scope, for: lot.productID, hiddenFrom: Set(hidden))
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
                case .nudge(let id):
                    try HouseholdService.shared.nudge(id)
                case .householdRule(let rule, let forMe):
                    guard HouseholdStore.shared.state != nil else { throw ToolError("还没有建立家庭") }
                    HouseholdService.shared.addRule(rule.text, forMe: forMe)
                case .removeHouseholdRule(let rule):
                    HouseholdService.shared.removeRule(rule.id)
                case .quietHours(let quiet):
                    guard HouseholdStore.shared.state != nil else { throw ToolError("还没有建立家庭") }
                    HouseholdService.shared.setQuiet(quiet)
                case .taskSharing(let id, let sharing, let revision):
                    guard HouseholdStore.shared.state != nil else { throw ToolError("还没有建立家庭") }
                    try reminders.setSharing(id, sharing, detail: "改为" + HouseholdStore.shared.names.thirdPerson.summary(sharing),
                                             expectedRevision: revision)
                case .weatherLocation(let selection, let before):
                    try weather.setLocation(selection, expected: before)
                    Task { await weather.refresh(force: true) }
                case .settings(let changes):
                    try ButlerSettingsService.apply(changes, defaults: settingsDefaults, jev: jev as? JevClient)
                case .alarm, .appleReminder, .calendar, .taskDisplay, .health, .home, .contacts, .travel, .sync, .webPage, .folder: continue
                }
                results.append(change.result(.succeeded, "✓ \(change.title)"))
            } catch {
                results.append(change.result(.failed, "✗ \(change.title)：\(error.localizedDescription)"))
            }
        }
        pending.removeAll { selectedIDs.contains($0.id) }
        return results
    }

    /// Shared confirmation boundary for asynchronous system permissions and writes.
    func confirmIncludingSystemChanges(ids: Set<UUID>? = nil, progress: (([String]) throws -> Void)? = nil) async -> [String] {
        await confirmResults(ids: ids, progress: { values in
            try progress?(values.filter { $0.state != .notStarted && $0.state != .running }.map(\.message))
        }).map(\.message)
    }

    /// Each snapshot includes all selected identities in their original order.
    /// Persist running BEFORE calling a system: interrupted writes are then unknown, not failed.
    func confirmResults(ids: Set<UUID>? = nil, progress: (([ConfirmationResult]) throws -> Void)? = nil) async -> [ConfirmationResult] {
        let selected = pending.filter { ids == nil || ids!.contains($0.id) }
        guard selected.count <= 1 || !selected.contains(where: \.requiresSoleConfirmation) else {
            return selected.map { $0.result(.notStarted, "✗ 此操作须单独确认；本批没有执行，提案均已保留。") }
        }
        guard !Task.isCancelled else {
            selected.forEach { removePending($0.id) }
            return selected.map { $0.result(.notStarted, "✗ 已停止执行，没有开始本批修改；原确认已消费，重新执行须重新提议。") }
        }
        let systemChanges = selected.filter(\.requiresAsyncConfirmation)
        let localIDs = Set(selected.map(\.id)).subtracting(systemChanges.map(\.id))
        var results = selected.map { $0.result(.notStarted, "\($0.title)：未开始执行。") }
        for index in selected.indices where localIDs.contains(selected[index].id) {
            results[index] = selected[index].result(.running, "\(selected[index].title)：正在执行。")
        }
        do { try progress?(results) }
        catch {
            selected.forEach { removePending($0.id) }
            return selected.map { $0.result(.notStarted, "✗ 执行进度无法保存，未开始本批修改；请核查记录后重新提议。") }
        }
        for result in confirmLocalResults(ids: localIDs) {
            if let index = results.firstIndex(where: { $0.id == result.id }) { results[index] = result }
        }
        // Consume before any await so another confirmation cannot start the same proposal.
        systemChanges.forEach { removePending($0.id) }
        do { try progress?(results) }
        catch {
            for index in results.indices where results[index].state == .notStarted {
                results[index].message = "✗ 执行进度无法保存，未开始剩余系统操作；请核查之前的结果，不会自动重试。"
            }
            return results
        }
        for proposal in systemChanges {
            guard let index = results.firstIndex(where: { $0.id == proposal.id }) else { continue }
            if Task.isCancelled {
                results[index] = proposal.result(.notStarted, "\(proposal.title)：已停止，尚未开始此项。")
                continue
            }
            results[index] = proposal.result(.running, "\(proposal.title)：正在执行。")
            do { try progress?(results) }
            catch {
                results[index] = proposal.result(.notStarted, "✗ 执行进度无法保存，未开始此项或后续系统操作。")
                break
            }
            do {
                try Task.checkCancellation()
                let receipt: String
                // Older device adapters return prose, sometimes explicitly unverified.
                // A normal return alone is not a universal proof of external completion.
                var state: ConfirmationResult.State = .reported
                switch proposal.kind {
                case .alarm(let change):
                    try await alarms.apply(change, operationID: proposal.id)
                    receipt = "已核对系统状态（不代表已实际响铃）"
                case .appleReminder(let change):
                    receipt = try await appleReminders.apply(change, operationID: proposal.id)
                case .calendar(let change):
                    receipt = try await systemCalendar.apply(change, operationID: proposal.id)
                case .taskDisplay(let change):
                    defer { TaskDisplayService.reconcile() }
                    receipt = try await taskDisplays.apply(change, operationID: proposal.id,
                        tasks: { try TaskDisplayService.tasks(self.reminders) })
                case .health(let change):
                    let result = try await health.apply(change, operationID: proposal.id)
                    if let text = result.localText { onLocalHealthResult?(text) }
                    receipt = result.receipt
                case .home(let change):
                    receipt = try await home.apply(change, operationID: proposal.id, soleConfirmation: selected.count == 1)
                case .contacts(let change):
                    receipt = try await contacts.apply(change, operationID: proposal.id)
                case .travel(let change):
                    receipt = try await travel.apply(change, operationID: proposal.id)
                case .folder(let change):
                    switch change {
                    case .authorize:
                        folderSelectionRequest = proposal.id
                        state = .awaitingUser
                        receipt = "请点“选择文件夹”完成系统授权；当前尚未获得目录访问权。"
                    case .revoke(let id):
                        try folders.revoke(id)
                        receipt = "已撤销后续文件夹访问，原文件和聊天资料保留。"
                    case .export(let value):
                        receipt = try await folders.export(value, operationID: proposal.id)
                    }
                case .webPage(let address):
                    do { receipt = try await webPageReader.read(address) }
                    catch is CancellationError { throw CancellationError() }
                    catch let error as WebPageFailure { throw error }
                    catch { throw WebPageFailure("网页读取未完成，请检查网络后重新提议并确认；没有自动重试或修改库存。") }
                case .sync(let change):
                    switch change {
                    case .enabled(let enabled):
                        if enabled { try await syncStore().setEnabled(true) }
                        else {
                            let main = Result { try syncStore().pause() }
                            let chats = Result { try chatSynchronization?.pause() }
                            let photos = Result { try photoSynchronization?.pause() }
                            try main.get(); try chats.get(); try photos.get()
                        }
                        receipt = enabled ? "已开启库存文字、任务和笔记前台同步；聊天和图片分别另行开启，不代表本轮已完成。" : "已关闭普通资料、聊天和图片的后续同步，本机及云端资料保留；已发请求可能完成。"
                    case .chatEnabled(let enabled):
                        guard !enabled || synchronization?.enabled == true else { throw SyncFailure("请先确认开启普通资料同步，再单独开启聊天。") }
                        try await syncStore(kind: .chat).setEnabled(enabled)
                        receipt = enabled ? "已开启聊天文字同步，当前对话结束后前台尝试传输；不上传草稿、待确认操作、图片文件或健康查询结果，也不执行历史指令。" : "已关闭后续聊天同步；普通资料同步不受影响，本机和云端聊天保留，已发请求可能完成。"
                    case .photosEnabled(let enabled):
                        guard !enabled || synchronization?.enabled == true else { throw SyncFailure("请先开启普通资料同步，再单独开启图片。") }
                        try await syncStore(kind: .itemPhoto).setEnabled(enabled)
                        receipt = enabled ? "已开启Butler内已保存图片同步，当前对话结束后前台尝试；不扫描相册，不代表图片已全部收到。" : "已关闭后续图片同步，本机及云端已有图片保留，普通资料和聊天开关不变。"
                    case .cleanup(let kind, let plan):
                        if kind == .inventory {
                            let chats = Result { try chatSynchronization?.pause() }, photos = Result { try photoSynchronization?.pause() }
                            try chats.get(); try photos.get()
                        }
                        try await syncStore(kind: kind).clean(plan)
                        receipt = "所选云端区清理已完成，本机资料保留且该区暂停；其他区未清理。重新连接和上传本机资料须再次单独确认。"
                    case .reconnect(let kind, let account, let head):
                        guard kind == .inventory || synchronization?.enabled == true else { throw SyncFailure("请先重新连接普通资料，再连接聊天或图片。") }
                        if kind == .inventory {
                            let chats = Result { try chatSynchronization?.pause() }, photos = Result { try photoSynchronization?.pause() }
                            try chats.get(); try photos.get()
                        }
                        try await syncStore(kind: kind).reconnect(account: account, head: head)
                        receipt = "已允许所选范围重新连接并上传当前本机资料，等待前台同步；不代表已完成传输。"
                    case .resolve(let key, let heads, let selected):
                        try syncStore(kind: key.kind).resolve(key: key, expectedHeads: heads, selected: selected, applyLocally: key.kind != .chat && !key.kind.isPhoto)
                        receipt = key.kind == .chat || key.kind.isPhoto
                            ? "已记录所选版本，当前对话结束后核对新变化再采用；有新分支仍需选择，不代表本机或另一设备已经更新。"
                            : "已在本机采用所选版本，等待同步；原冲突版本保留，不代表另一设备已更新。"
                    }
                default: continue
                }
                results[index] = proposal.result(state, "\(proposal.title)；\(receipt)")
            } catch is CancellationError {
                results[index] = proposal.result(.needsVerification, "\(proposal.title)：执行中停止，可能已生效。请先核查；没有自动重试或撤销。")
            } catch {
                let state: ConfirmationResult.State
                if case .webPage = proposal.kind { state = .failed } else { state = .needsVerification }
                results[index] = proposal.result(state, "\(proposal.title)：\(error.localizedDescription)"
                    + (state == .needsVerification ? "\n结果待核实，不自动重试。" : ""))
            }
            do { try progress?(results) }
            catch {
                results[index].message += "\n执行进度无法保存，停止剩余操作；请核查之前的结果，不会自动重试。"
                break
            }
        }
        return results
    }

    // MARK: - Helpers

    struct ToolError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Set by `gate` when the model re-proposed despite Jev; consumed by the next `add`s of this call.
    var insistedConcern: String?

    func add(_ kind: PendingChange.Kind, title: String, detail: String?, check: JevCheck? = nil) {
        let change = PendingChange(kind: kind, title: title, detail: detail,
            check: insistedConcern.map { .concern($0) } ?? check, requestTurnID: requestTurnID)
        if let scope = change.relatedScope { relatedScopes.insert(scope) }
        pending.append(change)
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
