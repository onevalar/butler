import Foundation

extension ButlerTools {
    static var appleReminderTools: String {
        let string: [String: Any] = ["type": "string"]
        let optionalString: [String: Any] = ["type": ["string", "null"]]
        let integer: [String: Any] = ["type": "integer"]
        let optionalInt: [String: Any] = ["type": ["integer", "null"]]
        let due: [String: Any] = ["anyOf": [objectSchema([
            "year": integer, "month": integer, "day": integer, "hour": optionalInt, "minute": optionalInt, "timeZone": optionalString
        ]), ["type": "null"]]]
        let recurrence: [String: Any] = ["anyOf": [objectSchema([
            "frequency": ["type": "string", "enum": ["daily", "weekly", "monthly", "yearly"]],
            "interval": integer, "weekdays": ["type": "array", "items": integer, "maxItems": 7]
        ]), ["type": "null"]]]
        let tools = [
            functionSchema("get_apple_reminder_capabilities", "查询苹果提醒事项能力/授权，不请求权限。与Butler本地任务和响铃闹钟不同；用户明确要苹果提醒事项时才使用。", [:]),
            functionSchema("propose_apple_reminder_access", "提出访问苹果提醒事项，用户确认后才出现系统权限请求；不读写提醒。说明按本次请求读取的内容会交给当前对话模型，授权不代表同意自动复制/同步本地任务。", [:]),
            functionSchema("get_apple_reminder_lists", "读取苹果提醒事项列表及可写状态，不请求权限。同名列表用来源和ID消歧，不能猜。", [:]),
            functionSchema("get_apple_reminders", "按id读取完整提醒，或按list_id（null全部）、query标题片段（null全部）、completed（null全部）筛选分页。offset=null从0，limit=null为20，最多50。指定id时其他字段全null。修改前读取最新revision。列表查询备注最多200字，需完整备注按id读取。不复制为本地任务。", [
                "id": optionalString, "list_id": optionalString, "query": optionalString,
                "completed": ["type": ["boolean", "null"]], "offset": optionalInt, "limit": optionalInt
            ]),
            functionSchema("propose_apple_reminder", "在指定系统列表创建提醒，确认后写入。list_id必须来自列表查询；title/notes是内容。due=null无截止，只有日期时hour/minute/timeZone全null；有时分时timeZone须IANA地区（如Asia/Shanghai）。notify_at_due显式决定是否添加截止通知，不是真正响铃。recurrence=null不重复，否则interval为1–365，weekly的weekdays周一1至周日7，空数组沿用截止日星期；其他frequency须空数组。重复必须有首次截止；不支持节假日排除/重复结束条件，不可简化。", [
                "list_id": string, "title": string, "notes": optionalString, "due": due, "priority": integer,
                "recurrence": recurrence, "notify_at_due": ["type": "boolean"]
            ]),
            functionSchema("propose_apple_reminder_edit", "提出修改已查询的系统提醒。field=title/notes使用text（notes=null清空）；priority使用number=0–9；completed使用flag，true完成/false重新打开；delete三个值全null，删除整个提醒及重复规则，不是只跳过一次。未使用的值必须null。一次只改一个字段，保留其他内容；同一提醒的后续修改等本次完成后重新读取revision。", [
                "id": string, "expected_revision": string, "field": ["type": "string", "enum": ["title", "notes", "priority", "completed", "delete"]],
                "text": optionalString, "number": optionalInt, "flag": ["type": ["boolean", "null"]]
            ]),
            functionSchema("propose_apple_reminder_schedule", "完整替换截止/重复/通知设置，须先查询并保留未要求改变的值；schedule_editable=false时不可使用。due和recurrence格式同创建工具。重复起始日一起设为新截止日期；仅改标题或备注不要使用此工具。", [
                "id": string, "expected_revision": string, "due": due, "recurrence": recurrence, "notify_at_due": ["type": "boolean"]
            ]),
            functionSchema("get_apple_reminder_operations", "查看本设备最近系统写入回执。operation_id=null返回最近100条及总数；指定ID只读对账，可消除已核实的待确认结果，不重复写系统。标识失效不能证明删除成功。", ["operation_id": optionalString])
        ]
        return ToolSchema.json(tools, sortedKeys: true)
    }

    func executeAppleReminderTool(_ name: String, data: Data) async throws -> String? {
        do {
            switch name {
            case "get_apple_reminder_capabilities":
                return try encode(["authorization": appleReminders.authorization,
                    "supported": ["lists", "search", "create", "title", "notes", "priority", "reschedule", "complete", "reopen", "delete", "basic_recurrence"],
                    "unsupported": ["local_task_linking", "automatic_mirroring", "location_rule_creation", "complex_recurrence_editing", "repeat_end", "skip_single_occurrence"],
                    "time_zone": TimeZone.current.identifier, "confirmation_required": true,
                    "note": "系统提醒事项独立管理；不会在Butler再设一份通知。查询只包含系统当前允许访问的内容。"] as [String: Any])
            case "propose_apple_reminder_access":
                proposeAppleReminder(.access, title: "允许对话访问苹果提醒事项", detail: "确认后申请系统权限；按你请求读取的提醒内容会提供给当前对话模型。不会自动复制本地任务，也不会自动读出全部提醒。")
                return pendingContext
            case "get_apple_reminder_lists":
                return try encode(["lists": try appleReminderJSON(appleReminders.lists()), "authorization": appleReminders.authorization])
            case "get_apple_reminders":
                struct Args: Decodable {
                    let id: String?; let list_id: String?; let query: String?; let completed: Bool?; let offset: Int?; let limit: Int?
                }
                let a = try JSONDecoder().decode(Args.self, from: data)
                let offset = a.offset ?? 0, limit = a.limit ?? 20
                guard offset >= 0, (1...50).contains(limit) else { throw AppleReminderFailure("分页位置须不小于0，每页1–50条") }
                let values: [AppleReminderSnapshot]
                if let id = a.id {
                    guard a.list_id == nil, a.query == nil, a.completed == nil, a.offset == nil, a.limit == nil else {
                        throw AppleReminderFailure("按ID读取时其他筛选和分页参数须为null")
                    }
                    values = [try appleReminders.reminder(id)]
                } else {
                    let query = a.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    values = try await appleReminders.reminders(listID: a.list_id).filter {
                        (query.isEmpty || $0.fields.title.localizedCaseInsensitiveContains(query)) && (a.completed == nil || $0.completed == a.completed)
                    }
                }
                let page = Array(values.dropFirst(offset).prefix(limit))
                let more = offset < values.count && page.count < values.count - offset
                return try encode(["reminders": try page.map { try appleReminderDescription($0, full: a.id != nil) },
                    "total": values.count, "offset": offset, "truncated": offset > 0 || more,
                    "next_offset": more ? (offset + page.count) as Any : NSNull(),
                    "queried_at": ISO8601DateFormatter().string(from: .now), "linkage": "system_only"] as [String: Any])
            case "propose_apple_reminder":
                struct Args: Decodable {
                    let list_id: String; let title: String; let notes: String?; let due: AppleReminderDue?
                    let priority: Int; let recurrence: AppleReminderRecurrence?; let notify_at_due: Bool
                }
                let a = try JSONDecoder().decode(Args.self, from: data)
                guard let list = try appleReminders.lists().first(where: { $0.id == a.list_id }) else { throw AppleReminderFailure("目标列表不存在，请先查询") }
                let fields = AppleReminderFields(title: a.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    notes: a.notes?.isEmpty == true ? nil : a.notes, due: a.due, priority: a.priority,
                    recurrence: a.recurrence, notifyAtDue: a.notify_at_due)
                let change = AppleReminderChange.create(list: list, fields: fields)
                try appleReminders.validate(change)
                proposeAppleReminder(change, title: "添加到苹果提醒事项：\(fields.title)",
                    detail: "\(list.source) / \(list.title)\n\(fields.scheduleSummary)\n优先级：\(fields.priority)\n备注：\(fields.notes ?? "无")")
                return pendingContext
            case "propose_apple_reminder_edit":
                struct Args: Decodable { let id: String; let expected_revision: String; let field: String; let text: String?; let number: Int?; let flag: Bool? }
                let a = try JSONDecoder().decode(Args.self, from: data)
                let before = try freshAppleReminder(a.id, revision: a.expected_revision)
                let patch: AppleReminderPatch
                let detail: String
                switch a.field {
                case "title" where a.text != nil && a.number == nil && a.flag == nil:
                    patch = .title(a.text!.trimmingCharacters(in: .whitespacesAndNewlines)); detail = "标题改为：\(a.text!)"
                case "notes" where a.number == nil && a.flag == nil:
                    patch = .notes(a.text?.isEmpty == true ? nil : a.text); detail = "备注改为：\(a.text ?? "清空")"
                case "priority" where a.number != nil && a.text == nil && a.flag == nil:
                    patch = .priority(a.number!); detail = "优先级改为：\(a.number!)"
                case "completed" where a.flag != nil && a.text == nil && a.number == nil:
                    patch = .completed(a.flag!); detail = a.flag! ? "标为完成；重复项的后续安排由苹果提醒事项处理，不代表取消重复规则" : "重新打开为未完成"
                case "delete" where a.text == nil && a.number == nil && a.flag == nil:
                    patch = .delete; detail = "删除整个系统提醒及其重复规则；不是跳过本次，Butler不提供删除撤销。"
                default: throw AppleReminderFailure("修改字段与值不匹配，未使用的值必须为null")
                }
                try proposeAppleReminderEdit(before, patch: patch, detail: detail)
                return pendingContext
            case "propose_apple_reminder_schedule":
                struct Args: Decodable { let id: String; let expected_revision: String; let due: AppleReminderDue?; let recurrence: AppleReminderRecurrence?; let notify_at_due: Bool }
                let a = try JSONDecoder().decode(Args.self, from: data)
                let before = try freshAppleReminder(a.id, revision: a.expected_revision)
                let patch = AppleReminderPatch.schedule(due: a.due, recurrence: a.recurrence, notifyAtDue: a.notify_at_due)
                try proposeAppleReminderEdit(before, patch: patch,
                    detail: "原安排：\(before.scheduleDescription)\n新安排：\(patch.fields(after: before.fields).scheduleSummary)\n重复起始日同步设为新截止日期。")
                return pendingContext
            case "get_apple_reminder_operations":
                struct Args: Decodable { let operation_id: UUID? }
                let a = try JSONDecoder().decode(Args.self, from: data)
                var message: String?
                if let id = a.operation_id { message = try appleReminders.reconcile(id) }
                let operations = a.operation_id.map { id in appleReminders.operations.filter { $0.id == id } } ?? Array(appleReminders.operations.suffix(100))
                return try encode(["operations": operations.map {
                    ["operation_id": $0.id.uuidString, "system_id": $0.targetID, "status": $0.succeeded ? "verified" : "needs_verification", "error": $0.error as Any? ?? NSNull()] as [String: Any]
                }, "total": appleReminders.operations.count, "message": message as Any? ?? NSNull()] as [String: Any])
            default: return nil
            }
        } catch is DecodingError {
            throw AppleReminderFailure("提醒事项工具参数格式不正确，没有写入系统")
        } catch is CancellationError { throw CancellationError() }
        catch { throw AppleReminderFailure(error.localizedDescription) }
    }

    private func freshAppleReminder(_ id: String, revision: String) throws -> AppleReminderSnapshot {
        let value = try appleReminders.reminder(id)
        guard value.revision == revision else { throw AppleReminderFailure("提醒事项已经变化，请重新查询revision") }
        return value
    }

    private func proposeAppleReminderEdit(_ before: AppleReminderSnapshot, patch: AppleReminderPatch, detail: String) throws {
        let change = AppleReminderChange.edit(before: before, patch: patch)
        try appleReminders.validate(change)
        proposeAppleReminder(change, title: "苹果提醒事项：\(before.fields.title)", detail: "\(before.list.source) / \(before.list.title)\n\(detail)")
    }

    private func proposeAppleReminder(_ change: AppleReminderChange, title: String, detail: String) {
        guard !pending.contains(where: { if case .appleReminder(let other) = $0.kind { other == change } else { false } }) else { return }
        add(.appleReminder(change), title: title, detail: detail)
    }

    private func appleReminderJSON<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }

    private func appleReminderDescription(_ value: AppleReminderSnapshot, full: Bool) throws -> [String: Any] {
        var fields = value.fields
        if !full, let notes = fields.notes { fields.notes = String(notes.prefix(200)) }
        return ["id": value.id, "revision": value.revision, "list": try appleReminderJSON(value.list),
            "fields": try appleReminderJSON(fields), "completed": value.completed,
            "notes_truncated": !full && (value.fields.notes?.count ?? 0) > 200,
            "schedule_editable": value.scheduleEditable, "schedule": value.scheduleDescription,
            "linkage": "system_only"]
    }
}
