import SwiftUI

struct TaskListView: View {
    @Bindable var store: ReminderStore
    let onOpen: (UUID) -> Void
    let onCreate: () -> Void
    @State private var includeFinished = false

    private var values: [TimedReminder] {
        store.reminders.filter { includeFinished || $0.status == .active || $0.status == .paused }
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
                        HStack { Text(task.text).foregroundStyle(.primary); Spacer(); Text(task.statusLabel).font(.caption).foregroundStyle(.secondary) }
                        Text(task.whenLabel).font(.footnote).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                .glassRows()
            }
        }
        .glassList()
        .navigationTitle("任务与历史")
        .toolbar { Button("新任务", systemImage: "plus", action: onCreate) }
        .orbScrollTracking()
        .onAppear { store.rescheduleAll() }
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

    var body: some View {
        List {
            if let task = store.reminder(id: id) {
                Section {
                    Text(task.text).font(.title3.bold())
                    LabeledContent("状态", value: task.statusLabel)
                    Text(task.whenLabel)
                    LabeledContent("时区", value: task.timeZoneIdentifier)
                    if let end = task.endDate { LabeledContent("提醒截止", value: end.formatted()) }
                    if let date = task.autoCompleteAt { LabeledContent("自动标记完成", value: date.formatted()) }
                    if let warning = store.scheduleWarning { Text(warning).font(.footnote).foregroundStyle(.orange) }
                }
                .glassRows()
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
                    if task.status == .active || task.status == .paused {
                        Button("标记整个任务完成", systemImage: "checkmark.circle") { act { try store.complete(id) } }
                        if task.status == .active { Button("暂停提醒", systemImage: "pause.circle") { act { try store.pause(id) } } }
                        else { Button("恢复提醒", systemImage: "play.circle") { act { try store.resume(id) } } }
                        Button("取消任务", role: .destructive) { confirmCancel = true }
                    }
                }
                .glassRows()
                Section("做过什么") {
                    if task.activity.isEmpty { Text("还没有操作记录").foregroundStyle(.secondary) }
                    ForEach(task.activity.reversed()) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.detail)
                            Text(event.date.formatted()).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .glassRows()
                if let error { Text(error).foregroundStyle(.red) }
            } else { ContentUnavailableView("任务不存在", systemImage: "checklist", description: Text("它可能已从备份中移除。")) }
        }
        .glassList()
        .navigationTitle("任务")
        .navigationBarTitleDisplayMode(.inline)
        .orbScrollTracking()
        .onAppear { store.rescheduleAll() }
        .confirmationDialog("取消这个任务并停止后续提醒？历史会保留。", isPresented: $confirmCancel) {
            Button("取消任务", role: .destructive) { act { try store.remove(id) } }
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
                    if !item.turn.answer.isEmpty { Text(item.turn.answer).textSelection(.enabled) }
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
        .orbScrollTracking()
    }
}
