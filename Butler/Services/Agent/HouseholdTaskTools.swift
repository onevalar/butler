import Foundation

/// The family part of a task proposal: who can see it, who is responsible, who is reminded.
struct TaskFamilyArgs: Decodable, Equatable {
    var visibility: String
    var people: [String]
    var hidden_from: [String]
    var assignee: String?
    var notify: [String]
    var escalate_to: String?
    var escalate_after_minutes: Int?

    static let schema: [String: Any] = {
        let names: [String: Any] = ["type": "array", "maxItems": 10, "items": ["type": "string"]]
        let fields: [String: Any] = [
            "visibility": ["type": "string", "enum": ["personal", "household", "people"]],
            "people": names, "hidden_from": names,
            "assignee": ["type": ["string", "null"]], "notify": names,
            "escalate_to": ["type": ["string", "null"]],
            "escalate_after_minutes": ["type": ["integer", "null"], "minimum": 5, "maximum": 1440],
        ]
        return ["anyOf": [["type": "object", "properties": fields, "required": fields.keys.sorted(),
                           "additionalProperties": false], ["type": "null"]]]
    }()

    static let schemaJSON: String = {
        let data = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data("{\"type\":\"null\"}".utf8)
        return String(decoding: data, as: UTF8.self)
    }()

    static let guidance = "family：仅当current_context有household时填写，否则null。visibility：personal只有我、household全家、people只给people里的人；hidden_from全家可见但不让这些人看到；assignee谁负责（家人称呼，null没人负责）；notify到点提醒谁（空数组=负责的人，没人负责就提醒创建的人）；escalate_to和escalate_after_minutes：一次性任务到点后这么久还没人完成，再提醒这个人（用户或家庭规则要求时才填，否则null）。先按用户这句话，其次已记住的家庭规则，再由你按内容判断：家务、采购、缴费、孩子和老人的事通常全家可见；交给别人做的事给对方看并提醒对方；看病、体检、私人约会、礼物惊喜等私事只有我。只有涉及隐私又真拿不准时才问一句是/否，其他情况直接给出判断，用户会在卡片上改。修改已有任务的范围用propose_task_sharing。"
}

extension ButlerTools {
    /// Turns the model's family choice into the task's sharing. Outside a household there is none.
    func taskSharing(_ family: TaskFamilyArgs?, existing: TaskSharing?) throws -> TaskSharing? {
        let household = HouseholdStore.shared
        guard let state = household.state else {
            if let family, family.visibility != "personal" || family.assignee != nil || !family.notify.isEmpty {
                throw ToolError("还没有建立家庭，任务只属于你自己；family 传 null")
            }
            return existing
        }
        guard let family else { return existing ?? TaskSharing(scope: .personal, createdBy: state.me) }
        func members(_ names: [String]) throws -> Set<UUID> {
            Set(try names.map { name in
                guard let member = household.member(named: name) else {
                    throw ToolError("家里没有“\(name)”。家人：" + household.members.map(\.name).joined(separator: "、"))
                }
                return member.id
            })
        }
        guard let scope = TaskSharing.Scope(rawValue: family.visibility) else { throw ToolError("visibility 无效") }
        var sharing = TaskSharing(scope: scope, createdBy: existing?.createdBy ?? state.me)
        sharing.people = try members(family.people)
        sharing.hiddenFrom = try members(family.hidden_from).subtracting([state.me])
        sharing.assignee = try family.assignee.flatMap { try members([$0]).first }
        sharing.notify = try members(family.notify)
        sharing.escalateTo = try family.escalate_to.flatMap { try members([$0]).first }
        sharing.escalateAfter = family.escalate_after_minutes
        if scope == .people, sharing.people.subtracting([state.me]).isEmpty, sharing.assignee == nil, sharing.notify.isEmpty {
            throw ToolError("visibility=people 需要在 people 里写给谁看")
        }
        return sharing.normalized()
    }


    /// What the model reads about a task's family side.
    func familyDescription(_ task: TimedReminder) -> [String: Any]? {
        let names = HouseholdStore.shared.names
        guard names.isActive else { return nil }
        let sharing = task.sharing
        var value: [String: Any] = ["summary": names.summary(sharing)]
        value["created_by"] = names.name(sharing?.createdBy) ?? NSNull()
        value["assignee"] = names.name(sharing?.assignee) ?? NSNull()
        value["reminded"] = sharing.map { names.list($0.reminded) } ?? "你"
        if let done = task.activity.last(where: { $0.kind == "completed" }) {
            value["completed_by"] = names.name(done.by) ?? NSNull()
        }
        return value
    }

    /// Who is in the household, who is talking, and the rules the butler follows.
    func householdContext() -> [String: Any]? {
        let household = HouseholdStore.shared
        guard let state = household.state else { return nil }
        let rule: (HouseholdRule, String) -> [String: Any] = { value, scope in
            ["id": value.id.uuidString, "text": value.text, "applies_to": scope,
             "added_by": household.names.name(value.createdBy) ?? NSNull()]
        }
        return ["name": state.name, "me": household.me?.name ?? "我",
                "members": household.members.map { member -> [String: Any] in
                    ["name": member.name, "is_me": member.id == state.me, "quiet_hours": member.quiet?.label ?? NSNull()]
                },
                "rules": household.rules.map { rule($0, "household") } + household.myRules.map { rule($0, "me") },
                "rule_order": "这句话说的 > 只对我的规则 > 家里的规则 > 你按内容判断 > 保守默认（任务只有我，物品全家）"]
    }

    func notificationPolicy(_ task: TimedReminder) -> String {
        if reminders.remindsHere(task) { return "由本机按规则尽力安排，实际送达依赖系统" }
        if let sharing = task.sharing, sharing.isShared, HouseholdStore.shared.state != nil {
            return "家庭任务，到点提醒\(HouseholdStore.shared.names.list(sharing.reminded))的手机，本机不提醒"
        }
        return "从其他设备同步，仅显示任务，本机不新增通知"
    }
}

extension PendingChange {
    /// For a task proposal in a household: the family choice the card shows and lets the owner change.
    var taskFamily: TaskSharing? {
        guard let state = HouseholdStore.shared.state else { return nil }
        switch kind {
        case .reminder(let task), .taskPlan(let task, _): return task.sharing ?? TaskSharing(scope: .personal, createdBy: state.me)
        case .taskSharing(_, let sharing, _): return sharing ?? TaskSharing(scope: .personal, createdBy: state.me)
        default: return nil
        }
    }
}

extension ButlerTools {
    /// The owner changed the family choice on the card itself; the proposal keeps its place and stays unconfirmed.
    @discardableResult
    func reviseFamily(of changeID: UUID, to sharing: TaskSharing) -> PendingChange? {
        guard let index = pending.firstIndex(where: { $0.id == changeID }) else { return nil }
        let old = pending[index]
        let sharing = sharing.normalized()
        let kind: PendingChange.Kind
        let detail: String?
        switch old.kind {
        case .reminder(var task):
            task.sharing = sharing
            kind = .reminder(task); detail = task.whenLabel
        case .taskPlan(var task, let revision):
            task.sharing = sharing
            kind = .taskPlan(task, expectedRevision: revision); detail = ReminderSchedule.friendlySummary(task)
        case .taskSharing(let id, _, let revision):
            kind = .taskSharing(id, sharing, expectedRevision: revision); detail = nil
        default: return nil
        }
        var revised = PendingChange(kind: kind, title: old.title, detail: detail, check: old.check, requestTurnID: old.requestTurnID)
        revised.id = old.id
        var next = pending
        next[index] = revised
        restorePending(next)
        return revised
    }
}
