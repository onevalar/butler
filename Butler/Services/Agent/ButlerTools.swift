import Foundation
import Observation
import SwiftData

/// A change the assistant proposed. Nothing is written until the owner taps confirm.
struct PendingChange: Identifiable {
    enum Kind {
        case add(InventoryActions.NewItem)
        case setQuantity(LotFacts, Int)
        case close(LotFacts, InventoryLotState)
        case setDate(LotFacts, LotDateKind, Date?)
        case move(LotFacts, String)
        case note(LocalMemory)
    }

    let id = UUID()
    let kind: Kind
    /// One line the owner reads on the card, e.g. "新增 牛奶 ×2 瓶".
    let title: String
    let detail: String?
}

/// The assistant's hands: reads and proposes changes to the owner's real inventory and notes.
@MainActor @Observable
final class ButlerTools {
    let container: ModelContainer
    let notes: LocalMemoryStore
    let jev: JevClient
    private(set) var pending: [PendingChange] = []

    init(container: ModelContainer, notes: LocalMemoryStore, jev: JevClient) {
        self.container = container
        self.notes = notes
        self.jev = jev
    }

    nonisolated deinit {}

    func clearPending() { pending = [] }

    func removePending(_ id: UUID) { pending.removeAll { $0.id == id } }

    // MARK: - Tool definitions

    var toolJSON: String {
        var tools = Self.inventoryTools
        if jev.isConfigured { tools += "," + Self.jevTool }
        return "[" + tools + "]"
    }

    static let inventoryTools = #"""
    {"type":"function","name":"search_inventory","description":"查询家里现有物品（真实库存）。query为空字符串时返回全部；按名称、品牌或存放位置的关键词匹配。include_finished=true 时额外返回最近30天已用完/丢掉/送人的记录。返回每件的 lot_id、数量、单位、位置、三种日期和剩余天数。","strict":true,"parameters":{"type":"object","properties":{"query":{"type":"string"},"include_finished":{"type":"boolean"}},"required":["query","include_finished"],"additionalProperties":false}},
    {"type":"function","name":"propose_add_items","description":"提出新增购买的物品，等用户确认后才入库。每件一条。package_expiry 只能填用户明确说出或包装上的日期(YYYY-MM-DD)，否则 null；planned_use_by 是用户想在哪天前吃完/用完的计划，没说就 null。storage 如 冷藏/冷冻/常温/零食柜/药箱，没说就 null。","strict":true,"parameters":{"type":"object","properties":{"items":{"type":"array","minItems":1,"maxItems":20,"items":{"type":"object","properties":{"name":{"type":"string"},"quantity":{"type":"integer","minimum":1,"maximum":999},"unit":{"type":"string"},"storage":{"type":["string","null"]},"package_expiry":{"type":["string","null"]},"planned_use_by":{"type":["string","null"]}},"required":["name","quantity","unit","storage","package_expiry","planned_use_by"],"additionalProperties":false}}},"required":["items"],"additionalProperties":false}},
    {"type":"function","name":"propose_set_quantity","description":"把某件物品的剩余数量设置为指定值（不是扣减）。设为0等于用完。lot_id 必须来自 search_inventory。","strict":true,"parameters":{"type":"object","properties":{"lot_id":{"type":"string"},"quantity":{"type":"integer","minimum":0,"maximum":999}},"required":["lot_id","quantity"],"additionalProperties":false}},
    {"type":"function","name":"propose_close","description":"把某件物品标记为处理掉：used_up 用完/吃完，discarded 丢掉，gifted 送人。","strict":true,"parameters":{"type":"object","properties":{"lot_id":{"type":"string"},"reason":{"type":"string","enum":["used_up","discarded","gifted"]}},"required":["lot_id","reason"],"additionalProperties":false}},
    {"type":"function","name":"propose_set_date","description":"设置或清除某件物品的日期。kind=package_expiry 包装有效期（只能用用户明确给出的日期），kind=planned_use_by 计划吃完/用完的日期。date 为 YYYY-MM-DD，null 表示清除。","strict":true,"parameters":{"type":"object","properties":{"lot_id":{"type":"string"},"kind":{"type":"string","enum":["package_expiry","planned_use_by"]},"date":{"type":["string","null"]}},"required":["lot_id","kind","date"],"additionalProperties":false}},
    {"type":"function","name":"propose_move","description":"更改某件物品的存放位置。","strict":true,"parameters":{"type":"object","properties":{"lot_id":{"type":"string"},"location":{"type":"string"}},"required":["lot_id","location"],"additionalProperties":false}},
    {"type":"function","name":"search_notes","description":"查询用户告诉过你的习惯、偏好和其他需要记住的事（例如常去哪家店买、放在哪里、家里的布局）。query 为空返回全部。","strict":true,"parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}},
    {"type":"function","name":"propose_note","description":"新增或更正一条需要长期记住的事（习惯、偏好、布局、提醒自己的话）。id=null 新建；更正时传原 id，保留没被纠正的内容。库存物品本身不要写成笔记。","strict":true,"parameters":{"type":"object","properties":{"id":{"type":["string","null"]},"title":{"type":"string"},"text":{"type":"string"}},"required":["id","title","text"],"additionalProperties":false}}
    """#

    static let jevTool = #"""
    {"type":"function","name":"judge_with_jev","description":"请 Jev 条件判断模型对候选逐个判断一个是/否问题，返回每个候选为“是”的概率(0-1)。适合：用户说的是哪件物品、是纠正还是新增、两条记录是否同一样东西。结果是参考，不是授权；失败时自己判断并继续。","strict":true,"parameters":{"type":"object","properties":{"request":{"type":"string"},"question":{"type":"string"},"candidates":{"type":"array","minItems":1,"maxItems":8,"items":{"type":"object","properties":{"id":{"type":"string"},"text":{"type":"string"}},"required":["id","text"],"additionalProperties":false}}},"required":["request","question","candidates"],"additionalProperties":false}}
    """#

    // MARK: - Execution

    func execute(_ call: LocalToolCall) async -> String {
        do {
            let data = Data(call.arguments.utf8)
            switch call.name {
            case "search_inventory":
                struct Args: Decodable { var query: String; var include_finished: Bool }
                let args = try JSONDecoder().decode(Args.self, from: data)
                return try encode(searchInventory(args.query, includeFinished: args.include_finished))
            case "propose_add_items":
                struct Item: Decodable {
                    var name: String; var quantity: Int; var unit: String
                    var storage: String?; var package_expiry: String?; var planned_use_by: String?
                }
                struct Args: Decodable { var items: [Item] }
                let args = try JSONDecoder().decode(Args.self, from: data)
                for item in args.items {
                    try proposeAdd(name: item.name, quantity: item.quantity, unit: item.unit, storage: item.storage,
                                   packageExpiry: try Self.date(item.package_expiry),
                                   plannedUseBy: try Self.date(item.planned_use_by))
                }
            case "propose_set_quantity":
                struct Args: Decodable { var lot_id: String; var quantity: Int }
                let args = try JSONDecoder().decode(Args.self, from: data)
                let lot = try activeLot(args.lot_id)
                guard (0...999).contains(args.quantity) else { throw ToolError("数量需要在 0 到 999 之间") }
                if args.quantity == 0 {
                    add(.close(lot, .depleted), title: "\(lot.name) 用完了", detail: "原有 \(lot.quantity) \(lot.unit)")
                } else {
                    add(.setQuantity(lot, args.quantity), title: "\(lot.name) 剩 \(args.quantity) \(lot.unit)",
                        detail: "原来 \(lot.quantity) \(lot.unit)")
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
                add(.close(lot, state), title: "\(lot.name) \(verb)", detail: "\(lot.quantity) \(lot.unit)")
            case "propose_set_date":
                struct Args: Decodable { var lot_id: String; var kind: String; var date: String? }
                let args = try JSONDecoder().decode(Args.self, from: data)
                let lot = try activeLot(args.lot_id)
                let kind: LotDateKind = args.kind == "package_expiry" ? .packageExpiry : .plannedUseBy
                let date = try Self.date(args.date)
                let label = kind == .packageExpiry ? "包装有效期" : "计划吃完"
                add(.setDate(lot, kind, date), title: "\(lot.name) \(label)",
                    detail: date.map { "改为 \($0.monthDay)" } ?? "清除这个日期")
            case "propose_move":
                struct Args: Decodable { var lot_id: String; var location: String }
                let args = try JSONDecoder().decode(Args.self, from: data)
                let lot = try activeLot(args.lot_id)
                let location = args.location.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !location.isEmpty, location.count <= 40 else { throw ToolError("位置不能为空") }
                add(.move(lot, location), title: "\(lot.name) 放到 \(location)",
                    detail: lot.storageLocation.map { "原来在 \($0)" })
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
                struct Args: Decodable { var request: String; var question: String; var candidates: [JevClient.Candidate] }
                let args = try JSONDecoder().decode(Args.self, from: data)
                let judgments = try await jev.judge(request: args.request, question: args.question, candidates: args.candidates)
                return try encode(["source": "jev", "judgments": judgments.map { ["id": $0.id, "probability": $0.probability] as [String: Any] }]
                                  as [String: Any])
            default:
                return #"{"error":"unknown_tool"}"#
            }
            return "{\"status\":\"waiting_for_user_confirmation\",\"pending_changes\":\(pending.count),\"saved\":false}"
        } catch let error as ToolError {
            return (try? encode(["error": error.message, "saved": false] as [String: Any])) ?? #"{"error":"invalid"}"#
        } catch let error as JevClient.JevError {
            return (try? encode(["error": "jev_failed", "detail": error.localizedDescription,
                                 "hint": "自己判断并继续"] as [String: Any])) ?? #"{"error":"jev_failed"}"#
        } catch {
            return #"{"error":"invalid_arguments","saved":false}"#
        }
    }

    /// Applies every pending change in order. Returns one line per change for the chat and the model.
    func confirmAll() -> [String] {
        let actions = InventoryActions(modelContainer: container)
        var results: [String] = []
        let adds = pending.compactMap { change -> (PendingChange, InventoryActions.NewItem)? in
            if case .add(let item) = change.kind { return (change, item) }
            return nil
        }
        if !adds.isEmpty {
            do {
                try actions.add(adds.map(\.1), sourceText: "对话中确认")
                results += adds.map { "✓ \($0.0.title)" }
            } catch {
                results += adds.map { "✗ \($0.0.title)：\(error.localizedDescription)" }
            }
        }
        for change in pending {
            do {
                switch change.kind {
                case .add: continue
                case .setQuantity(let lot, let quantity): try actions.adjustQuantity(try fresh(lot), to: quantity)
                case .close(let lot, let state): try actions.close(try fresh(lot), as: state)
                case .setDate(let lot, let kind, let date): try actions.setDate(date, kind: kind, for: try fresh(lot))
                case .move(let lot, let location): try actions.move(try fresh(lot), to: location)
                case .note(let memory): try notes.upsert(memory)
                }
                results.append("✓ \(change.title)")
            } catch {
                results.append("✗ \(change.title)：\(error.localizedDescription)")
            }
        }
        pending = []
        return results
    }

    // MARK: - Helpers

    private struct ToolError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func add(_ kind: PendingChange.Kind, title: String, detail: String?) {
        pending.append(PendingChange(kind: kind, title: title, detail: detail))
    }

    private func proposeAdd(name: String, quantity: Int, unit: String, storage: String?,
                            packageExpiry: Date?, plannedUseBy: Date?) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, (1...999).contains(quantity) else { throw ToolError("名称或数量不合理") }
        let candidates = try CatalogProductLookup(modelContainer: container).exactMatches(for: name)
        let linked = candidates.count == 1 ? candidates.first?.id : nil
        let item = InventoryActions.NewItem(name: name, quantity: quantity, unit: unit.isEmpty ? "份" : unit,
                                            storage: storage?.isEmpty == true ? nil : storage,
                                            packageExpiry: packageExpiry, plannedUseBy: plannedUseBy,
                                            existingProductID: linked)
        var parts: [String] = []
        if let storage = item.storage { parts.append(storage) }
        if let date = packageExpiry { parts.append("包装有效期 \(date.monthDay)") }
        if let date = plannedUseBy { parts.append("\(date.monthDay)前吃完") }
        if linked != nil { parts.append("家里已有同款") }
        add(.add(item), title: "新增 \(name) ×\(quantity) \(item.unit)", detail: parts.isEmpty ? nil : parts.joined(separator: " · "))
    }

    private func allLots() throws -> [(InventoryLot, CatalogProduct?)] {
        let context = ModelContext(container)
        let products = Dictionary(try context.fetch(FetchDescriptor<CatalogProduct>()).map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        return try context.fetch(FetchDescriptor<InventoryLot>()).map { ($0, products[$0.productID]) }
    }

    private func activeLot(_ raw: String) throws -> LotFacts {
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

    private func searchInventory(_ query: String, includeFinished: Bool) throws -> [String: Any] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lots = try allLots()
        // "牛奶 鸡蛋" or "牛奶、鸡蛋" matches either word.
        let words = query.split(whereSeparator: { " ,，、;；".contains($0) }).map(String.init)
        func matches(_ lot: InventoryLot, _ product: CatalogProduct?) -> Bool {
            guard !words.isEmpty else { return true }
            let haystack = [product?.canonicalName, product?.brand, lot.storageLocation].compactMap { $0 }.joined(separator: " ")
            return words.contains { word in
                haystack.localizedStandardContains(word)
                    || (product?.canonicalName).map { !$0.isEmpty && word.localizedStandardContains($0) } == true
            }
        }
        let active = lots.filter { $0.0.state == .active && matches($0.0, $0.1) }
            .map { LotFacts(lot: $0.0, product: $0.1) }
            .sorted { ($0.daysLeft ?? .max) < ($1.daysLeft ?? .max) }
        var result: [String: Any] = [
            "today": Date.now.isoDay,
            "count": active.count,
            "items": active.prefix(80).map(Self.describe),
        ]
        if includeFinished {
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
            result["finished"] = lots.filter { $0.0.state != .active && $0.0.updatedAt >= cutoff && matches($0.0, $0.1) }
                .sorted { $0.0.updatedAt > $1.0.updatedAt }.prefix(30)
                .map { lot, product in
                    ["lot_id": lot.id.uuidString, "name": product?.canonicalName ?? "未命名",
                     "state": lot.state.rawValue, "when": lot.updatedAt.isoDay] as [String: Any]
                }
        }
        return result
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
        item["bought"] = lot.startedAt.isoDay
        return item
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

    private func encode(_ value: Any) throws -> String {
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
