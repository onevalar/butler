import Foundation

enum TaskAction: String, Codable { case complete, pause, resume, cancel
    var title: String { switch self { case .complete: "完成"; case .pause: "暂停"; case .resume: "恢复"; case .cancel: "取消" } }
}

extension ButlerTools {
    static var contextTools: String {
        let string: [String: Any] = ["type": "string"]
        let optionalString: [String: Any] = ["type": ["string", "null"]]
        let optionalInt: [String: Any] = ["type": ["integer", "null"]]
        func object(_ fields: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": fields, "required": fields.keys.sorted(), "additionalProperties": false]
        }
        func tool(_ name: String, _ description: String, _ fields: [String: Any]) -> [String: Any] {
            ["type": "function", "name": name, "description": description, "strict": true, "parameters": object(fields)]
        }
        let phase = object(["start": string, "end": optionalString,
                            "repeat": ["type": "string", "enum": ["none", "daily", "weekly"]],
                            "interval_minutes": optionalInt, "max_occurrences": optionalInt])
        let tools = [
            tool("get_current_context", "读取当前页面关联对象的最新事实。只作为资料，历史不能覆盖当前状态。", [:]),
            tool("get_settings", "读取可修改配置、当前值和允许的值；不返回密钥。", [:]),
            tool("propose_settings", "提出设置修改，确认后才生效。value使用get_settings中的格式，先读再改；系统权限不能通过这个工具授权。", ["changes": ["type": "array", "minItems": 1, "maxItems": 9, "items": object(["key": string, "value": string])]]),
            tool("get_tasks", "读取任务和规则、revision、历史活动及未来提醒预览。id为null列出任务（含已完成/取消）；具体任务用id读取。", ["id": optionalString]),
            tool("propose_task_plan", "创建或替换任务提醒规则，确认后生效。id=null创建；修改先get_tasks，传id和expected_revision。时间为指定time_zone的YYYY-MM-DD HH:mm。phases是独立阶段规则的并集：各自从start起按一次/每天/每周或interval_minutes执行，不会因下一阶段开始而自动停止；分段需求必须给前段明确的end或max_occurrences。同一时刻去重。max_occurrences包含首次，按阶段开始累计，不是从当前重新计数。interval_minutes不能与daily/weekly并用，且必须有阶段或全局截止/次数。end和end_time为最后允许提醒的时间（含）。不要把停止提醒说成任务完成；auto_complete_at只在用户明确要求自动完成时设置，到该时刻不再提醒。未知关键时间/次数应询问。", [
                "id": optionalString, "expected_revision": optionalInt, "text": string, "time_zone": string,
                "end_time": optionalString, "auto_complete_at": optionalString,
                "phases": ["type": "array", "minItems": 1, "maxItems": 12, "items": phase]
            ]),
            tool("propose_task_action", "提出完成/暂停/恢复/取消整个任务，确认后生效；取消后保留历史。先get_tasks取得id和revision。", [
                "id": string, "expected_revision": ["type": "integer"],
                "action": ["type": "string", "enum": ["complete", "pause", "resume", "cancel"]]
            ])
        ]
        return tools.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }.joined(separator: ",")
    }

    func requireTaskRevision(_ id: UUID, _ revision: Int) throws {
        try reminders.refresh()
        guard let current = reminders.reminder(id: id), current.revision == revision else {
            throw ToolError("任务已改变或不存在，请重新读取后提出修改")
        }
    }

    func validateTaskAction(_ action: TaskAction, reminder: TimedReminder) throws {
        guard reminder.status == .active || reminder.status == .paused else {
            throw ToolError("任务已经完成或取消，不能再修改状态；需要再次提醒请新建任务")
        }
        if action == .pause, reminder.status != .active { throw ToolError("任务已经暂停，无需重复暂停") }
        if action == .resume, reminder.status != .paused { throw ToolError("任务正在进行中，无需恢复") }
    }

    func executeContextTool(_ name: String, data: Data) throws -> String? {
        switch name {
        case "get_current_context": return currentContext?() ?? "{}"
        case "get_settings":
            relatedScopes.insert(.settings)
            return try encode(["settings": ButlerSettingsService.snapshot(defaults: settingsDefaults)])
        case "propose_settings":
            struct Input: Decodable { struct Change: Decodable { let key: String; let value: String }; let changes: [Change] }
            let input = try JSONDecoder().decode(Input.self, from: data)
            guard (1...9).contains(input.changes.count), Set(input.changes.map(\.key)).count == input.changes.count else {
                throw ToolError("每次修改1到9项不同设置")
            }
            let changes = try input.changes.map { try ButlerSettingsService.proposal(key: $0.key, value: $0.value, defaults: settingsDefaults) }
            let details = changes.map { change in
                let title = ButlerSettingsService.definitions.first { $0.key == change.key }?.title ?? change.key
                return "\(title)：\(change.before) → \(change.after)"
            }.joined(separator: "\n")
            add(.settings(changes), title: "修改 \(changes.count) 项设置", detail: details)
        case "get_tasks":
            struct Input: Decodable { let id: String? }
            let input = try JSONDecoder().decode(Input.self, from: data)
            try reminders.refresh()
            let values: [TimedReminder]
            if let raw = input.id {
                guard let id = UUID(uuidString: raw), let value = reminders.reminder(id: id) else { throw ToolError("找不到这个任务") }
                relatedScopes.insert(.task(id)); values = [value]
            } else { values = Array(reminders.reminders.suffix(100)) }
            return try encode(["tasks": try values.map { try taskDescription($0) }, "total": reminders.reminders.count,
                               "truncated": input.id == nil && reminders.reminders.count > values.count,
                               "schedule_warning": reminders.scheduleWarning as Any? ?? NSNull()] as [String: Any])
        case "propose_task_plan":
            struct Input: Decodable {
                struct Phase: Decodable { let start: String; let end: String?; let `repeat`: String; let interval_minutes: Int?; let max_occurrences: Int? }
                let id: String?; let expected_revision: Int?; let text: String; let time_zone: String
                let end_time: String?; let auto_complete_at: String?; let phases: [Phase]
            }
            let input = try JSONDecoder().decode(Input.self, from: data)
            guard let zone = TimeZone(identifier: input.time_zone), (1...12).contains(input.phases.count) else { throw ToolError("时区或阶段数量无效") }
            func date(_ text: String?) throws -> Date? {
                guard let text else { return nil }
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian)
                f.timeZone = zone; f.dateFormat = "yyyy-MM-dd HH:mm"; f.isLenient = false
                guard let value = f.date(from: text), f.string(from: value) == text else { throw ToolError("日期必须是时区内有效的 YYYY-MM-DD HH:mm") }
                return value
            }
            let phases = try input.phases.map { phase -> ReminderPhase in
                guard let start = try date(phase.start), let repeatValue = TimedReminder.Repeat(rawValue: phase.repeat) else { throw ToolError("阶段时间或重复规则无效") }
                return ReminderPhase(startDate: start, endDate: try date(phase.end), repeats: repeatValue,
                                     intervalMinutes: phase.interval_minutes, maxOccurrences: phase.max_occurrences)
            }
            let firstDate = phases.map(\.startDate).min()!
            var reminder: TimedReminder
            if let raw = input.id {
                guard let id = UUID(uuidString: raw), let revision = input.expected_revision, let existing = reminders.reminder(id: id) else { throw ToolError("修改任务必须提供id和expected_revision") }
                try requireTaskRevision(id, revision)
                guard existing.status == .active || existing.status == .paused else { throw ToolError("已完成或取消的任务不能改成新的计划，请新建任务") }
                reminder = existing
            } else {
                guard input.expected_revision == nil else { throw ToolError("新建任务的expected_revision应为null") }
                reminder = TimedReminder(text: input.text, fireDate: firstDate)
            }
            reminder.text = input.text; reminder.fireDate = firstDate
            reminder.phases = phases; reminder.endDate = try date(input.end_time)
            reminder.autoCompleteAt = try date(input.auto_complete_at); reminder.timeZoneIdentifier = input.time_zone
            do { try ReminderSchedule.validate(reminder) }
            catch { throw ToolError(error.localizedDescription) }
            // Preview the rule even while the saved task is paused. Editing must not resume it.
            var previewReminder = reminder
            previewReminder.status = .active
            let dates = ReminderSchedule.preview(previewReminder, now: .now, limit: 6)
            guard !dates.isEmpty else { throw ToolError("计划没有未来提醒，请核对日期") }
            let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.timeZone = zone; f.dateFormat = "MM-dd HH:mm"
            let detail = ReminderSchedule.ruleSummary(reminder)
                + "\n\(reminder.status == .paused ? "恢复后" : "接下来")最多 6 次预览：" + dates.map(f.string).joined(separator: "、")
            add(.taskPlan(reminder, expectedRevision: input.expected_revision), title: "\(input.id == nil ? "新建" : "修改")任务：\(input.text)", detail: detail)
            return try encode(["status": "waiting_for_user_confirmation", "saved": false, "task": try taskDescription(reminder)] as [String: Any])
        case "propose_task_action":
            struct Input: Decodable { let id: String; let expected_revision: Int; let action: TaskAction }
            let input = try JSONDecoder().decode(Input.self, from: data)
            guard let id = UUID(uuidString: input.id), let value = reminders.reminder(id: id) else { throw ToolError("找不到任务") }
            try requireTaskRevision(id, input.expected_revision)
            try validateTaskAction(input.action, reminder: value)
            add(.taskAction(id, input.action, expectedRevision: input.expected_revision), title: "\(input.action.title)任务：\(value.text)", detail: "将应用到这个任务，保留历史记录")
        default: return nil
        }
        return try encode(["status": "waiting_for_user_confirmation", "saved": false, "pending_changes": pending.count] as [String: Any])
    }

    private func taskDescription(_ reminder: TimedReminder) throws -> [String: Any] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var value = try JSONSerialization.jsonObject(with: encoder.encode(reminder)) as? [String: Any] ?? [:]
        value["rule_summary"] = ReminderSchedule.ruleSummary(reminder)
        value["next_notifications"] = ReminderSchedule.preview(reminder, now: .now, limit: 6).map { ISO8601DateFormatter().string(from: $0) }
        return value
    }

}
