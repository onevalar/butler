import CryptoKit
import Foundation

/// A fingerprint checks the entire proposal, including changes made directly on its card.
/// It is derived, so old persisted proposals require no migration or invented revision.
extension PendingChange {
    var editFingerprint: String {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            // Photos can be several MB. Hash bytes directly instead of constructing
            // and parsing their Base64 representation on every proposal read.
            encoder.dataEncodingStrategy = .custom { data, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            }
            let encoded = try encoder.encode(self)
            let object = try JSONSerialization.jsonObject(with: encoded)
            // Codable sets have no order. Canonicalize only the known set-valued fields;
            // ordered phases, activity and other arrays retain their meaning.
            func canonical(_ value: Any) -> Any {
                if let object = value as? [String: Any] {
                    var result = object.mapValues { canonical($0) }
                    for key in ["people", "hiddenFrom", "notify"] {
                        if let values = object[key] as? [String] { result[key] = values.sorted() }
                    }
                    return result
                }
                if let array = value as? [Any] { return array.map { canonical($0) } }
                return value
            }
            let data = try JSONSerialization.data(withJSONObject: canonical(object), options: [.sortedKeys])
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}

struct PendingItemPatch: Decodable {
    struct Storage: Decodable {
        let value: String?
        private enum CodingKeys: String, CodingKey { case value }
        init(from decoder: Decoder) throws {
            try TaskPatchFields.validate(decoder, allowed: ["value"], required: ["value"])
            value = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .value)
        }
    }

    let name: String?
    let quantity: Int?
    let unit: String?
    let storage: Storage?
    private enum CodingKeys: String, CodingKey { case name, quantity, unit, storage }

    init(from decoder: Decoder) throws {
        try TaskPatchFields.validate(decoder, allowed: ["name", "quantity", "unit", "storage"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        quantity = try container.decodeIfPresent(Int.self, forKey: .quantity)
        unit = try container.decodeIfPresent(String.self, forKey: .unit)
        storage = try container.decodeIfPresent(Storage.self, forKey: .storage)
    }

    static var schema: [String: Any] {
        TaskPatchFields.object([
            "name": ["type": ["string", "null"], "minLength": 1, "maxLength": 40],
            "quantity": ["type": ["integer", "null"], "minimum": 0, "maximum": 999],
            "unit": ["type": ["string", "null"], "minLength": 1, "maxLength": 20],
            "storage": TaskPatchFields.nullable(TaskPatchFields.object([
                "value": ["type": ["string", "null"], "maxLength": 100]
            ]))
        ])
    }

    func applying(to original: InventoryActions.NewItem) throws -> InventoryActions.NewItem {
        var result = original
        if let name { result.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let quantity { result.quantity = quantity }
        if let unit { result.unit = unit.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let storage {
            let value = storage.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            result.storage = value?.isEmpty == true ? nil : value
        }
        guard !result.name.isEmpty, result.name.count <= 40, (1...999).contains(result.quantity),
              !result.unit.isEmpty, result.unit.count <= 20, (result.storage?.count ?? 0) <= 100 else {
            throw ButlerTools.ToolError("物品名称、数量、单位或位置无效；没有修改提案")
        }
        guard result != original else { throw ButlerTools.ToolError("和现在一样，不需要修改") }
        return result
    }
}

extension ButlerTools {
    static var pendingRevisionToolJSON: String {
        let schema: [String: Any] = [
            "type": "function", "name": "revise_pending_change", "strict": true,
            "description": "原位局部修改待确认事项，不执行保存、不新建第二张卡。先 get_pending_changes，使用对应 id/fingerprint 作为 proposal_id/expected_fingerprint。task_patch和item_patch仅填一个，另一个null；各字段null表示保留。任务支持text、单次schedule、family局部设置；日期/时段保留模糊精度，重复/分段任务只可改文字或家人。family.assignee={value:null}清除负责人、数组[]清空，其他未指定字段保留。新增库存支持name/quantity(1–999)/unit/storage；storage={value:null}清空位置。现有库存的数量/用完提案仅可修改quantity(0–999)，0表示用完，不改变物品对象。不支持的字段不要猜测。校验或审查未通过时旧提案完整保留。真实已保存的任务请用propose_task_update。",
            "parameters": TaskPatchFields.object([
                "proposal_id": ["type": "string"], "expected_fingerprint": ["type": "string"],
                "task_patch": TaskPatchFields.nullable(TaskPatchFields.object(TaskUpdatePatch.fields)),
                "item_patch": TaskPatchFields.nullable(PendingItemPatch.schema)
            ])
        ]
        let data = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    func pendingDescription(_ change: PendingChange, number: Int) throws -> [String: Any] {
        var description: [String: Any] = [
            "id": change.id.uuidString, "number": number, "title": change.title, "detail": change.detail ?? "",
            "fingerprint": try change.editFingerprint, "editable_fields": [] as [String]
        ]
        switch change.kind {
        case .reminder(let task), .taskPlan(let task, _):
            description["kind"] = "task"
            description["editable_fields"] = ["text"] + (task.allowsSimpleTimeEdit ? ["schedule"] : [])
                + (household.state == nil ? [] : ["family"])
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(identifier: task.timeZoneIdentifier)
            formatter.dateFormat = task.timePeriod == nil ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
            var values: [String: Any] = ["task_id": task.id.uuidString, "text": task.text,
                "status": task.status.rawValue, "schedule": ["time": formatter.string(from: task.fireDate),
                    "period": task.timePeriod?.rawValue as Any? ?? NSNull(), "time_zone": task.timeZoneIdentifier,
                    "repeat": task.repeats.rawValue, "simple_edit_supported": task.allowsSimpleTimeEdit] as [String: Any]]
            if let family = task.sharing {
                values["family"] = ["visibility": family.scope.rawValue,
                    "people": family.people.map(\.uuidString).sorted(), "hidden_from": family.hiddenFrom.map(\.uuidString).sorted(),
                    "assignee": family.assignee?.uuidString as Any? ?? NSNull(), "notify": family.notify.map(\.uuidString).sorted(),
                    "escalation": ["person": family.escalateTo?.uuidString as Any? ?? NSNull(),
                        "after_minutes": family.escalateAfter as Any? ?? NSNull()] as [String: Any]] as [String: Any]
            } else { values["family"] = NSNull() }
            description["values"] = values
        case .add(let item):
            description["kind"] = "new_inventory_item"
            description["editable_fields"] = ["name", "quantity", "unit", "storage"]
            description["values"] = ["name": item.name, "quantity": item.quantity, "unit": item.unit,
                "storage": item.storage as Any? ?? NSNull(), "track": item.quantityOnly ? "quantity" : "expiry",
                "package_expiry": item.packageExpiry?.isoDay as Any? ?? NSNull(),
                "planned_use_by": item.plannedUseBy?.isoDay as Any? ?? NSNull()] as [String: Any]
        case .setQuantity(let lot, let quantity):
            description["kind"] = "inventory_quantity"
            description["editable_fields"] = ["quantity"]
            description["values"] = ["lot_id": lot.id.uuidString, "name": lot.name, "quantity": quantity,
                "unit": lot.unit, "expected_revision": lot.revision, "current_quantity": lot.quantity] as [String: Any]
        case .close(let lot, .depleted):
            description["kind"] = "inventory_quantity"
            description["editable_fields"] = ["quantity"]
            description["values"] = ["lot_id": lot.id.uuidString, "name": lot.name, "quantity": 0,
                "unit": lot.unit, "expected_revision": lot.revision, "current_quantity": lot.quantity] as [String: Any]
        default:
            description["kind"] = "other"
        }
        return description
    }

    func revisePendingChange(data: Data) async throws -> String {
        struct Input: Decodable {
            let proposal_id: UUID
            let expected_fingerprint: String
            let task_patch: TaskUpdatePatch?
            let item_patch: PendingItemPatch?
            private enum CodingKeys: String, CodingKey { case proposal_id, expected_fingerprint, task_patch, item_patch }
            init(from decoder: Decoder) throws {
                try TaskPatchFields.validate(decoder, allowed: ["proposal_id", "expected_fingerprint", "task_patch", "item_patch"])
                let container = try decoder.container(keyedBy: CodingKeys.self)
                proposal_id = try container.decode(UUID.self, forKey: .proposal_id)
                expected_fingerprint = try container.decode(String.self, forKey: .expected_fingerprint)
                task_patch = try container.decodeIfPresent(TaskUpdatePatch.self, forKey: .task_patch)
                item_patch = try container.decodeIfPresent(PendingItemPatch.self, forKey: .item_patch)
            }
        }
        let input = try JSONDecoder().decode(Input.self, from: data)
        guard (input.task_patch != nil) != (input.item_patch != nil) else {
            throw ToolError("task_patch 和 item_patch 必须且只能填写一个")
        }
        guard let old = pending.first(where: { $0.id == input.proposal_id }),
              try old.editFingerprint == input.expected_fingerprint else {
            throw ToolError("待确认项已改变，请重新 get_pending_changes 后再修改；原提案没有改变")
        }
        let kind: PendingChange.Kind
        let title: String
        let detail: String?
        var check = old.check
        switch old.kind {
        case .reminder(let original), .taskPlan(let original, _):
            guard let patch = input.task_patch else { throw ToolError("这张卡是任务，请使用 task_patch") }
            let task = try patch.applying(to: original, household: household)
            if case .taskPlan(_, let revision) = old.kind { kind = .taskPlan(task, expectedRevision: revision) }
            else { kind = .reminder(task) }
            title = task.text
            detail = ReminderSchedule.friendlySummary(task)
        case .add(let original):
            guard let patch = input.item_patch else { throw ToolError("这张卡是新增库存，请使用 item_patch") }
            var item = try patch.applying(to: original)
            if item.name != original.name {
                let candidates = try CatalogProductLookup(modelContainer: container).exactMatches(for: item.name)
                item.existingProductID = candidates.count == 1 ? candidates.first?.id : nil
            }
            let review = await reviewAdd([item])
            // A card may have been changed or discarded while the optional judge was running.
            guard let current = pending.first(where: { $0.id == old.id }),
                  try current.editFingerprint == input.expected_fingerprint else {
                throw ToolError("待确认项已改变，请重新 get_pending_changes；没有覆盖新内容")
            }
            try Task.checkCancellation()
            let canonicalInput = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: [.sortedKeys])
            if let rejected = gate("revise|" + old.id.uuidString + "|" + String(decoding: canonicalInput, as: UTF8.self), review) {
                return rejected
            }
            if let concern = insistedConcern { check = .concern(concern) }
            else if review.checked { check = review.check }
            else if case .some(.passed) = check { check = nil }
            // An unchecked revision cannot erase an existing concern.
            kind = .add(item)
            title = "新增 \(item.name) ×\(item.quantity) \(item.unit)"
            var parts: [String] = []
            if let storage = item.storage { parts.append(storage) }
            if let profile = item.profile { parts.append(profile.searchText); if profile.photo != nil { parts.append("含照片") } }
            else if item.quantityOnly { parts.append("只记数量") }
            if let date = item.packageExpiry { parts.append("包装有效期 \(date.monthDay)") }
            if let date = item.plannedUseBy { parts.append("\(date.monthDay)前吃完") }
            if item.existingProductID != nil { parts.append("家里已有同款") }
            detail = parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .setQuantity(let lot, _), .close(let lot, .depleted):
            guard let patch = input.item_patch, let quantity = patch.quantity, (0...999).contains(quantity),
                  patch.name == nil, patch.unit == nil, patch.storage == nil else {
                throw ToolError("数量提案仅可修改 quantity(0–999)，不能顺便改名称、单位、位置或物品对象")
            }
            let beforeQuantity: Int
            if case .setQuantity(_, let value) = old.kind { beforeQuantity = value } else { beforeQuantity = 0 }
            guard quantity != beforeQuantity else { throw ToolError("和现在一样，不需要修改") }
            guard try fresh(lot).revision == lot.revision else {
                throw ToolError("库存已改变，请重新查询后提出修改；原提案没有改变")
            }
            var extra: [JevClient.Question] = []
            let used = lot.quantity - quantity
            if quantity != lot.quantity, used >= 0, used != quantity {
                extra = [.init(id: "m.remain", question: Self.meaningQuestion,
                               candidate: "\(lot.name) 现在还剩 \(quantity) \(lot.unit)"),
                         .init(id: "m.used", question: Self.meaningQuestion,
                               candidate: "\(lot.name) 用掉了 \(quantity) \(lot.unit)，还剩 \(used) \(lot.unit)")]
            }
            let review = await reviewTarget(lot, extra: extra) { answers in
                guard let remain = answers["m.remain"], let usedP = answers["m.used"], usedP > remain + 0.2 else { return nil }
                return "“\(quantity)”更可能是用掉的数量：\(lot.name) 原有 \(lot.quantity)，用掉 \(quantity) 后应剩 \(used)"
            }
            guard let current = pending.first(where: { $0.id == old.id }),
                  try current.editFingerprint == input.expected_fingerprint else {
                throw ToolError("待确认项已改变，请重新 get_pending_changes；没有覆盖新内容")
            }
            guard try fresh(lot).revision == lot.revision else { throw ToolError("库存已改变，请重新查询后提出修改") }
            try Task.checkCancellation()
            if let rejected = gate("revise_quantity|\(old.id)|\(input.expected_fingerprint)|\(quantity)", review) { return rejected }
            if let concern = insistedConcern { check = .concern(concern) }
            else if review.checked { check = review.check }
            else if case .some(.passed) = check { check = nil }
            if quantity == 0 {
                kind = .close(lot, .depleted)
                title = "\(lot.name) 用完了"
                detail = "原有 \(lot.quantity) \(lot.unit)"
            } else {
                kind = .setQuantity(lot, quantity)
                title = "\(lot.name) 剩 \(quantity) \(lot.unit)"
                detail = "原来 \(lot.quantity) \(lot.unit)"
            }
        default:
            throw ToolError("这类提案暂不支持局部修改，请读取 editable_fields；原提案已保留")
        }
        guard let index = pending.firstIndex(where: { $0.id == old.id }),
              try pending[index].editFingerprint == input.expected_fingerprint else {
            throw ToolError("待确认项已改变，请重新 get_pending_changes；没有覆盖新内容")
        }
        var revised = PendingChange(kind: kind, title: title, detail: detail, check: check, requestTurnID: old.requestTurnID)
        revised.id = old.id
        let output = try encode(["status": "waiting_for_user_confirmation", "saved": false, "changed": true,
                                 "change": try pendingDescription(revised, number: index + 1)] as [String: Any])
        var next = pending
        next[index] = revised
        if let scope = revised.relatedScope { relatedScopes.insert(scope) }
        restorePending(next)
        return output
    }
}
