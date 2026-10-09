import Foundation
import SwiftData

struct ItemProfileInput: Decodable {
    struct Field: Decodable { let name: String; let value: String }
    let category: ItemCategory
    let attributes: [Field]
    let tags: [String]
    let availability: String
    let photo_index: Int?
    let remove_photo: Bool

    func profile(photos: [Data], previous: ItemProfile? = nil) throws -> ItemProfile {
        guard Set(attributes.map(\.name)).count == attributes.count else { throw ButlerTools.ToolError("属性名称不能重复") }
        var photo = remove_photo ? nil : previous?.photo
        if let index = photo_index {
            guard photos.indices.contains(index) else { throw ButlerTools.ToolError("照片索引无效，仅可使用本轮附件") }
            photo = photos[index]
        }
        let result = ItemProfile(category: category, attributes: Dictionary(uniqueKeysWithValues: attributes.map { ($0.name, $0.value) }),
                                 tags: tags, availability: availability, photo: photo)
        try result.validate()
        return result
    }
}

struct ItemCollection: Codable, Equatable, Identifiable {
    var id = UUID()
    let title: String
    var items: [Entry]
    struct Entry: Codable, Equatable, Identifiable { let id: UUID; let name: String; let reason: String }
}

extension ButlerTools {
    static var profileSchema: [String: Any] {
        let string: [String: Any] = ["type": "string"]
        let field = objectSchema(["name": string, "value": string])
        return objectSchema([
            "category": ["type": "string", "enum": ItemCategory.allCases.map(\.rawValue)],
            "attributes": ["type": "array", "maxItems": 16, "items": field],
            "tags": ["type": "array", "maxItems": 20, "items": string],
            "availability": ["type": "string", "enum": ["ready", "laundry", "lent", "repair"]],
            "photo_index": ["type": ["integer", "null"], "minimum": 0, "maximum": 3],
            "remove_photo": ["type": "boolean"]
        ])
    }
    static func objectSchema(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
    }
    static func functionSchema(_ name: String, _ description: String, _ properties: [String: Any]) -> [String: Any] {
        ["type": "function", "name": name, "description": description, "strict": true, "parameters": objectSchema(properties)]
    }
    static var inventoryTools: String {
        var tools = (try? JSONSerialization.jsonObject(with: Data(("[" + legacyInventoryTools + "]").utf8)) as? [[String: Any]]) ?? []
        if let index = tools.firstIndex(where: { $0["name"] as? String == "propose_add_items" }),
           var parameters = tools[index]["parameters"] as? [String: Any], var properties = parameters["properties"] as? [String: Any],
           var items = properties["items"] as? [String: Any], var item = items["items"] as? [String: Any],
           var fields = item["properties"] as? [String: Any] {
            fields["profile"] = ["anyOf": [profileSchema, ["type": "null"]]]
            item["properties"] = fields; item["required"] = fields.keys.sorted()
            items["items"] = item; properties["items"] = items; parameters["properties"] = properties; tools[index]["parameters"] = parameters
            tools[index]["description"] = (tools[index]["description"] as? String ?? "") + " profile可为null；衣服、工具、数码等请填写category和已知属性（颜色、尺码、材质、季节、用途等），未知不猜。photo_index仅引用本轮附件，从0起；多人多件合照需用户明确选择。耐用品track用quantity。"
        }
        return ToolSchema.json(tools, sortedKeys: true)
    }
    static var itemTools: String {
        let string: [String: Any] = ["type": "string"]
        let revision: [String: Any] = ["type": "integer", "minimum": 0]
        let tools = [
            functionSchema("propose_item_profile", "修改物品分类、属性、用途标签、可用状态或照片。先查询真实lot_id和revision；profile是完整替换，必须保留未要求改变的资料。photo_index=null且remove_photo=false保留原照片。确认后保存。", ["lot_id": string, "expected_revision": revision, "profile": profileSchema]),
            functionSchema("get_inventory_history", "查询某件物品的变动记录及当前版本，undoable标明能否撤销最近一次数量/处理操作；不会删除历史。", ["lot_id": string]),
            functionSchema("propose_undo_inventory", "纠正误操作：撤销最近一次数量或处理操作。必须先get_inventory_history，只能用undoable=true的operation_id和当前revision。确认后执行。", ["lot_id": string, "operation_id": string, "expected_revision": revision]),
            functionSchema("show_inventory", "把查询得到的真实物品显示为可点击的图形清单或对比/搭配卡片，不修改库存。场景类问题（修自行车、野餐要带什么、我有什么衣服）先查库存，再用本工具把相关物品列出来，可以跨分类、位置和到期状态。title写清是什么清单（不带数量），reason一句话说为什么用得上，没有可写空字符串。不可把尚未购买的东西列成家里已有。", ["title": string, "items": ["type": "array", "minItems": 1, "maxItems": 30, "items": objectSchema(["lot_id": string, "reason": string])]]),
            functionSchema("update_shown_list", "修改对话里最近显示的那张清单（current_context 的 shown_list）：remove 去掉某几行（只是不列在清单里，东西仍在家里，不改库存），add 追加真实物品。用户说“去掉某样/不用带某样/再加上某样”时用它，不要重新 show_inventory 出一张新清单。", ["remove": ["type": "array", "maxItems": 30, "items": string], "add": ["type": "array", "maxItems": 30, "items": objectSchema(["lot_id": string, "reason": string])]]),
            functionSchema("propose_item_sharing", "家庭里谁能看到某样东西（仅当 current_context 有 household 时）。scope=household 全家可见，personal 只有当前用户自己；hidden_from 填家人称呼，表示全家可见但不让这些人看到（例如送给他的礼物），不需要则空数组。先自己判断：个人的药、护肤品、礼物通常只给自己，家里共用的东西全家可见；用户说“这个只给我看/别让老婆看到”时用它。确认后生效。", ["lot_id": string, "scope": ["type": "string", "enum": ["household", "personal"]], "hidden_from": ["type": "array", "maxItems": 10, "items": string]]),
            functionSchema("propose_regroup", "一次调整多件物品的存放位置和/或分类，例如“把酸奶和饮用水放到卫生间架子”“这几样归到工具”。location为新位置（不改则null），category为新分类（不改则null）；每件生成一条待确认修改，用户确认后才保存。", ["lot_ids": ["type": "array", "minItems": 1, "maxItems": 30, "items": string], "location": ["type": ["string", "null"]], "category": ["type": ["string", "null"], "enum": ItemCategory.allCases.map { $0.rawValue as Any } + [NSNull()]]])
        ]
        return ToolSchema.json(tools, sortedKeys: true)
    }

    func executeItemTool(_ name: String, data: Data) throws -> String? {
        switch name {
        case "propose_item_profile":
            struct Args: Decodable { let lot_id: UUID; let expected_revision: Int; let profile: ItemProfileInput }
            let args = try JSONDecoder().decode(Args.self, from: data)
            let lot = try activeLot(args.lot_id.uuidString)
            guard lot.revision == args.expected_revision else { throw ToolError("物品已改变，请重新读取") }
            let profile = try args.profile.profile(photos: inputPhotos, previous: lot.profile)
            add(.itemProfile(lot, profile), title: "更新资料：\(lot.name)", detail: profile.searchText + (profile.photo != nil ? " · 含照片" : ""))
        case "get_inventory_history":
            struct Args: Decodable { let lot_id: UUID }
            let id = try JSONDecoder().decode(Args.self, from: data).lot_id
            let lot = try lotFacts(id)
            let context = ModelContext(container)
            let events = try context.fetch(FetchDescriptor<InventoryEvent>(predicate: #Predicate { $0.subjectID == id }, sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]))
            relatedScopes.insert(.lot(id))
            return try encode(["lot_id": id.uuidString, "revision": lot.revision, "total": events.count, "truncated": events.count > 100, "events": events.prefix(100).map {
                ["operation_id": $0.operationID.uuidString, "kind": $0.eventTypeRawValue, "date": $0.occurredAt.ISO8601Format(),
                 "undoable": $0.undoQuantity(currentQuantity: lot.quantity, revision: lot.revision) != nil] as [String: Any]
            }] as [String: Any])
        case "propose_undo_inventory":
            struct Args: Decodable { let lot_id: UUID; let operation_id: UUID; let expected_revision: Int }
            let args = try JSONDecoder().decode(Args.self, from: data)
            let lot = try lotFacts(args.lot_id)
            let event = try inventoryEvent(args.operation_id)
            guard lot.revision == args.expected_revision, event.subjectID == lot.id,
                  event.undoQuantity(currentQuantity: lot.quantity, revision: lot.revision) != nil else { throw ToolError("这条记录已不能撤销，请重新查询") }
            add(.undoInventory(lot, args.operation_id), title: "纠正最近处理：\(lot.name)", detail: "恢复之前数量和在库状态，保留变动记录")
        case "show_inventory":
            struct Args: Decodable { struct Entry: Decodable { let lot_id: UUID; let reason: String }; let title: String; let items: [Entry] }
            let args = try JSONDecoder().decode(Args.self, from: data)
            guard (1...30).contains(args.items.count), args.title.count <= 80, Set(args.items.map(\.lot_id)).count == args.items.count else { throw ToolError("清单需要1到30件不同物品") }
            let entries = try args.items.map { item -> ItemCollection.Entry in
                guard item.reason.count <= 600 else { throw ToolError("说明过长") }
                let lot = try activeLot(item.lot_id.uuidString)
                return .init(id: lot.id, name: lot.name, reason: item.reason)
            }
            displayedCollection = ItemCollection(id: displayedCollection?.id ?? UUID(), title: args.title, items: entries)
            relatedScopes.formUnion(entries.map { .lot($0.id) })
            return try encode(["displayed": true, "count": entries.count] as [String: Any])
        case "update_shown_list":
            struct Args: Decodable { struct Entry: Decodable { let lot_id: UUID; let reason: String }; let remove: [UUID]; let add: [Entry] }
            let args = try JSONDecoder().decode(Args.self, from: data)
            guard var list = displayedCollection ?? shownListEdit ?? shownList?() else { throw ToolError("对话里还没有显示过清单，请用 show_inventory") }
            let known = Set(list.items.map(\.id))
            guard Set(args.remove).isSubset(of: known) else { throw ToolError("要去掉的物品不在这张清单里，请按 shown_list 的 lot_id") }
            list.items.removeAll { args.remove.contains($0.id) }
            for item in args.add where !list.items.contains(where: { $0.id == item.lot_id }) {
                guard item.reason.count <= 600 else { throw ToolError("说明过长") }
                let lot = try activeLot(item.lot_id.uuidString)
                list.items.append(.init(id: lot.id, name: lot.name, reason: item.reason))
            }
            guard list.items.count <= 30 else { throw ToolError("清单最多30件") }
            if displayedCollection?.id == list.id { displayedCollection = list }
            else { shownListEdit = list }
            relatedScopes.formUnion(list.items.map { .lot($0.id) })
            return try encode(["updated": true, "count": list.items.count, "items": list.items.map(\.name)] as [String: Any])
        case "propose_item_sharing":
            struct Args: Decodable { let lot_id: String; let scope: String; let hidden_from: [String] }
            let args = try JSONDecoder().decode(Args.self, from: data)
            let household = HouseholdStore.shared
            guard household.state != nil else { throw ToolError("还没有建立家庭，东西都只在这台手机上") }
            let lot = try activeLot(args.lot_id)
            let scope: ItemSharing.Scope = args.scope == "personal" ? .personal : .household
            var hidden: [UUID] = []
            for name in args.hidden_from where scope == .household {
                guard let member = household.members.first(where: { $0.name == name })
                        ?? household.members.first(where: { $0.name.contains(name) || name.contains($0.name) }) else {
                    throw ToolError("家里没有“\(name)”。家人：" + household.members.map(\.name).joined(separator: "、"))
                }
                guard member.id != household.state?.me else { throw ToolError("不能对自己隐藏") }
                hidden.append(member.id)
            }
            let names = hidden.compactMap { household.member($0)?.name }
            let detail = scope == .personal ? "只有你能看到，家人那边不再显示" : (names.isEmpty ? "全家都能看到" : "全家能看到，但不让\(names.joined(separator: "、"))看到")
            add(.itemSharing(lot, scope, hiddenFrom: hidden), title: "\(lot.name)：\(scope == .personal ? "只给自己" : "家里共享")", detail: detail)
        case "propose_regroup":
            struct Args: Decodable { let lot_ids: [String]; let location: String?; let category: ItemCategory? }
            let args = try JSONDecoder().decode(Args.self, from: data)
            let location = args.location?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...30).contains(args.lot_ids.count), Set(args.lot_ids).count == args.lot_ids.count else { throw ToolError("需要1到30件不同物品") }
            guard location != nil || args.category != nil else { throw ToolError("location和category至少改一项") }
            if let location { guard !location.isEmpty, location.count <= 40 else { throw ToolError("位置不能为空，最多40字") } }
            let lots = try args.lot_ids.map { try activeLot($0) }
            var count = 0
            for lot in lots {
                if let location, lot.storageLocation != location {
                    add(.move(lot, location), title: "\(lot.name) 放到 \(location)", detail: lot.storageLocation.map { "原来在 \($0)" })
                    count += 1
                }
                if let category = args.category, lot.category != category {
                    var profile = lot.profile ?? ItemProfile(category: lot.category)
                    profile.category = category
                    add(.itemProfile(lot, profile), title: "\(lot.name) 归到 \(category.title)", detail: "原来是 \(lot.category.title)")
                    count += 1
                }
            }
            guard count > 0 else { throw ToolError("这些物品已经是这个位置和分类了") }
        default: return nil
        }
        return pendingContext
    }

    func lotFacts(_ id: UUID) throws -> LotFacts {
        guard let pair = try allLots().first(where: { $0.0.id == id }) else { throw ToolError("找不到这件物品") }
        return LotFacts(lot: pair.0, product: pair.1)
    }
    func inventoryEvent(_ id: UUID) throws -> InventoryEvent {
        let context = ModelContext(container)
        guard let event = try context.fetch(FetchDescriptor<InventoryEvent>(predicate: #Predicate { $0.operationID == id })).first else { throw ToolError("找不到变动记录") }
        return event
    }
}
