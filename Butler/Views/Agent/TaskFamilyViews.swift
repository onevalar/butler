import SwiftUI

/// The changes a tap can make to a household task's family choice.
enum TaskFamilyEdit {
    static func onlyMe(_ s: TaskSharing, me: UUID) -> TaskSharing {
        var s = s
        s.scope = .personal
        if s.assignee != me { s.assignee = nil }
        s.notify = s.notify.intersection([me])
        return s.normalized()
    }

    static func everyone(_ s: TaskSharing) -> TaskSharing {
        var s = s
        s.scope = .household
        s.hiddenFrom = []
        return s.normalized()
    }

    static func toggleHidden(_ s: TaskSharing, _ member: UUID) -> TaskSharing {
        var s = s
        if s.scope != .household { s.scope = .household; s.hiddenFrom = [] }
        if s.hiddenFrom.contains(member) { s.hiddenFrom.remove(member) } else { s.hiddenFrom.insert(member) }
        if s.assignee == member { s.assignee = nil }
        s.notify.remove(member)
        return s.normalized()
    }

    static func togglePerson(_ s: TaskSharing, _ member: UUID) -> TaskSharing {
        var s = s
        if s.scope != .people { s.scope = .people; s.people = [] }
        if s.people.contains(member) {
            s.people.remove(member)
            if s.assignee == member { s.assignee = nil }
            s.notify.remove(member)
        } else { s.people.insert(member) }
        if s.people.isEmpty, s.assignee == nil, s.notify.isEmpty { s.scope = .personal }
        return s.normalized()
    }

    static func assign(_ s: TaskSharing, _ member: UUID?) -> TaskSharing {
        var s = s
        s.assignee = member
        return s.normalized()
    }

    static func toggleNotify(_ s: TaskSharing, _ member: UUID) -> TaskSharing {
        var s = s
        if s.notify.isEmpty { s.notify = s.reminded }
        if s.notify.contains(member) { s.notify.remove(member) } else { s.notify.insert(member) }
        if s.notify == Set([s.assignee ?? s.createdBy].compactMap { $0 }) { s.notify = [] }
        return s.normalized()
    }

    static func escalate(_ s: TaskSharing, to member: UUID?, after minutes: Int?) -> TaskSharing {
        var s = s
        s.escalateTo = member
        s.escalateAfter = member == nil ? nil : minutes
        return s.normalized()
    }

    static func notifyDefault(_ s: TaskSharing) -> TaskSharing {
        var s = s
        s.notify = []
        return s.normalized()
    }
}

/// The menu items for each of the three choices; the same on the task page and on the confirm card.
struct TaskFamilyMenus {
    let sharing: TaskSharing
    let apply: (TaskSharing) -> Void
    private var store: HouseholdStore { .shared }
    private var me: UUID? { store.state?.me }
    private var others: [HouseholdMember] { store.members.filter { $0.id != me } }

    private func mark(_ on: Bool, _ symbol: String) -> String { on ? "checkmark" : symbol }

    @ViewBuilder var visibility: some View {
        if let me {
            Button { apply(TaskFamilyEdit.onlyMe(sharing, me: me)) } label: {
                Label("只有我", systemImage: mark(sharing.scope == .personal, "lock"))
            }
            Button { apply(TaskFamilyEdit.everyone(sharing)) } label: {
                Label("全家", systemImage: mark(sharing.scope == .household && sharing.hiddenFrom.isEmpty, "house"))
            }
            if !others.isEmpty {
                Menu("只给…看") {
                    ForEach(others) { member in
                        Button { apply(TaskFamilyEdit.togglePerson(sharing, member.id)) } label: {
                            Label(member.name, systemImage: mark(sharing.scope == .people && sharing.people.contains(member.id), "person"))
                        }
                    }
                }
                Menu("全家，但不让…看到") {
                    ForEach(others) { member in
                        Button { apply(TaskFamilyEdit.toggleHidden(sharing, member.id)) } label: {
                            Label(member.name, systemImage: mark(sharing.scope == .household && sharing.hiddenFrom.contains(member.id), "eye.slash"))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder var assignee: some View {
        Button { apply(TaskFamilyEdit.assign(sharing, nil)) } label: {
            Label("没人负责", systemImage: mark(sharing.assignee == nil, "minus"))
        }
        ForEach(store.members) { member in
            Button { apply(TaskFamilyEdit.assign(sharing, member.id)) } label: {
                Label(member.id == me ? "我" : member.name, systemImage: mark(sharing.assignee == member.id, "person"))
            }
        }
    }

    @ViewBuilder var escalation: some View {
        Button { apply(TaskFamilyEdit.escalate(sharing, to: nil, after: nil)) } label: {
            Label("不用再提醒别人", systemImage: mark(sharing.escalateTo == nil, "minus"))
        }
        ForEach(store.members) { member in
            Menu(member.id == me ? "提醒我" : "提醒\(member.name)") {
                ForEach([15, 30, 60, 120], id: \.self) { minutes in
                    Button { apply(TaskFamilyEdit.escalate(sharing, to: member.id, after: minutes)) } label: {
                        Label("过 \(HouseholdNames.duration(minutes))还没完成",
                              systemImage: mark(sharing.escalateTo == member.id && sharing.escalateAfter == minutes, "clock"))
                    }
                }
            }
        }
    }

    @ViewBuilder var notify: some View {
        Button { apply(TaskFamilyEdit.notifyDefault(sharing)) } label: {
            Label(sharing.assignee == nil ? "记下的人" : "负责的人", systemImage: mark(sharing.notify.isEmpty, "person.crop.circle.badge.checkmark"))
        }
        ForEach(store.members) { member in
            Button { apply(TaskFamilyEdit.toggleNotify(sharing, member.id)) } label: {
                Label(member.id == me ? "我" : member.name, systemImage: mark(!sharing.notify.isEmpty && sharing.notify.contains(member.id), "bell"))
            }
        }
    }
}

/// 任务 › 家人: who can see it, who does it, who is reminded, and who wrote it down.
struct TaskFamilySection: View {
    let task: TimedReminder
    let apply: (TaskSharing) -> Void
    private var store: HouseholdStore { .shared }

    var body: some View {
        let names = store.names
        let sharing = task.sharing ?? TaskSharing(scope: .personal, createdBy: names.me)
        let menus = TaskFamilyMenus(sharing: sharing, apply: apply)
        Section {
            Menu { menus.visibility } label: { row("谁能看到", visibility(sharing, names)) }
            Menu { menus.assignee } label: { row("谁负责", names.name(sharing.assignee).map { $0 == "你" ? "我" : $0 } ?? "没人负责") }
            Menu { menus.notify } label: { row("到点提醒", reminded(sharing, names)) }
            if task.repeats == .none, task.phases == nil {
                Menu { menus.escalation } label: { row("没人处理时", escalation(sharing, names)) }
            }
            if let creator = store.member(sharing.createdBy), creator.id != names.me {
                HStack(spacing: 8) {
                    Text("谁记的")
                    Spacer(minLength: 12)
                    MemberBadge(member: creator, size: 22)
                    Text(creator.name).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("家人")
        } footer: {
            Text("到点只提醒上面的人；有人完成后，其他人不会再被提醒。")
        }
        .glassRows()
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(.secondary).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func visibility(_ s: TaskSharing, _ names: HouseholdNames) -> String {
        switch s.scope {
        case .personal: return "只有我"
        case .household: return s.hiddenFrom.isEmpty ? "全家" : "全家（不给\(names.list(s.hiddenFrom))看）"
        case .people:
            let others = s.people.union([s.createdBy].compactMap { $0 }).subtracting([names.me].compactMap { $0 })
            return others.isEmpty ? "只有我" : "我和\(names.list(others))"
        }
    }

    private func escalation(_ s: TaskSharing, _ names: HouseholdNames) -> String {
        guard let next = s.escalateTo, let after = s.escalateAfter else { return "不用" }
        let who = names.name(next).map { $0 == "你" ? "我" : $0 } ?? "家人"
        return "\(HouseholdNames.duration(after))后提醒\(who)"
    }

    private func reminded(_ s: TaskSharing, _ names: HouseholdNames) -> String {
        s.reminded.map { names.name($0) == "你" ? "我" : (names.name($0) ?? "家人") }.sorted().joined(separator: "、")
    }
}

/// On the confirm card: the decision in one line, tappable to change before confirming.
struct TaskFamilyCardLine: View {
    let sharing: TaskSharing
    let disabled: Bool
    let apply: (TaskSharing) -> Void

    var body: some View {
        let menus = TaskFamilyMenus(sharing: sharing, apply: apply)
        Menu {
            Menu("谁能看到") { menus.visibility }
            Menu("谁负责") { menus.assignee }
            Menu("到点提醒") { menus.notify }
            Menu("没人处理时") { menus.escalation }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.2")
                Text(HouseholdStore.shared.names.summary(sharing))
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline)
            .foregroundStyle(.tint)
            .contentShape(Rectangle())
        }
        .disabled(disabled)
        .accessibilityLabel("修改家人设置：\(HouseholdStore.shared.names.summary(sharing))")
    }
}
