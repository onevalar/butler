import Foundation

extension ButlerTools {
    static var alarmTools: String {
        let string: [String: Any] = ["type": "string"]
        let optionalString: [String: Any] = ["type": ["string", "null"]]
        let optionalInt: [String: Any] = ["type": ["integer", "null"]]
        let tools = [
            functionSchema("get_alarm_capabilities", "查询真正响铃的闹钟/倒计时能力、限制和系统权限；不弹权限框。叫醒、必须响铃等意图使用闹钟，普通提醒继续用通知，含糊时询问。不能访问苹果时钟App闹钟。", [:]),
            functionSchema("get_alarms", "查询本设备 Butler 闹钟、倒计时及真实系统状态。id=null时按query标题片段筛选（null为全部），按创建顺序分页；offset=null从0开始，limit=null默认50，最多100。还有next_offset时可继续，不把一页当作全部；指定id时其他参数留null。修改前读取id和revision。not_scheduled不代表任务完成或曾经响过，result_pending表示需核实。查询不请求权限、不重新创建。", [
                "id": optionalString, "query": optionalString, "offset": optionalInt, "limit": optionalInt
            ]),
            functionSchema("propose_alarm", "提出创建/完整替换响铃闹钟或倒计时，用户确认后执行。id=null且expected_revision=null为创建；修改先get_alarms，保留未要求改动的参数。once使用带UTC偏移的ISO8601 at（含秒），weekly用hour/minute和weekdays（周一1至周日7），timer用seconds，其他字段必须null或空数组。weekly跟随手机当地时间，不支持固定异地时区、未来才开始、跳过某次或节假日排除，不能静默改写这些意图；需要这些规则先说明限制。timer确认后从头计时，修改运行中的timer会重新开始，须明确告诉用户。未确认提案的修改先discard_pending_changes再提出。", [
                "id": optionalString, "expected_revision": optionalInt, "title": string,
                "mode": ["type": "string", "enum": ["once", "weekly", "timer"]],
                "at": optionalString, "hour": optionalInt, "minute": optionalInt,
                "weekdays": ["type": "array", "items": ["type": "integer"], "maxItems": 7],
                "seconds": optionalInt
            ]),
            functionSchema("propose_alarm_action", "提出闹钟操作，确认后执行；先get_alarms取得id/revision。cancel取消所有后续响铃但保留记录；enable重新启用（timer从头开始）；stop仅停止正在响的本次、不完成任务、不取消每周重复；pause/resume只暂停/继续倒计时。不能把stop当作跳过尚未响的某次，也不能把取消整个重复闹钟当作只取消今天。", [
                "id": string, "expected_revision": ["type": "integer"],
                "action": ["type": "string", "enum": ["cancel", "enable", "stop", "pause", "resume"]]
            ])
        ]
        return tools.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }.joined(separator: ",")
    }

    func executeAlarmTool(_ name: String, data: Data) throws -> String? {
        switch name {
        case "get_alarm_capabilities":
            return try encode([
                "source": "AlarmKit", "authorization": alarms.authorization,
                "rules": ["once_fixed_instant", "weekly_device_local_time", "countdown_1_to_86400_seconds"],
                "actions": ["query", "create", "replace", "cancel", "enable", "stop_alert", "pause_countdown", "resume_countdown"],
                "unsupported": ["clock_app_alarms", "skip_one_repeating_occurrence", "holiday_calendar", "fixed_zone_weekly", "future_start_weekly", "automatic_task_completion"],
                "confirmation_required": true, "device_time_zone": TimeZone.current.identifier,
                "now": ISO8601DateFormatter().string(from: .now),
                "note": "系统接受调度不等于已经响铃；不保证精确后台运行AI。"
            ] as [String: Any])
        case "get_alarms":
            struct Args: Decodable { let id: UUID?; let query: String?; let offset: Int?; let limit: Int? }
            let args = try JSONDecoder().decode(Args.self, from: data)
            let offset = args.offset ?? 0, limit = args.limit ?? 50
            guard offset >= 0, (1...100).contains(limit) else { throw AlarmFailure("分页位置须不小于0，每页1–100条") }
            guard args.id == nil || (args.query == nil && args.offset == nil && args.limit == nil) else {
                throw AlarmFailure("按ID读取时不能混用搜索和分页参数")
            }
            let live = try alarms.refresh()
            let query = args.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let matching = try args.id.map { [try alarms.record($0)] } ?? alarms.records.filter {
                query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
            }
            let values = Array(matching.dropFirst(offset).prefix(limit))
            let hasMore = offset < matching.count && values.count < matching.count - offset
            let knownIDs = Set(alarms.records.flatMap { [$0.systemID] + ($0.operation?.retiredIDs ?? []) })
            return try encode([
                "authorization": alarms.authorization,
                "alarms": values.map { alarmDescription($0, live: live) },
                "total": matching.count, "offset": offset,
                "truncated": offset > 0 || hasMore,
                "next_offset": hasMore ? (offset + values.count) as Any : NSNull(),
                "unlinked_system_alarm_count": live.filter { !knownIDs.contains($0.id) }.count,
                "note": "仅本设备 Butler 闹钟。未在系统中调度不代表任务完成；未关联的系统闹钟不能猜测归属。"
            ] as [String: Any])
        case "propose_alarm":
            struct Args: Decodable {
                let id: UUID?; let expected_revision: Int?; let title: String; let mode: String
                let at: String?; let hour: Int?; let minute: Int?; let weekdays: [Int]; let seconds: Int?
            }
            let a = try JSONDecoder().decode(Args.self, from: data)
            guard (a.id == nil) == (a.expected_revision == nil) else { throw AlarmFailure("修改须同时提供闹钟ID和最新revision") }
            let rule: ButlerAlarm.Rule
            switch a.mode {
            case "once":
                guard let at = a.at, a.hour == nil, a.minute == nil, a.weekdays.isEmpty, a.seconds == nil,
                      let date = ISO8601DateFormatter().date(from: at) else {
                    throw AlarmFailure("一次闹钟需要带时区的ISO8601时间，例如2026-10-01T07:00:00+08:00，不能混用重复或倒计时参数")
                }
                rule = .once(date)
            case "weekly":
                guard let hour = a.hour, let minute = a.minute, a.at == nil, a.seconds == nil else {
                    throw AlarmFailure("每周闹钟需要时分和星期，不能混用日期或倒计时参数")
                }
                rule = .weekly(hour: hour, minute: minute, weekdays: a.weekdays.sorted())
            case "timer":
                guard let seconds = a.seconds, a.at == nil, a.hour == nil, a.minute == nil, a.weekdays.isEmpty else {
                    throw AlarmFailure("倒计时只使用秒数，不能混用日期或重复参数")
                }
                rule = .timer(seconds: seconds)
            default: throw AlarmFailure("不支持这种响铃规则，请查询闹钟能力")
            }
            let id = a.id ?? UUID()
            let title = a.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let change = ButlerAlarm.Change.set(id: id, title: title, rule: rule, expectedRevision: a.expected_revision)
            try alarms.validate(change)
            if a.id == nil, pending.contains(where: {
                if case .alarm(.set(_, let existingTitle, let existingRule, nil)) = $0.kind {
                    return existingTitle == title && existingRule == rule
                }
                return false
            }) { return pendingContext }
            add(.alarm(change), title: (a.id == nil ? "设置响铃：" : "修改响铃：") + title,
                detail: rule.summary + "\n静音或专注模式下也会响铃；停止响铃不代表任务完成。")
            return pendingContext
        case "propose_alarm_action":
            struct Args: Decodable { let id: UUID; let expected_revision: Int; let action: ButlerAlarm.Action }
            let a = try JSONDecoder().decode(Args.self, from: data)
            _ = try alarms.refresh()
            let value = try alarms.record(a.id)
            let change = ButlerAlarm.Change.action(id: a.id, action: a.action, expectedRevision: a.expected_revision,
                                                  expiresAt: .now.addingTimeInterval(300))
            try alarms.validate(change)
            add(.alarm(change), title: "\(value.title)：\(a.action.summary)", detail: value.rule.summary + "\n此操作请在 5 分钟内确认，过期后重新查询。")
            return pendingContext
        default: return nil
        }
    }

    private func alarmDescription(_ value: ButlerAlarm, live: [SystemAlarm]) -> [String: Any] {
        var rule: [String: Any]
        switch value.rule {
        case .once(let date): rule = ["mode": "once", "at": ISO8601DateFormatter().string(from: date)]
        case .weekly(let hour, let minute, let weekdays):
            rule = ["mode": "weekly", "hour": hour, "minute": minute, "weekdays": weekdays, "time_zone": "device_local"]
        case .timer(let seconds): rule = ["mode": "timer", "seconds": seconds]
        }
        rule["summary"] = value.rule.summary
        let current = live.first { $0.id == value.systemID }
        return ["id": value.id.uuidString, "revision": value.revision, "title": value.title,
                "rule": rule, "enabled_intent": value.enabled,
                "system_state": current?.state.rawValue ?? "not_scheduled",
                "remaining_seconds": current?.remainingSeconds as Any? ?? NSNull(),
                "queried_at": ISO8601DateFormatter().string(from: .now),
                "remaining_note": "剩余秒数来自系统实时活动；null表示不可读取，不能用最初时长冒充剩余时间。",
                "result_pending": value.operation != nil,
                "previous_system_alarms_remaining": live.filter { value.operation?.retiredIDs.contains($0.id) == true }.count,
                "last_error": value.lastError as Any? ?? NSNull()]
    }
}
