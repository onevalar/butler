import SwiftUI

struct TaskListView: View {
    @Bindable var store: ReminderStore
    let onOpen: (UUID) -> Void
    let onCreate: () -> Void
    @State private var includeFinished = true
    @State private var searchText = ""
    @State private var deleting: TimedReminder?
    @State private var deleteError: String?

    private var values: [TimedReminder] {
        store.reminders.filter { (includeFinished || $0.status == .active || $0.status == .paused)
            && (searchText.isEmpty || $0.text.localizedCaseInsensitiveContains(searchText)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        List {
            Toggle("显示已完成和已取消", isOn: $includeFinished).glassRows()
            if let warning = store.scheduleWarning {
                Label(warning, systemImage: "exclamationmark.bubble").font(.footnote).foregroundStyle(.orange).glassRows()
            }
            if values.isEmpty { Text("还没有任务，告诉管家你想安排什么。").foregroundStyle(.secondary).glassRows() }
            ForEach(values) { task in
                Button { onOpen(task.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(task.text).foregroundStyle(.primary)
                            Spacer()
                            Text(HouseholdStore.shared.names.completedBy(task) ?? task.statusLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Text([task.whenLabel, HouseholdStore.shared.names.rowLabel(task.sharing)].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                .glassRows()
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("删除", role: .destructive) { deleting = task }
                }
                .contextMenu {
                    Button("删除任务", systemImage: "trash", role: .destructive) { deleting = task }
                }
            }
        }
        .glassList()
        .navigationTitle("任务与历史")
        .searchable(text: $searchText, prompt: "搜索任务与历史")
        .toolbar { Button("新任务", systemImage: "plus", action: onCreate) }
        .onAppear { store.rescheduleAll() }
        .confirmationDialog("永久删除这个任务？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { task in
            Button("删除任务", role: .destructive) {
                do { try store.delete(task.id, expectedRevision: task.revision) }
                catch { deleteError = error.localizedDescription }
                deleting = nil
            }
            Button("保留任务", role: .cancel) { deleting = nil }
        } message: { task in
            Text("「\(task.text)」及其操作记录将被永久删除，后续提醒停止，对话记录保留。此操作不能撤销。")
        }
        .alert("未能删除", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("知道了") { deleteError = nil }
        } message: { Text(deleteError ?? "") }
    }
}

struct TaskDetailView: View {
    let id: UUID
    @Bindable var store: ReminderStore
    let sessions: ChatSessions?
    let onChat: () -> Void
    let onOpenScope: (ChatScope) -> Void
    @State private var error: String?
    @State private var confirmCancel = false
    @State private var deleting: TimedReminder?
    @Environment(\.dismiss) private var dismiss

    private func quickButton(_ title: String, _ symbol: String, primary: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                Text(title).font(.footnote.weight(.medium))
            }
            .foregroundStyle(primary ? Color(.systemBackground) : Color.primary)
            .frame(maxWidth: .infinity).frame(height: 66)
            .background(primary ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .glassEffect(primary ? .identity : .regular.interactive(), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        List {
            if let task = store.reminder(id: id) {
                Section {
                    Text(task.text).font(.title3.bold())
                    LabeledContent("状态", value: [task.statusLabel, HouseholdStore.shared.names.completedBy(task)]
                        .compactMap { $0 }.joined(separator: " · "))
                    Text(task.whenLabel)
                    if task.timeZoneIdentifier != TimeZone.current.identifier {
                        LabeledContent("时区", value: task.timeZoneIdentifier)
                    }
                    if let end = task.endDate { LabeledContent("提醒截止", value: end.formatted()) }
                    if let date = task.autoCompleteAt { LabeledContent("自动标记完成", value: date.formatted()) }
                    if let warning = store.scheduleWarning { Text(warning).font(.footnote).foregroundStyle(.orange) }
                }
                .glassRows()
                // The things people come here to do, right under the title instead of at the bottom.
                if task.status == .active || task.status == .paused {
                    Section {
                        HStack(spacing: 10) {
                            quickButton("完成", "checkmark", primary: true) { act { try store.complete(id) } }
                            if task.status == .active {
                                quickButton("暂停提醒", "pause") { act { try store.pause(id) } }
                            } else {
                                quickButton("恢复提醒", "play") { act { try store.resume(id) } }
                            }
                            quickButton("取消任务", "xmark") { confirmCancel = true }
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                }
                if HouseholdStore.shared.state != nil {
                    TaskFamilySection(task: task) { sharing in
                        act { try store.setSharing(id, sharing, detail: "改为" + HouseholdStore.shared.names.thirdPerson.summary(sharing)) }
                    }
                }
                Section("提醒规则预览") {
                    DisclosureGroup("完整提醒规则") {
                        Text(ReminderSchedule.ruleSummary(task))
                            .font(.subheadline)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                    let dates = ReminderSchedule.preview(task, now: .now, limit: 8)
                    if dates.isEmpty { Text(emptyScheduleMessage(task)).foregroundStyle(.secondary) }
                    ForEach(dates, id: \.self) { date in Text(date.formatted(date: .abbreviated, time: .shortened)) }
                    if !dates.isEmpty { Text("按当前规则计算；实际通知还受系统授权和排程容量影响。").font(.footnote).foregroundStyle(.secondary) }
                }
                .glassRows()
                Section {
                    Button("和管家讨论这个任务", systemImage: "bubble.left.and.bubble.right", action: onChat)
                    NavigationLink("相关对话") { RelatedConversationView(scope: .task(id), sessions: sessions, onOpen: onOpenScope) }
                    if task.status == .completed || task.status == .cancelled {
                        Button("重新标记为未完成", systemImage: "arrow.uturn.backward") {
                            act { try store.reopen(id) }
                        }
                        Text("保留之前的操作记录，恢复原有提醒规则；已过期的自动完成时间会清除。提醒时间已过的任务仍需重新安排。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .glassRows()
                Section("做过什么") {
                    if task.activity.isEmpty { Text("还没有操作记录").foregroundStyle(.secondary) }
                    ForEach(task.activity.reversed()) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.detail)
                            Text([HouseholdStore.shared.names.name(event.by).map { $0 == "你" ? "我" : $0 }, event.date.formatted()]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .glassRows()
                Section {
                    Button("删除任务", systemImage: "trash", role: .destructive) { deleting = task }
                }
                .glassRows()
                if let error { Text(error).foregroundStyle(.red) }
            } else { ContentUnavailableView("任务不存在", systemImage: "checklist", description: Text("它可能已从备份中移除。")) }
        }
        .glassList()
        .navigationTitle("任务")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.rescheduleAll() }
        .confirmationDialog("取消这个任务并停止后续提醒？历史会保留。", isPresented: $confirmCancel) {
            Button("取消任务", role: .destructive) { act { try store.remove(id) } }
        }
        .confirmationDialog("永久删除这个任务？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { task in
            Button("删除任务", role: .destructive) {
                do {
                    try store.delete(task.id, expectedRevision: task.revision)
                    deleting = nil
                    dismiss()
                } catch { self.error = error.localizedDescription; deleting = nil }
            }
            Button("保留任务", role: .cancel) { deleting = nil }
        } message: { task in
            Text("「\(task.text)」及其操作记录将被永久删除，后续提醒停止，对话记录保留。此操作不能撤销。")
        }
    }

    private func act(_ body: () throws -> Void) {
        do { try body(); error = nil } catch { self.error = error.localizedDescription }
    }

    private func emptyScheduleMessage(_ task: TimedReminder) -> String {
        switch task.status {
        case .paused: "已暂停，恢复后继续安排。"
        case .completed: "任务已完成，后续提醒已停止。"
        case .cancelled: "任务已取消，历史记录会保留。"
        case .active: "没有后续提醒；提醒结束不代表事情已经完成。"
        }
    }
}

struct RelatedConversationView: View {
    let scope: ChatScope
    let sessions: ChatSessions?
    let onOpen: (ChatScope) -> Void

    var body: some View {
        List {
            Button("继续这个对象的对话", systemImage: "bubble.left") { onOpen(scope) }.glassRows()
            let turns = sessions?.relatedTurns(for: scope) ?? []
            if turns.isEmpty { Text("这里会保留这个对象的对话，以及其他会话中关联到它的内容。").foregroundStyle(.secondary).glassRows() }
            ForEach(turns.reversed()) { item in
                Section {
                    Text(item.turn.question).font(.body.bold())
                    if !item.turn.answer.isEmpty { ChatMarkdownText(text: item.turn.answer) }
                    ForEach(Array(item.turn.receipts.enumerated()), id: \.offset) { _, receipt in Text(receipt).font(.footnote) }
                    Button("打开来源对话") { onOpen(item.scope) }
                } header: {
                    Text("\(item.scope.title) · \(item.turn.date.formatted())")
                }
                .glassRows()
            }
        }
        .glassList()
        .navigationTitle("相关对话")
        .navigationBarTitleDisplayMode(.inline)
    }
}
