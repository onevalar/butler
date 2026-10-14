import SwiftUI

/// The changes a tap can make to a household task's family choice.
enum TaskFamilyEdit {
    static func onlyMe(_ s: TaskSharing, me: UUID) -> TaskSharing {
        var s = s
        s.scope = .personal
        if s.assignee != me { s.assignee = nil }
        s.notify = s.notify.intersection([me])
        if s.escalateTo != me { s.escalateTo = nil; s.escalateAfter = nil }
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

/// 任务 › 家人: who can see it, who does it, who is reminded, and who wrote it down.
struct TaskFamilySection: View {
    let task: TimedReminder
    let apply: (TaskSharing) -> Void
    private var store: HouseholdStore { .shared }

    var body: some View {
        let names = store.names
        let sharing = task.sharing ?? TaskSharing(scope: .personal, createdBy: names.me)
        Section {
            TaskFamilyCardLine(sharing: sharing, disabled: false, apply: apply)
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


}

/// One review entry, with a flat editor instead of menus inside menus.
struct TaskFamilyCardLine: View {
    let sharing: TaskSharing
    let disabled: Bool
    let apply: (TaskSharing) -> Void
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "person.2").accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(TaskFamilyEditor.visibilityLabel(sharing))
                    Text("提醒" + HouseholdStore.shared.names.list(sharing.reminded))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
            .font(.subheadline).frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled)
        .accessibilityLabel("家人设置：\(HouseholdStore.shared.names.summary(sharing))")
        .sheet(isPresented: $editing) {
            TaskFamilyEditor(sharing: sharing, apply: apply)
        }
    }
}

struct TaskFamilyEditor: View {
    @State private var draft: TaskSharing
    @State private var advanced: Bool
    let apply: (TaskSharing) -> Void
    @Environment(\.dismiss) private var dismiss
    private var store: HouseholdStore { .shared }

    init(sharing: TaskSharing, apply: @escaping (TaskSharing) -> Void) {
        _draft = State(initialValue: sharing)
        _advanced = State(initialValue: !sharing.notify.isEmpty || sharing.escalateTo != nil || !sharing.hiddenFrom.isEmpty)
        self.apply = apply
    }

    static func visibilityLabel(_ s: TaskSharing) -> String {
        let names = HouseholdStore.shared.names
        switch s.scope {
        case .personal: return "只有我可见"
        case .household: return s.hiddenFrom.isEmpty ? "全家可见" : "全家可见（除\(names.list(s.hiddenFrom))）"
        case .people: return names.list(s.people.union([s.createdBy].compactMap { $0 })) + "可见"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("谁能看到") {
                    choice("只有我", selected: draft.scope == .personal) {
                        if let me = store.state?.me { draft = TaskFamilyEdit.onlyMe(draft, me: me) }
                    }
                    choice("全家", selected: draft.scope == .household && draft.hiddenFrom.isEmpty) {
                        draft = TaskFamilyEdit.everyone(draft)
                    }
                    choice("选择家人", selected: draft.scope == .people) {
                        draft.scope = .people; draft.hiddenFrom = []; draft = draft.normalized()
                    }
                    if draft.scope == .people {
                        ForEach(store.members.filter { $0.id != draft.createdBy }) { member in
                            Toggle(member.name, isOn: Binding(get: { draft.people.contains(member.id) }, set: { on in
                                if on { draft.people.insert(member.id) }
                                else {
                                    draft.people.remove(member.id)
                                    if draft.assignee == member.id { draft.assignee = nil }
                                    draft.notify.remove(member.id)
                                    if draft.escalateTo == member.id { draft.escalateTo = nil; draft.escalateAfter = nil }
                                }
                                draft = draft.normalized()
                            }))
                        }
                    }
                }
                Section {
                    Picker("交给谁", selection: Binding(get: { draft.assignee }, set: { draft = TaskFamilyEdit.assign(draft, $0) })) {
                        Text("我来处理").tag(store.state?.me)
                        Text("暂不指定").tag(UUID?.none)
                        ForEach(store.members.filter { $0.id != store.state?.me }) { member in
                            Text(member.name).tag(Optional(member.id))
                        }
                    }
                } footer: {
                    Text("默认提醒负责的人；未指定时提醒创建人。")
                }
                Section {
                    DisclosureGroup("更多提醒设置", isExpanded: $advanced) {
                        ForEach(store.members) { member in
                            Toggle("提醒\(member.name)", isOn: Binding(get: { draft.reminded.contains(member.id) }, set: { _ in
                                draft = TaskFamilyEdit.toggleNotify(draft, member.id)
                            }))
                        }
                        Picker("未处理时再提醒", selection: Binding(get: { draft.escalateTo }, set: {
                            draft = TaskFamilyEdit.escalate(draft, to: $0, after: $0 == nil ? nil : (draft.escalateAfter ?? 30))
                        })) {
                            Text("不用").tag(UUID?.none)
                            ForEach(store.members) { member in Text(member.name).tag(Optional(member.id)) }
                        }
                        if draft.escalateTo != nil {
                            Picker("等待多久", selection: Binding(get: { draft.escalateAfter ?? 30 }, set: { draft.escalateAfter = $0 })) {
                                ForEach([15, 30, 60, 120], id: \.self) { minutes in
                                    Text(HouseholdNames.duration(minutes)).tag(minutes)
                                }
                            }
                        }
                        if !draft.hiddenFrom.isEmpty {
                            Text("当前不向\(store.names.list(draft.hiddenFrom))显示。可在上方重新选择可见家人。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("家人设置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { apply(draft.normalized()); dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
