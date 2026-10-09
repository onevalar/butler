import Foundation

enum TaskAction: String, Codable { case complete, pause, resume, cancel, reopen, delete
    var title: String { switch self { case .complete: "完成"; case .pause: "暂停"; case .resume: "恢复"; case .cancel: "取消"; case .reopen: "重新标记为未完成"; case .delete: "删除" } }
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
            tool("propose_task_plan", "创建或替换任务提醒规则，确认后生效。id=null创建；修改先get_tasks，传id和expected_revision。时间为指定time_zone的YYYY-MM-DD HH:mm。phases是独立阶段规则的并集：各自从start起按一次/每天/每周或interval_minutes执行，不会因下一阶段开始而自动停止；分段需求必须给前段明确的end或max_occurrences。同一时刻去重。max_occurrences包含首次，按阶段开始累计，不是从当前重新计数。interval_minutes不能与daily/weekly并用，且必须有阶段或全局截止/次数。end和end_time为最后允许提醒的时间（含）。不要把停止提醒说成任务完成；auto_complete_at只在用户明确要求自动完成时设置，到该时刻不再提醒。未知关键时间/次数应询问。" + TaskFamilyArgs.guidance, [
                "id": optionalString, "expected_revision": optionalInt, "text": string, "time_zone": string,
                "end_time": optionalString, "auto_complete_at": optionalString,
                "phases": ["type": "array", "minItems": 1, "maxItems": 12, "items": phase],
                "family": TaskFamilyArgs.schema
            ]),
            tool("propose_nudge", "替用户提醒负责这件家庭任务的家人一下（对方手机会马上收到“某某提醒你”）。用户说“提醒老婆一下交水费的事”“催他一下”时用；先get_tasks取id。只对交给别人的家庭任务可用。确认后发出。", ["id": string]),
            tool("propose_household_rule", "增加或删除家庭的共享与提醒规则（仅当current_context有household时）。规则是以后你判断“谁能看到、谁负责、提醒谁”时照做的一句话，如“缴费的事都交给老婆”“孩子的事全家都能看到”“我的体检只给我看”“老婆完成的事告诉我”。applies_to=household 全家共用（家人也会看到），me 只对当前用户自己、只存在他手机上。删除时action=remove并给rule_id（来自current_context.household.rules），text填原文。用户纠正你的判断后，可以顺带提议记成规则。确认后生效。", [
                "action": ["type": "string", "enum": ["add", "remove"]], "text": string,
                "applies_to": ["type": "string", "enum": ["household", "me"]], "rule_id": optionalString
            ]),
            tool("propose_quiet_hours", "设置当前用户的免打扰时段（仅当current_context有household时）：家人交给他的事、提醒他一下、完成通知在这段时间内不响，到结束时再提醒；他自己定的提醒照常。start/end 为HH:mm，可跨午夜；都填null表示取消。确认后生效。", [
                "start": optionalString, "end": optionalString
            ]),
            tool("propose_task_sharing", "修改家庭任务谁能看到、谁负责、提醒谁（仅当current_context有household时）。用户说“这个交给老婆”“别让孩子看到”“让全家都知道”“只提醒我”时用它；先get_tasks取得id和revision。已完成的任务也可以改。确认后生效。" + TaskFamilyArgs.guidance, [
                "id": string, "expected_revision": ["type": "integer"], "family": TaskFamilyArgs.schema
            ]),
            tool("propose_task_action", "提出完成/暂停/恢复/取消/删除整个任务；reopen将已完成或取消的任务重新标记为未完成。cancel保留历史，delete永久删除任务及操作记录并停止提醒，保留对话。仅在用户明确要求删除时使用delete，确认后才生效。先get_tasks取得id和revision。", [
                "id": string, "expected_revision": ["type": "integer"],
                "action": ["type": "string", "enum": ["complete", "pause", "resume", "cancel", "reopen", "delete"]]
            ])
        ]
        return ToolSchema.json(tools, sortedKeys: true)
    }

    func requireTaskRevision(_ id: UUID, _ revision: Int) throws {
        try reminders.refresh()
        guard let current = reminders.reminder(id: id), current.revision == revision else {
            throw ToolError("任务已改变或不存在，请重新读取后提出修改")
        }
    }

    func validateTaskAction(_ action: TaskAction, reminder: TimedReminder) throws {
        if action == .delete { return }
        if action == .reopen {
            guard reminder.status == .completed || reminder.status == .cancelled else { throw ToolError("任务尚未结束，不需要重新开启") }
            return
        }
        guard reminder.status == .active || reminder.status == .paused else {
            throw ToolError("任务已经完成或取消，如需纠正请使用reopen，再修改提醒计划")
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
                let family: TaskFamilyArgs?
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
            reminder.sharing = try taskSharing(input.family, existing: reminder.sharing)
            do { try ReminderSchedule.validate(reminder) }
            catch { throw ToolError(error.localizedDescription) }
            // Preview the rule even while the saved task is paused. Editing must not resume it.
            var previewReminder = reminder
            previewReminder.status = .active
            let dates = ReminderSchedule.preview(previewReminder, now: .now, limit: 6)
            guard !dates.isEmpty else { throw ToolError("计划没有未来提醒，请核对日期") }
            let detail = ReminderSchedule.friendlySummary(reminder)
            add(.taskPlan(reminder, expectedRevision: input.expected_revision), title: "\(input.id == nil ? "新建" : "修改")任务：\(input.text)", detail: detail)
            return try encode(["status": "waiting_for_user_confirmation", "saved": false, "task": try taskDescription(reminder)] as [String: Any])
        case "propose_task_action":
            struct Input: Decodable { let id: String; let expected_revision: Int; let action: TaskAction }
            let input = try JSONDecoder().decode(Input.self, from: data)
            guard let id = UUID(uuidString: input.id), let value = reminders.reminder(id: id) else { throw ToolError("找不到任务") }
            try requireTaskRevision(id, input.expected_revision)
            try validateTaskAction(input.action, reminder: value)
            add(.taskAction(id, input.action, expectedRevision: input.expected_revision), title: "\(input.action.title)任务：\(value.text)",
                detail: input.action == .delete ? "永久删除任务及操作记录，停止后续提醒；对话记录保留。此操作不能撤销。" : nil)
        case "propose_nudge":
            struct Input: Decodable { let id: String }
            let input = try JSONDecoder().decode(Input.self, from: data)
            let household = HouseholdStore.shared
            guard household.state != nil else { throw ToolError("还没有建立家庭") }
            guard let id = UUID(uuidString: input.id), let value = reminders.reminder(id: id) else { throw ToolError("找不到任务") }
            guard value.status == .active, let sharing = value.sharing, sharing.isShared,
                  let target = sharing.assignee ?? sharing.reminded.first, target != household.state?.me else {
                throw ToolError("这件事没有交给别人，不需要提醒家人")
            }
            add(.nudge(id), title: "提醒\(household.names.name(target) ?? "家人")一下：\(value.text)", detail: "对方手机会马上收到提醒")
        case "propose_household_rule":
            struct Input: Decodable { let action: String; let text: String; let applies_to: String; let rule_id: String? }
            let input = try JSONDecoder().decode(Input.self, from: data)
            let household = HouseholdStore.shared
            guard household.state != nil else { throw ToolError("还没有建立家庭") }
            let forMe = input.applies_to == "me"
            if input.action == "remove" {
                guard let raw = input.rule_id, let id = UUID(uuidString: raw),
                      let rule = (household.rules + household.myRules).first(where: { $0.id == id }) else { throw ToolError("找不到这条规则") }
                add(.removeHouseholdRule(rule), title: "删除规则：\(rule.text)", detail: nil)
            } else {
                let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (2...200).contains(text.count) else { throw ToolError("规则要写清楚，最多200字") }
                add(.householdRule(HouseholdRule(text: text, createdBy: household.state?.me), forMe: forMe),
                    title: "\(forMe ? "只对我" : "家里")的规则：\(text)", detail: forMe ? "只存在你的手机上" : "全家都会看到并按它来")
            }
        case "propose_quiet_hours":
            struct Input: Decodable { let start: String?; let end: String? }
            let input = try JSONDecoder().decode(Input.self, from: data)
            guard HouseholdStore.shared.state != nil else { throw ToolError("还没有建立家庭") }
            var quiet: QuietHours?
            if input.start != nil || input.end != nil {
                guard let start = input.start.flatMap(QuietHours.minutes), let end = input.end.flatMap(QuietHours.minutes), start != end else {
                    throw ToolError("start和end都要是HH:mm，且不能相同")
                }
                quiet = QuietHours(start: start, end: end)
            }
            add(.quietHours(quiet), title: quiet.map { "免打扰：每天 \($0.label)" } ?? "取消免打扰",
                detail: "家人发来的提醒在这段时间不响，结束时再提醒；你自己定的提醒照常")
        case "propose_task_sharing":
            struct Input: Decodable { let id: String; let expected_revision: Int; let family: TaskFamilyArgs? }
            let input = try JSONDecoder().decode(Input.self, from: data)
            guard HouseholdStore.shared.state != nil else { throw ToolError("还没有建立家庭，任务只属于你自己") }
            guard let id = UUID(uuidString: input.id), let value = reminders.reminder(id: id) else { throw ToolError("找不到任务") }
            try requireTaskRevision(id, input.expected_revision)
            guard let family = input.family else { throw ToolError("family 不能为 null") }
            let sharing = try taskSharing(family, existing: value.sharing)
            guard sharing != value.sharing else { throw ToolError("和现在一样，不需要修改") }
            add(.taskSharing(id, sharing, expectedRevision: input.expected_revision), title: "\(value.text)：改家人设置", detail: nil)
        default: return nil
        }
        return try encode(["status": "waiting_for_user_confirmation", "saved": false, "pending_changes": pending.count] as [String: Any])
    }

    private func taskDescription(_ reminder: TimedReminder) throws -> [String: Any] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var value = try JSONSerialization.jsonObject(with: encoder.encode(reminder)) as? [String: Any] ?? [:]
        value["rule_summary"] = ReminderSchedule.ruleSummary(reminder)
        value["notification_policy"] = notificationPolicy(reminder)
        value["next_notifications"] = !reminders.remindsHere(reminder) ? [] : ReminderSchedule.preview(reminder, now: .now, limit: 6).map { ISO8601DateFormatter().string(from: $0) }
        value["sharing"] = nil
        if let family = familyDescription(reminder) { value["family"] = family }
        return value
    }

}
