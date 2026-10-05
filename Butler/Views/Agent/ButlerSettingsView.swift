import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// 管家与设置: the butler (who it is, what it knows, its diary) above the settings, which are grouped
/// into a few rows; each row opens its own page with the same controls as before.
struct ButlerSettingsView: View {
    @Bindable var chat: ButlerChat
    /// Shown as a sheet from the conversation: add a 完成 button.
    var showsDone = false
    var hasOtherWork = false
    var diaryTurns: [ChatTurn]? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(CalendarFeed.self) private var calendarFeed: CalendarFeed?
    @Environment(\.modelContext) private var modelContext
    @State private var confirmClear = false
    @State private var showVoiceTrial = false
    @AppStorage("expiryWarningDays") private var leadDays = 2
    @AppStorage(SpeechRecognitionSettings.providerKey) private var speechProvider = SpeechRecognitionProvider.apple.rawValue
    @AppStorage("reminderMinutes") private var reminderMinutes = 9 * 60
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .mist
    @Query(filter: #Predicate<InventoryLot> { $0.stateRawValue == "active" }) private var activeLots: [InventoryLot]

    var body: some View {
        Form {
            Section {
                UnderstandingCard(chat: chat, editor: ProfileSettingsPage(chat: chat))
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Section {
                DiaryStrip(turns: diaryTurns ?? chat.turns)
            } header: {
                Text("管家日记").font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Section {
                NavigationLink { ProfileSettingsPage(chat: chat) } label: {
                    LabeledContent("关于我和家里", value: chat.profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未填写" : "已填写")
                }
                NavigationLink { MemoriesView(chat: chat) } label: {
                    LabeledContent("习惯和偏好", value: "\(chat.tools?.notes.records.count ?? 0) 条")
                }
                NavigationLink { ModelSettingsPage(chat: chat, hasOtherWork: hasOtherWork) } label: {
                    LabeledContent("对话模型", value: chat.connection.isLoggedIn ? "GPT-6 Sol" : "未登录")
                }
                NavigationLink { ScreenshotSetupView() } label: {
                    Label("从其他 App 采集", systemImage: "camera.viewfinder")
                }
                NavigationLink { SpeechRecognitionSettingsView() } label: {
                    LabeledContent("语音识别", value: (SpeechRecognitionProvider(rawValue: speechProvider) ?? .apple).title)
                }
                NavigationLink { JevSettingsPage(chat: chat, hasOtherWork: hasOtherWork) } label: {
                    LabeledContent("Jev 条件判断", value: !chat.jev.isConfigured ? "未接入" : chat.jev.isEnabled ? "已启用" : "已关闭")
                }
            } header: {
                Text("管家")
            } footer: {
                Text("买了什么、还剩多少、放在哪，记在首页右上角的“物品”（现在 \(activeLots.count) 件）。习惯和偏好（常在哪买、习惯放哪、忌口）记在“习惯和偏好”里。")
            }
            .glassRows()

            Section("提醒与日程") {
                NavigationLink { ExpirySettingsPage() } label: {
                    LabeledContent("到期提醒", value: "提前 \(leadDays == 0 ? "当天" : leadDays == 7 ? "1 周" : "\(leadDays) 天") · \(String(format: "%02d:%02d", reminderMinutes / 60, reminderMinutes % 60))")
                }
                if !showsDone {
                    NavigationLink(value: Route.tasks) {
                        LabeledContent("任务与历史", value: "\(chat.tools?.reminders.active.count ?? 0) 件进行中")
                    }
                }
                NavigationLink { ScheduledRemindersPage(chat: chat) } label: {
                    LabeledContent("定时提醒", value: "\(chat.tools?.reminders.upcoming.count ?? 0) 条")
                }
                if let calendarFeed {
                    NavigationLink { CalendarSettingsPage(calendarFeed: calendarFeed) } label: {
                        LabeledContent("显示系统日历", value: calendarFeed.enabled && calendarFeed.canRead ? "已打开" : "未打开")
                    }
                }
            }
            .glassRows()

            Section("外观与数据") {
                NavigationLink { AppearanceSettingsView() } label: {
                    LabeledContent("外观", value: theme.title)
                }
                NavigationLink { BackupSettingsPage(chat: chat, hasOtherWork: hasOtherWork) } label: {
                    Text("备份与恢复")
                }
                Button(role: .destructive) { confirmClear = true } label: {
                    HStack { Text("清空当前对话记录"); Spacer() }
                }
                .disabled(chat.turns.isEmpty || chat.working)
            }
            .glassRows()

            #if DEBUG
            // Developer checks only: hidden unless the app is launched with --dev-tools.
            if ProcessInfo.processInfo.arguments.contains("--dev-tools") {
                Section("开发者测试") {
                    NavigationLink("Jev 自动对照测试") { JevEvaluationView(connection: chat.connection) }
                        .disabled(chat.working || hasOtherWork)
                    Button("按住说话 · 连续触感") { showVoiceTrial = true }
                        .disabled(chat.working || hasOtherWork)
                }
                .glassRows()
            }
            #endif

            Section("关于") {
                LabeledContent("版本", value: Self.version)
                Link("隐私政策", destination: OnboardingView.privacyURL)
            }
            .glassRows()
        }
        .glassList()
        .fullScreenCover(isPresented: $showVoiceTrial) { VoicePressTrialView() }
        .compactTitle("管家与设置") { EmptyView() }
        .toolbar {
            if showsDone { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .confirmationDialog("清空当前对话记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { chat.clearHistory() }
        } message: {
            Text("只清空当前会话的聊天内容和照片，其他会话、库存和管家记住的事不受影响。")
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }
}

// MARK: - Pages

/// 关于我和家里.
struct ProfileSettingsPage: View {
    @Bindable var chat: ButlerChat
    @FocusState private var editing: Bool

    var body: some View {
        Form {
            Section {
                TextField("例如：我叫安，家里两个人加一只猫；周末去盒马买菜；不吃香菜。", text: $chat.profile, axis: .vertical)
                    .lineLimit(4...10)
                    .focused($editing)
            } footer: {
                Text("管家每次对话都会先读这段话。写你希望它一直记得的背景。")
            }
            .glassRows()
        }
        .glassList()
        .navigationTitle("关于我和家里").navigationBarTitleDisplayMode(.inline)
    }
}

/// 对话模型: sign in with the subscription.
struct ModelSettingsPage: View {
    @Bindable var chat: ButlerChat
    let hasOtherWork: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                if chat.connection.isLoggedIn {
                    Label("已登录 · GPT-6 Sol", systemImage: "checkmark.circle.fill").foregroundStyle(.blue)
                    Button("退出登录", role: .destructive) { chat.signOut() }
                        .disabled(chat.working || hasOtherWork)
                } else if let code = chat.connection.deviceCode {
                    Text("1. 复制登录码")
                    HStack {
                        Text(code.code).font(.title2.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button("复制") { UIPasteboard.general.string = code.code }
                    }
                    Button("2. 打开官方页面授权") { openURL(SubscriptionConnection.verificationURL) }
                    HStack { ProgressView(); Text("授权后回到这里，会自动完成登录") }
                    Button("取消") { chat.connection.cancelLogin() }
                } else {
                    Button(chat.connection.signingIn ? "正在获取登录码…" : "用 Codex 订阅登录") {
                        Task { await chat.connection.beginLogin() }
                    }
                    .disabled(chat.connection.signingIn)
                }
                if let error = chat.connection.error { Text(error).foregroundStyle(.red) }
            } footer: {
                Text("登录即表示同意：你说的话、拍的照片和回答需要的相关库存、笔记会发给你登录的 OpenAI 账号处理；库存、笔记和对话记录保存在这台 iPhone。退出登录后不再发送。")
            }
            .glassRows()
        }
        .glassList()
        .navigationTitle("对话模型").navigationBarTitleDisplayMode(.inline)
        .task(id: chat.connection.deviceCode?.id) { await chat.connection.awaitApproval() }
        .onChange(of: chat.connection.isLoggedIn) { _, loggedIn in
            if loggedIn { chat.didSignIn() }
        }
        .onDisappear { chat.connection.cancelLogin() }
    }
}

/// Jev 条件判断.
struct JevSettingsPage: View {
    @Bindable var chat: ButlerChat
    let hasOtherWork: Bool
    @State private var jevKey = ""

    var body: some View {
        Form {
            Section {
                if chat.jev.isConfigured {
                    Toggle("启用 Jev", isOn: Binding(
                        get: { chat.jev.isEnabled }, set: { chat.jev.isEnabled = $0 }
                    ))
                    Toggle("提前准备查询资料", isOn: Binding(
                        get: { chat.jev.prefetchEnabled }, set: { chat.jev.prefetchEnabled = $0 }
                    ))
                    .disabled(!chat.jev.isEnabled)
                    Label(chat.jev.isEnabled ? "已启用 · \(JevClient.model)" : "已关闭 · 密钥已保留",
                          systemImage: chat.jev.isEnabled ? "checkmark.circle.fill" : "pause.circle")
                        .foregroundStyle(chat.jev.isEnabled ? Color.blue : Color.secondary)
                    LabeledContent("Jev 请求尝试次数", value: "\(chat.jev.callsThisSession) 次")
                    Button("移除密钥", role: .destructive) { chat.jev.removeKey() }
                        .disabled(chat.working || hasOtherWork)
                } else {
                    SecureField("粘贴 Jev API 密钥", text: $jevKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("保存") {
                        try? chat.jev.saveKey(jevKey)
                        jevKey = ""
                    }
                    .disabled(jevKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("提前准备资料：Jev 根据你的消息和上一轮问答判断是否需要库存、偏好笔记，让管家有机会直接回答；不确定或等待过久时照常查询。关闭这一项可比较原来的对话流程。\nJev 也会在部分查询和修改时核对；关闭 Jev 后不再发起新请求，已发出的请求仍可能完成。密钥保存在系统钥匙串。\n请求数从这次管家载入时开始统计，重新载入会归零；失败也计入，不代表实际扣费。开关不会清零。")
            }
            .glassRows()
        }
        .glassList()
        .navigationTitle("Jev 条件判断").navigationBarTitleDisplayMode(.inline)
    }
}

/// 到期提醒.
struct ExpirySettingsPage: View {
    @Environment(\.openURL) private var openURL
    @State private var notificationStatus: UNAuthorizationStatus?
    @AppStorage("expiryWarningDays") private var leadDays = 2
    @AppStorage("reminderMinutes") private var reminderMinutes = 9 * 60

    var body: some View {
        Form {
            Section {
                switch notificationStatus {
                case .authorized?, .provisional?, .ephemeral?:
                    Picker("提前多久提醒", selection: $leadDays) {
                        Text("当天").tag(0)
                        Text("提前 1 天").tag(1)
                        Text("提前 2 天").tag(2)
                        Text("提前 3 天").tag(3)
                        Text("提前 1 周").tag(7)
                    }
                    DatePicker("提醒时间", selection: reminderTime, displayedComponents: .hourAndMinute)
                case .denied?:
                    Text("通知被关掉了，到期前收不到提醒。").foregroundStyle(.red)
                    Button("去系统设置打开") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                default:
                    Button("开启到期提醒") {
                        Task {
                            await NotificationManager.shared.requestAuthorization()
                            await refreshNotificationStatus()
                        }
                    }
                }
            } footer: {
                Text("有日期的东西会在到期前按这里的时间提醒一次；药品会再多提前 4 天。“只记数量”的东西不提醒到期。")
            }
            .glassRows()
        }
        .glassList()
        .navigationTitle("到期提醒").navigationBarTitleDisplayMode(.inline)
        .task { await refreshNotificationStatus() }
        .onChange(of: leadDays) { _, _ in rescheduleReminders() }
        .onChange(of: reminderMinutes) { _, _ in rescheduleReminders() }
    }

    private var reminderTime: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: reminderMinutes / 60, minute: reminderMinutes % 60, second: 0, of: .now) ?? .now
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            reminderMinutes = (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
        })
    }

    private func refreshNotificationStatus() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// The home screen rebuilds reminders when it hears this.
    private func rescheduleReminders() {
        NotificationCenter.default.post(name: .butlerNotificationAuthorizationChanged, object: nil)
    }
}

/// 定时提醒.
struct ScheduledRemindersPage: View {
    @Bindable var chat: ButlerChat

    var body: some View {
        Form {
            Section {
                let upcoming = chat.tools?.reminders.upcoming ?? []
                if upcoming.isEmpty {
                    Text("还没有。对管家说“11 点提醒我热饭”“每天晚上 9 点提醒我吃药”就能设。")
                        .foregroundStyle(.secondary)
                }
                ForEach(upcoming) { reminder in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(reminder.text)
                        Text(reminder.whenLabel).font(Theme.body(13)).foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    for index in offsets { try? chat.tools?.reminders.remove(upcoming[index].id) }
                }
            } footer: {
                Text("左滑可以取消提醒，任务历史会保留。")
            }
            .glassRows()
        }
        .glassList()
        .navigationTitle("定时提醒").navigationBarTitleDisplayMode(.inline)
    }
}

/// 显示系统日历.
struct CalendarSettingsPage: View {
    let calendarFeed: CalendarFeed
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                Toggle("在首页显示系统日历", isOn: Binding(get: { calendarFeed.enabled && calendarFeed.canRead }, set: { on in
                    calendarFeed.enabled = on
                    if on { Task { if !(await calendarFeed.requestAccess()) { calendarFeed.enabled = false } } }
                }))
                if calendarFeed.isBlocked {
                    Button("日历权限被关掉了，去系统设置打开") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            } footer: {
                Text("此开关只在首页显示日程，不会自动修改日历或发送给模型。对话使用日历需另行确认，每次修改也需确认。可在对话中说“关闭对话日历访问”撤销许可。")
            }
            .glassRows()
        }
        .glassList()
        .navigationTitle("显示系统日历").navigationBarTitleDisplayMode(.inline)
    }
}

/// 备份与恢复.
struct BackupSettingsPage: View {
    @Bindable var chat: ButlerChat
    let hasOtherWork: Bool
    @Environment(CalendarFeed.self) private var calendarFeed: CalendarFeed?
    @Environment(\.modelContext) private var modelContext
    @State private var exportDocument: BackupDocument?
    @State private var importing = false
    @State private var pendingRestore: ButlerBackup?
    @State private var backupMessage: String?

    var body: some View {
        Form {
            Section {
                Button {
                    do {
                        let backup = try BackupService.makeBackup(container: modelContext.container)
                        exportDocument = BackupDocument(data: try BackupService.encode(backup))
                    } catch {
                        backupMessage = "没能生成备份：\(error.localizedDescription)"
                    }
                } label: {
                    Label("导出备份到文件", systemImage: "square.and.arrow.up")
                }
                Button { importing = true } label: {
                    Label("从备份恢复", systemImage: "clock.arrow.circlepath")
                }
                if let backupMessage {
                    Text(backupMessage).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("备份包含家里的东西和变动记录、习惯和偏好、任务、全部会话、草稿、照片和设置。建议存到 iCloud 云盘，换手机或重装后可以恢复。")
            }
            .glassRows()
        }
        .glassList()
        .navigationTitle("备份与恢复").navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument, contentType: .json,
                      defaultFilename: BackupService.fileName()) { result in
            if case .success = result { backupMessage = "备份已保存。" }
            exportDocument = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                pendingRestore = try BackupService.decode(Data(contentsOf: url))
            } catch {
                backupMessage = (error as? LocalizedError)?.errorDescription ?? "没能读取这个文件。"
            }
        }
        .confirmationDialog("用这个备份替换现在的数据？", isPresented: Binding(
            get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }
        ), titleVisibility: .visible) {
            Button("恢复", role: .destructive) { restorePending() }
            Button("取消", role: .cancel) { pendingRestore = nil }
        } message: {
            if let backup = pendingRestore {
                Text("备份时间 \(backup.createdAt.formatted(date: .abbreviated, time: .shortened))，家里 \(backup.activeLotCount) 样东西。现在的数据会先自动保存一份，再被替换。")
            }
        }
    }

    private func restorePending() {
        guard !hasOtherWork && !chat.working else { backupMessage = "请先停止正在进行的对话，再恢复备份。"; return }
        guard let backup = pendingRestore else { return }
        pendingRestore = nil
        do {
            try BackupService.restore(backup, container: modelContext.container)
            chat.reloadFromDisk()
            if let calendarFeed { calendarFeed.enabled = UserDefaults.standard.bool(forKey: "showSystemCalendar") }
            NotificationCenter.default.post(name: .butlerNotificationAuthorizationChanged, object: nil)
            backupMessage = "已恢复：家里 \(backup.activeLotCount) 样东西。"
        } catch {
            backupMessage = "恢复没有完成：\(error.localizedDescription)"
        }
    }
}

struct MemoriesView: View {
    let chat: ButlerChat

    var body: some View {
        List {
            let records = chat.tools?.notes.records ?? []
            if records.isEmpty {
                Text("还没有记下的习惯。在对话里告诉管家，比如“饮用水我都放卫生间”“盒马的麻薯我一般买小盒”。")
                    .foregroundStyle(.secondary).glassRows()
            }
            ForEach(records) { note in
                VStack(alignment: .leading, spacing: 6) {
                    Text(note.title).font(.body.weight(.semibold))
                    Text(note.text).font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .onDelete { offsets in
                for index in offsets { try? chat.tools?.notes.delete(records[index].id) }
            }
            .glassRows()
        }
        .glassList()
        .navigationTitle("习惯和偏好").navigationBarTitleDisplayMode(.inline)
    }
}
