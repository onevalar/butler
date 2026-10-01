import AppIntents
import Foundation

struct ButlerTaskEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "小当家任务"
    static var defaultQuery = ButlerTaskQuery()
    let id: UUID
    let title: String
    let detail: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: "\(detail)") }

    init(_ task: TimedReminder) {
        id = task.id; title = task.text
        detail = task.whenLabel + " · " + task.statusLabel + " · " + task.id.uuidString.prefix(8)
    }
}

struct ButlerTaskQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [ButlerTaskEntity] {
        let tasks = try ReminderStore.openOnDevice().tasksForSystemEntry()
        return identifiers.compactMap { id in tasks.first { $0.id == id }.map(ButlerTaskEntity.init) }
    }
    @MainActor func entities(matching string: String) async throws -> [ButlerTaskEntity] {
        try ReminderStore.openOnDevice().tasksForSystemEntry().filter { $0.text.localizedCaseInsensitiveContains(string) }
            .map(ButlerTaskEntity.init)
    }
    @MainActor func suggestedEntities() async throws -> [ButlerTaskEntity] {
        try ReminderStore.openOnDevice().tasksForSystemEntry().filter { $0.status == .active || $0.status == .paused }
            .sorted { $0.fireDate < $1.fireDate }.prefix(30).map(ButlerTaskEntity.init)
    }
}

struct TodayButlerTasksIntent: AppIntent {
    static var title: LocalizedStringResource = "查看今日小当家待办"
    static var description = IntentDescription("返回今日未完成的Butler本地任务，不读取系统日历或苹果提醒事项。")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let tasks = try ReminderStore.openOnDevice().todayTasksForSystemEntry()
        let text = tasks.isEmpty ? "今天没有未完成的小当家待办。" : "今日\(tasks.count)项待办：\n" + tasks.map { "\($0.text)（\($0.whenLabel)）" }.joined(separator: "\n")
        return .result(value: text, dialog: "\(text)")
    }
}

struct OpenButlerTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "打开小当家任务对话"
    static var supportedModes: IntentModes = .foreground
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "任务") var task: ButlerTaskEntity
    static var parameterSummary: some ParameterSummary { Summary("打开\(\.$task)的对话") }

    @MainActor func perform() async throws -> some IntentResult {
        guard try ReminderStore.openOnDevice().tasksForSystemEntry().contains(where: { $0.id == task.id }) else {
            throw ShortcutNavigation.NavigationError("任务已不存在，请重新选择")
        }
        try ShortcutNavigation.shared.open(.task(task.id))
        return .result()
    }
}

struct CompleteButlerTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "完成小当家任务"
    static var description = IntentDescription("系统确认后完成整个任务，包括停止该任务的后续提醒；不是只关闭一次通知，也不会取消独立闹钟。")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "任务") var task: ButlerTaskEntity
    static var parameterSummary: some ParameterSummary { Summary("确认完成\(\.$task)") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = ReminderStore.openOnDevice()
        guard let current = try store.tasksForSystemEntry().first(where: { $0.id == task.id }) else {
            throw ShortcutNavigation.NavigationError("任务已不存在，请重新选择")
        }
        if current.status == .completed {
            store.rescheduleAll()
            await store.waitForScheduling()
            return .result(dialog: "这个任务已经完成，本次没有重复修改。")
        }
        guard current.status == .active || current.status == .paused else { throw ShortcutNavigation.NavigationError("任务已取消，未作修改") }
        try await requestConfirmation(dialog: "完成「\(current.text)」（\(current.whenLabel)）整个任务并停止其后续提醒？这不会取消独立闹钟。")
        try Task.checkCancellation()
        try store.complete(current.id, expectedRevision: current.revision)
        await store.waitForScheduling()
        if let warning = store.scheduleWarning { return .result(dialog: "任务已完成；通知安排仍需检查：\(warning)") }
        return .result(dialog: "已完成「\(current.text)」。")
    }
}

struct RecordButlerItemsIntent: AppIntent {
    static var title: LocalizedStringResource = "交给小当家记录物品"
    static var description = IntentDescription("打开现有物品对话核对输入和提案，不直接修改库存。")
    static var supportedModes: IntentModes = .foreground
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "物品描述") var text: String
    static var parameterSummary: some ParameterSummary { Summary("交给小当家记录\(\.$text)") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try ShortcutNavigation.shared.open(.inventory(text))
        return .result(dialog: "已打开物品记录对话；核对提案并确认后才会改变库存。")
    }
}

struct ButlerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TodayButlerTasksIntent(), phrases: ["查看\(.applicationName)今日待办"], shortTitle: "今日待办", systemImageName: "checklist")
        AppShortcut(intent: OpenButlerTaskIntent(), phrases: ["打开\(.applicationName)任务对话"], shortTitle: "打开任务", systemImageName: "text.bubble")
        AppShortcut(intent: CompleteButlerTaskIntent(), phrases: ["完成\(.applicationName)任务"], shortTitle: "完成任务", systemImageName: "checkmark.circle")
        AppShortcut(intent: RecordButlerItemsIntent(), phrases: ["用\(.applicationName)记录物品"], shortTitle: "记录物品", systemImageName: "shippingbox")
    }
}
