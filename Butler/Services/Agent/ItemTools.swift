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
    let items: [Entry]
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
        return tools.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }.joined(separator: ",")
    }
    static var itemTools: String {
        let string: [String: Any] = ["type": "string"]
        let revision: [String: Any] = ["type": "integer", "minimum": 0]
        let tools = [
            functionSchema("propose_item_profile", "修改物品分类、属性、用途标签、可用状态或照片。先查询真实lot_id和revision；profile是完整替换，必须保留未要求改变的资料。photo_index=null且remove_photo=false保留原照片。确认后保存。", ["lot_id": string, "expected_revision": revision, "profile": profileSchema]),
            functionSchema("get_inventory_history", "查询某件物品的变动记录及当前版本，undoable标明能否撤销最近一次数量/处理操作；不会删除历史。", ["lot_id": string]),
            functionSchema("propose_undo_inventory", "纠正误操作：撤销最近一次数量或处理操作。必须先get_inventory_history，只能用undoable=true的operation_id和当前revision。确认后执行。", ["lot_id": string, "operation_id": string, "expected_revision": revision]),
            functionSchema("show_inventory", "把查询得到的真实物品显示为可点击的图形清单或对比/搭配卡片，不修改库存。先查库存，建议说明理由及缺失资料；不可把尚未购买的东西列成家里已有。", ["title": string, "items": ["type": "array", "minItems": 1, "maxItems": 30, "items": objectSchema(["lot_id": string, "reason": string])]])
        ]
        return tools.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }.joined(separator: ",")
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
                relatedScopes.insert(.lot(lot.id))
                return .init(id: lot.id, name: lot.name, reason: item.reason)
            }
            displayedCollection = ItemCollection(title: args.title, items: entries)
            return try encode(["displayed": true, "count": entries.count] as [String: Any])
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
