import Foundation

extension ButlerTools {
    static var systemCalendarTools: String {
        let string: [String: Any] = ["type": "string"]
        let optionalString: [String: Any] = ["type": ["string", "null"]]
        let optionalInt: [String: Any] = ["type": ["integer", "null"]]
        let key = objectSchema(["itemID": string, "start": string])
        let schedule: [String: Any] = ["start": string, "end": string, "timeZone": string,
            "allDay": ["type": "boolean"], "alertMinutes": optionalInt]
        var fields = schedule
        fields.merge(["title": string, "location": optionalString, "notes": optionalString]) { _, new in new }
        let tools = [
            functionSchema("get_calendar_capabilities", "查询日历系统权限和独立对话许可，不读事件、不申请权限。首页显示许可不能代替对话许可。", [:]),
            functionSchema("propose_calendar_access", "提出开启/关闭对话日历访问。首次读取前必须让用户确认相关内容会发送给当前模型；关闭不改变首页展示，也不删除历史对话内容。", ["allowed": ["type": "boolean"]]),
            functionSchema("get_system_calendars", "读取可用日历及来源，使用ID消歧，不能按同名猜测目标。需要已确认对话访问。", [:]),
            functionSchema("get_calendar_event", "按查询返回的key读取指定实例的完整内容和最新revision，包括完整备注。", ["key": key]),
            functionSchema("get_calendar_events", "读取指定时间范围（最多366天）的事件，calendar_id=null所有日历，query=null不筛标题，offset=null从0、limit=null为20最多50。日期须带Z或偏移的ISO8601。返回key和revision用于修改，key.start是本次实例原开始时间，不能自行改写。备注列表最多200字。", ["start": string, "end": string, "calendar_id": optionalString, "query": optionalString, "offset": optionalInt, "limit": optionalInt]),
            functionSchema("propose_calendar_event", "在已查询的日历中创建事件。fields起止必须带Z或偏移，timeZone须IANA；全天起止为该时区零点，end是不包含的结束日。alertMinutes=null不添加通知，否则提前0–40320分钟。frequency=null不重复，或daily/weekly/monthly/yearly；未支持的节假日、多星期、结束条件不能偷换。确认卡附首次时间冲突；不是整个重复序列的冲突证明。", ["calendar_id": string, "fields": objectSchema(fields), "frequency": ["type": ["string", "null"], "enum": [NSNull(), "daily", "weekly", "monthly", "yearly"]]]),
            functionSchema("propose_calendar_event_edit", "修改已查询事件，必须提供key、最新revision和明确span=thisEvent仅这次/futureEvents这次及以后。field=title/notes/location用text，schedule必须null；delete时text/schedule全null；schedule时text=null并完整保留未要求更改的时间/通知值，不改变原重复规则。含邀请/参与人不支持修改；复杂通知不可改期。删除无法撤销。", [
                "key": key, "expected_revision": string,
                "span": ["type": "string", "enum": ["thisEvent", "futureEvents"]],
                "field": ["type": "string", "enum": ["title", "notes", "location", "schedule", "delete"]],
                "text": optionalString, "schedule": ["anyOf": [objectSchema(schedule), ["type": "null"]]]
            ]),
            functionSchema("get_calendar_operations", "读取最近100条日历操作回执；operation_id非null则只读核实该操作，不重复写入。标识变化、结果未知不得重新创建。需要对话访问许可。", ["operation_id": optionalString])
        ]
        return tools.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }.joined(separator: ",")
    }

    func executeSystemCalendarTool(_ name: String, data: Data) throws -> String? {
        // Only explicit ISO8601 offsets are accepted, never the phone's guessed time zone.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            return try Self.calendarDate(string)
        }
        do {
            switch name {
            case "get_calendar_capabilities":
                return try encode(["system_authorized": systemCalendar.systemAuthorized, "conversation_allowed": systemCalendar.conversationAllowed,
                    "time_zone": TimeZone.current.identifier, "unsupported": ["invitations", "attendee_changes", "calendar_moves", "complex_recurrence_creation", "automatic_task_sync"]] as [String: Any])
            case "propose_calendar_access":
                struct Args: Decodable { let allowed: Bool }
                let a = try decoder.decode(Args.self, from: data)
                proposeCalendar(.access(a.allowed), title: a.allowed ? "允许对话使用日历" : "关闭对话日历访问",
                    detail: a.allowed ? "按你的请求读取的相关日历内容会发送给当前对话模型。首页展示权限不等于此许可。每次新增、修改、删除仍须确认。" : "关闭后对话不能再查询或修改日历。首页展示不受影响，历史对话中的内容不会自动删除。")
                return pendingContext
            case "get_system_calendars": return try encode(["calendars": try calendarJSON(systemCalendar.calendars())])
            case "get_calendar_event":
                struct Args: Decodable { let key: CalendarEventKey }
                let a = try decoder.decode(Args.self, from: data)
                return try encode(["event": try calendarJSON(systemCalendar.event(a.key))])
            case "get_calendar_events":
                struct Args: Decodable { let start: Date; let end: Date; let calendar_id: String?; let query: String?; let offset: Int?; let limit: Int? }
                let a = try decoder.decode(Args.self, from: data)
                let offset = a.offset ?? 0, limit = a.limit ?? 20
                guard offset >= 0, (1...50).contains(limit) else { throw CalendarFailure("分页位置必须不小于0，每页1–50条") }
                let events = try systemCalendar.events(start: a.start, end: a.end, calendarID: a.calendar_id).filter {
                    a.query == nil || $0.fields.title.localizedCaseInsensitiveContains(a.query!)
                }
                let page = Array(events.dropFirst(offset).prefix(limit))
                let more = offset < events.count && page.count < events.count - offset
                let rows = try page.map { value -> [String: Any] in
                    var json = try calendarJSON(value) as! [String: Any]
                    var fields = value.fields; fields.notes = fields.notes.map { String($0.prefix(200)) }
                    json["fields"] = try calendarJSON(fields); json["notes_truncated"] = (value.fields.notes?.count ?? 0) > 200
                    return json
                }
                return try encode(["events": rows, "total": events.count, "next_offset": more ? (offset + page.count) as Any : NSNull(),
                    "range_complete": offset == 0 && !more, "linkage": "system_only"] as [String: Any])
            case "propose_calendar_event":
                struct Args: Decodable { let calendar_id: String; let fields: CalendarEventFields; let frequency: String? }
                let a = try decoder.decode(Args.self, from: data)
                guard let calendar = try systemCalendar.calendars().first(where: { $0.id == a.calendar_id }) else { throw CalendarFailure("请先查询目标日历") }
                let change = SystemCalendarChange.create(calendar: calendar, fields: a.fields, frequency: a.frequency)
                try systemCalendar.validate(change)
                let conflicts = try calendarConflicts(a.fields, excluding: nil)
                proposeCalendar(change, title: "新增日历事件：\(a.fields.title)",
                    detail: "\(calendar.source) / \(calendar.title)\n\(a.fields.summary)\n重复：\(a.frequency ?? "不重复")\n备注：\(a.fields.notes ?? "无")\n\(conflicts)")
                return pendingContext
            case "propose_calendar_event_edit":
                struct Schedule: Decodable { let start: Date; let end: Date; let timeZone: String; let allDay: Bool; let alertMinutes: Int? }
                struct Args: Decodable { let key: CalendarEventKey; let expected_revision: String; let span: CalendarEventSpan; let field: String; let text: String?; let schedule: Schedule? }
                let a = try decoder.decode(Args.self, from: data)
                let before = try systemCalendar.event(a.key)
                guard before.revision == a.expected_revision else { throw CalendarFailure("事件已变化，请重新查询") }
                let patch: CalendarEventPatch
                let detail: String
                switch a.field {
                case "title" where a.text != nil && a.schedule == nil: patch = .title(a.text!); detail = "标题：\(a.text!)"
                case "notes" where a.schedule == nil: patch = .notes(a.text); detail = "备注：\(a.text ?? "清空")"
                case "location" where a.schedule == nil: patch = .location(a.text); detail = "地点：\(a.text ?? "清空")（清除原结构化地点）"
                case "delete" where a.text == nil && a.schedule == nil: patch = .delete; detail = "删除，Butler不提供撤销。"
                case "schedule" where a.text == nil && a.schedule != nil:
                    let s = a.schedule!
                    patch = .schedule(start: s.start, end: s.end, timeZone: s.timeZone, allDay: s.allDay, alertMinutes: s.alertMinutes)
                    detail = "原时间：\(before.fields.summary)\n新时间：\(patch.fields(after: before.fields).summary)\n" + (try calendarConflicts(patch.fields(after: before.fields), excluding: before.key))
                default: throw CalendarFailure("修改参数不匹配，未使用字段必须为null")
                }
                let change = SystemCalendarChange.edit(before: before, patch: patch, span: a.span)
                try systemCalendar.validate(change)
                proposeCalendar(change, title: "修改日历：\(before.fields.title)", detail: "\(before.calendar.source) / \(before.calendar.title)\n原事件：\(before.fields.summary)\n范围：\(a.span.summary)\n原重复规则：\(before.recurrenceDescription)\n\(detail)")
                return pendingContext
            case "get_calendar_operations":
                struct Args: Decodable { let operation_id: UUID? }
                let a = try decoder.decode(Args.self, from: data)
                let message = try a.operation_id.map { try systemCalendar.reconcile($0) }
                let all = try systemCalendar.operations()
                let values = a.operation_id.map { id in all.filter { $0.id == id } } ?? Array(all.suffix(100))
                return try encode(["message": message as Any? ?? NSNull(), "total": all.count, "operations": values.map {
                    ["id": $0.id.uuidString, "status": $0.succeeded ? "verified" : "needs_verification", "error": $0.error as Any? ?? NSNull()] as [String: Any]
                }] as [String: Any])
            default: return nil
            }
        } catch let error as CalendarFailure { throw error }
        catch { throw CalendarFailure("日历工具未完成：\(error.localizedDescription)") }
    }

    nonisolated static func calendarDate(_ value: String) throws -> Date {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { throw CalendarFailure("时间必须包含明确时区偏移") }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else { throw CalendarFailure("时间须为ISO8601，如2027-07-13T09:27:00+08:00") }
        if !value.hasSuffix("Z") {
            let suffix = String(value.suffix(6))
            let hours = Int(suffix.dropFirst().prefix(2))!, minutes = Int(suffix.suffix(2))!
            guard hours <= 14, minutes <= 59, hours != 14 || minutes == 0 else { throw CalendarFailure("时区偏移无效") }
            formatter.timeZone = TimeZone(secondsFromGMT: (hours * 3600 + minutes * 60) * (suffix.hasPrefix("-") ? -1 : 1))
        }
        let normalized = value.replacingOccurrences(of: "+00:00", with: "Z").replacingOccurrences(of: "-00:00", with: "Z")
        guard formatter.string(from: date) == normalized else { throw CalendarFailure("日期或时间不存在，不会自动改成其他日期") }
        return date
    }
    private func calendarConflicts(_ fields: CalendarEventFields, excluding key: CalendarEventKey?) throws -> String {
        try fields.validate()
        let count = try systemCalendar.events(start: fields.start, end: fields.end, calendarID: nil).filter {
            $0.key != key && $0.fields.start < fields.end && $0.fields.end > fields.start
        }.count
        return "当前首次时间段与\(count)条可读取事件重叠；不阻止安排，不涵盖全部重复日期，确认前其他App仍可能更改日历。"
    }
    private func proposeCalendar(_ change: SystemCalendarChange, title: String, detail: String) {
        guard !pending.contains(where: { if case .calendar(let other) = $0.kind { other == change } else { false } }) else { return }
        add(.calendar(change), title: title, detail: detail)
    }
    private func calendarJSON<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
    }
}
