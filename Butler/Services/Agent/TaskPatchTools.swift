import Foundation

/// Patch objects reject misspelled fields instead of accepting an incomplete correction.
enum TaskPatchFields {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    static func validate(_ decoder: Decoder, allowed: Set<String>, required: Set<String> = []) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        let unknown = keys.subtracting(allowed)
        guard unknown.isEmpty else { throw ButlerTools.ToolError("不支持的修改字段：" + unknown.sorted().joined(separator: "、")) }
        let missing = required.subtracting(keys)
        guard missing.isEmpty else { throw ButlerTools.ToolError("缺少修改字段：" + missing.sorted().joined(separator: "、")) }
    }

    static func object(_ fields: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": fields, "required": fields.keys.sorted(), "additionalProperties": false]
    }

    static func nullable(_ schema: [String: Any]) -> [String: Any] {
        ["anyOf": [schema, ["type": "null"]]]
    }
}

/// A replacement of a single date/time, never an implicit replacement of repeating rules.
struct TaskSchedulePatch: Decodable {
    let time: String
    let period: ArrangementPeriod?
    let time_zone: String?

    private enum CodingKeys: String, CodingKey { case time, period, time_zone }

    init(from decoder: Decoder) throws {
        try TaskPatchFields.validate(decoder, allowed: ["time", "period", "time_zone"], required: ["time", "period"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = try container.decode(String.self, forKey: .time)
        period = try container.decodeIfPresent(ArrangementPeriod.self, forKey: .period)
        time_zone = try container.decodeIfPresent(String.self, forKey: .time_zone)
    }

    static var schema: [String: Any] {
        TaskPatchFields.object([
            "time": ["type": "string"],
            "period": ["type": ["string", "null"], "enum": ["day", "morning", "noon", "afternoon", "evening", NSNull()]],
            "time_zone": ["type": ["string", "null"]]
        ])
    }

    func applying(to original: TimedReminder, now: Date = .now) throws -> TimedReminder {
        guard original.allowsSimpleTimeEdit else {
            throw ButlerTools.ToolError("这个任务含重复、分段或截止规则；文字和家人可局部修改，修改时间请用 propose_task_plan 保留完整规则")
        }
        let identifier = time_zone ?? original.timeZoneIdentifier
        guard let zone = TimeZone(identifier: identifier) else { throw ButlerTools.ToolError("时区无效") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = period == nil ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: time), formatter.string(from: date) == time else {
            throw ButlerTools.ToolError("日期安排用 YYYY-MM-DD 和 period，定时提醒用 YYYY-MM-DD HH:mm 和 period=null")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard period != nil ? date >= calendar.startOfDay(for: now) : date > now else {
            throw ButlerTools.ToolError("所选时间已过去，请核对日期")
        }
        var result = original
        result.fireDate = date
        result.timePeriod = period
        result.timeZoneIdentifier = identifier
        result.phases = nil
        return result
    }
}

/// The outer null means keep; an explicit {value: null} means clear.
struct TaskMemberPatch: Decodable {
    let value: String?
    private enum CodingKeys: String, CodingKey { case value }

    init(from decoder: Decoder) throws {
        try TaskPatchFields.validate(decoder, allowed: ["value"], required: ["value"])
        value = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .value)
    }

    static var schema: [String: Any] { TaskPatchFields.object(["value": ["type": ["string", "null"]]]) }
}

struct TaskEscalationPatch: Decodable {
    let person: String?
    let after_minutes: Int?
    private enum CodingKeys: String, CodingKey { case person, after_minutes }

    init(from decoder: Decoder) throws {
        try TaskPatchFields.validate(decoder, allowed: ["person", "after_minutes"], required: ["person", "after_minutes"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        person = try container.decodeIfPresent(String.self, forKey: .person)
        after_minutes = try container.decodeIfPresent(Int.self, forKey: .after_minutes)
    }

    static var schema: [String: Any] {
        TaskPatchFields.object([
            "person": ["type": ["string", "null"]],
            "after_minutes": ["type": ["integer", "null"], "minimum": 5, "maximum": 1440]
        ])
    }
}

/// Family edits preserve every unspecified choice and never silently widen visibility.
struct TaskFamilyPatch: Decodable {
    let visibility: TaskSharing.Scope?
    let people: [String]?
    let hidden_from: [String]?
    let assignee: TaskMemberPatch?
    let notify: [String]?
    let escalation: TaskEscalationPatch?

    private enum CodingKeys: String, CodingKey { case visibility, people, hidden_from, assignee, notify, escalation }

    init(from decoder: Decoder) throws {
        try TaskPatchFields.validate(decoder, allowed: ["visibility", "people", "hidden_from", "assignee", "notify", "escalation"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visibility = try container.decodeIfPresent(TaskSharing.Scope.self, forKey: .visibility)
        people = try container.decodeIfPresent([String].self, forKey: .people)
        hidden_from = try container.decodeIfPresent([String].self, forKey: .hidden_from)
        assignee = try container.decodeIfPresent(TaskMemberPatch.self, forKey: .assignee)
        notify = try container.decodeIfPresent([String].self, forKey: .notify)
        escalation = try container.decodeIfPresent(TaskEscalationPatch.self, forKey: .escalation)
    }

    static var schema: [String: Any] {
        let names: [String: Any] = ["type": ["array", "null"], "maxItems": 10, "items": ["type": "string"]]
        return TaskPatchFields.object([
            "visibility": ["type": ["string", "null"], "enum": ["personal", "household", "people", NSNull()]],
            "people": names, "hidden_from": names, "notify": names,
            "assignee": TaskPatchFields.nullable(TaskMemberPatch.schema),
            "escalation": TaskPatchFields.nullable(TaskEscalationPatch.schema)
        ])
    }

    func applying(to original: TaskSharing?, household: HouseholdStore) throws -> TaskSharing? {
        guard visibility != nil || people != nil || hidden_from != nil || assignee != nil || notify != nil || escalation != nil else {
            return original
        }
        guard let state = household.state else { throw ButlerTools.ToolError("还没有建立家庭；保留原家人设置请传 family=null") }
        var result = original ?? TaskSharing(scope: .personal, createdBy: state.me)
        func member(_ value: String) throws -> UUID {
            guard let member = household.member(named: value) else {
                throw ButlerTools.ToolError("无法唯一确定“\(value)”，请读取当前家庭成员并使用成员 id")
            }
            return member.id
        }
        func members(_ values: [String]) throws -> Set<UUID> {
            guard values.count <= 10 else { throw ButlerTools.ToolError("家人字段最多填写 10 人") }
            return Set(try values.map(member))
        }
        if let visibility { result.scope = visibility }
        if let people { result.people = try members(people) }
        if let hidden_from { result.hiddenFrom = try members(hidden_from) }
        if let assignee { result.assignee = try assignee.value.map(member) }
        if let notify { result.notify = try members(notify) }
        if let escalation {
            if let person = escalation.person, let minutes = escalation.after_minutes, (5...1440).contains(minutes) {
                result.escalateTo = try member(person)
                result.escalateAfter = minutes
            } else if escalation.person == nil, escalation.after_minutes == nil {
                result.escalateTo = nil
                result.escalateAfter = nil
            } else {
                throw ButlerTools.ToolError("后续提醒需同时提供 person 和 5–1440 的 after_minutes；两项都为 null 才表示清除")
            }
        }
        guard !result.hiddenFrom.contains(state.me) else { throw ButlerTools.ToolError("不能把当前用户排除在任务可见范围之外") }
        if result.scope == .people, result.people.subtracting([result.createdBy].compactMap { $0 }).isEmpty,
           result.assignee == nil, result.notify.isEmpty {
            throw ButlerTools.ToolError("只给指定家人看的任务需要明确 people")
        }
        guard result == result.normalized() else {
            throw ButlerTools.ToolError("家人设置存在冲突，未自动改变其他字段。负责人、提醒对象必须在可见范围内；请根据用户意图明确修改 visibility/people/hidden_from，或明确清除 assignee/notify/escalation。未指定的字段会保留")
        }
        return result
    }
}

struct TaskUpdatePatch: Decodable {
    let text: String?
    let schedule: TaskSchedulePatch?
    let family: TaskFamilyPatch?
    private enum CodingKeys: String, CodingKey { case text, schedule, family }

    init(text: String?, schedule: TaskSchedulePatch?, family: TaskFamilyPatch?) {
        self.text = text
        self.schedule = schedule
        self.family = family
    }

    init(from decoder: Decoder) throws {
        try TaskPatchFields.validate(decoder, allowed: ["text", "schedule", "family"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        schedule = try container.decodeIfPresent(TaskSchedulePatch.self, forKey: .schedule)
        family = try container.decodeIfPresent(TaskFamilyPatch.self, forKey: .family)
    }

    static var fields: [String: Any] {
        ["text": ["type": ["string", "null"]],
         "schedule": TaskPatchFields.nullable(TaskSchedulePatch.schema),
         "family": TaskPatchFields.nullable(TaskFamilyPatch.schema)]
    }

    func applying(to original: TimedReminder, household: HouseholdStore, now: Date = .now) throws -> TimedReminder {
        guard original.status == .active || original.status == .paused else {
            throw ButlerTools.ToolError("任务已结束，请先重新开启；仅修改已结束任务的共享设置可使用 propose_task_sharing")
        }
        var result = original
        if let text { result.text = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let schedule { result = try schedule.applying(to: result, now: now) }
        if let family { result.sharing = try family.applying(to: result.sharing, household: household) }
        try ReminderSchedule.validate(result)
        guard result != original else { throw ButlerTools.ToolError("和现在一样，不需要修改") }
        return result
    }
}

extension ButlerTools {
    /// Recheck the household at the write boundary. A text/time edit that keeps the old
    /// sharing exactly is allowed even when those old member records are no longer available.
    func validateTaskFamilyConfirmation(_ proposed: TaskSharing?, replacing existing: TaskSharing? = nil) throws {
        guard proposed != existing else { return }
        guard let state = household.state else {
            throw ToolError("家庭已退出或发生变化，请重新读取后确认家人设置")
        }
        guard let proposed else { return }
        let creator = existing?.createdBy ?? state.me
        guard proposed.createdBy == creator, household.member(creator) != nil else {
            throw ToolError("这张卡片所属的家庭或创建者已变化，请重新提出修改")
        }
        let referenced = proposed.people.union(proposed.hiddenFrom).union(proposed.notify)
            .union([proposed.assignee, proposed.escalateTo].compactMap { $0 })
        guard referenced.allSatisfy({ household.member($0) != nil }) else {
            throw ToolError("卡片中的家人已不在当前家庭，请重新选择后确认")
        }
        guard proposed == proposed.normalized() else {
            throw ToolError("卡片中的家人设置存在冲突，请重新检查可见范围和提醒对象")
        }
    }

    static var taskUpdateSchema: [String: Any] {
        var fields = TaskUpdatePatch.fields
        fields["id"] = ["type": "string"]
        fields["expected_revision"] = ["type": "integer"]
        return ["type": "function", "name": "propose_task_update", "strict": true,
                "description": "局部修改已有任务，确认后生效。先 get_tasks 取得真实 id/revision。只传用户改变的字段：text/schedule/family 为 null 均保留。schedule 替换单次时间：time=YYYY-MM-DD、period=day/morning/noon/afternoon/evening，或 time=YYYY-MM-DD HH:mm、period=null；time_zone=null 沿用，不追问模糊时间。复杂重复/分段任务也可改文字和家人，但改规则仍用 propose_task_plan。family 内 null 均保留；people/hidden_from/notify 用 [] 清空（notify=[] 恢复默认提醒负责人或创建者）；assignee={value:成员id} 设置，{value:null} 清除；escalation={person:成员id,after_minutes:分钟} 设置，两项都 null 清除。只改变明确指定的字段，不会为了分配任务暗中扩大共享范围，冲突会返回错误。保留任务 id、暂停状态及其他原有条件。",
                "parameters": TaskPatchFields.object(fields)]
    }

    func proposeTaskUpdate(data: Data) throws -> String {
        struct Input: Decodable {
            let id: UUID
            let expected_revision: Int
            let patch: TaskUpdatePatch
            private enum CodingKeys: String, CodingKey { case id, expected_revision, text, schedule, family }

            init(from decoder: Decoder) throws {
                try TaskPatchFields.validate(decoder, allowed: ["id", "expected_revision", "text", "schedule", "family"])
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(UUID.self, forKey: .id)
                expected_revision = try container.decode(Int.self, forKey: .expected_revision)
                patch = TaskUpdatePatch(text: try container.decodeIfPresent(String.self, forKey: .text),
                                        schedule: try container.decodeIfPresent(TaskSchedulePatch.self, forKey: .schedule),
                                        family: try container.decodeIfPresent(TaskFamilyPatch.self, forKey: .family))
            }
        }
        let input = try JSONDecoder().decode(Input.self, from: data)
        try requireTaskRevision(input.id, input.expected_revision)
        guard let existing = reminders.reminder(id: input.id) else { throw ToolError("找不到任务") }
        let revised = try input.patch.applying(to: existing, household: household)
        let description = try taskDescription(revised)
        add(.taskPlan(revised, expectedRevision: input.expected_revision), title: revised.text,
            detail: ReminderSchedule.friendlySummary(revised))
        return try encode(["status": "waiting_for_user_confirmation", "saved": false, "task": description] as [String: Any])
    }
}
