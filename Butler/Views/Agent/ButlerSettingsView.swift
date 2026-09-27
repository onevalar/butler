import SwiftData
import SwiftUI
import UserNotifications

/// Everything the owner configures: who they are, the model account, Jev, memories, chat history.
struct ButlerSettingsView: View {
    @Bindable var chat: ButlerChat
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var jevKey = ""
    @State private var confirmClear = false
    @State private var notificationStatus: UNAuthorizationStatus?
    @Environment(CalendarFeed.self) private var calendarFeed: CalendarFeed?
    @AppStorage("expiryWarningDays") private var leadDays = 2
    @AppStorage("reminderMinutes") private var reminderMinutes = 9 * 60
    @Query(filter: #Predicate<InventoryLot> { $0.stateRawValue == "active" }) private var activeLots: [InventoryLot]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：我叫安，家里两个人加一只猫；周末去盒马买菜；不吃香菜。",
                              text: $chat.profile, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("关于我和家里")
                } footer: {
                    Text("管家每次对话都会先读这段话。写你希望它一直记得的背景。")
                }

                Section {
                    LabeledContent("家里的东西", value: "\(activeLots.count) 件")
                    NavigationLink {
                        MemoriesView(chat: chat)
                    } label: {
                        LabeledContent("习惯和偏好", value: "\(chat.tools?.notes.records.count ?? 0) 条")
                    }
                } header: {
                    Text("管家记住的")
                } footer: {
                    Text("买了什么、还剩多少、放在哪，记在“家里的东西”里，在首页冰箱图标里查看。你的习惯和偏好（常在哪买、习惯放哪、忌口）记在“习惯和偏好”里。")
                }

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
                } header: {
                    Text("到期提醒")
                } footer: {
                    Text("有日期的东西会在到期前按这里的时间提醒一次；药品会再多提前 4 天。“只记数量”的东西不提醒到期。")
                }

                if let calendarFeed {
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
                    } header: {
                        Text("首页日程")
                    } footer: {
                        Text("打开后，日历里的会议和安排会出现在首页的时间线上（绿色）。管家只读取，不修改你的日历。")
                    }
                }

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
                } header: {
                    Text("定时提醒")
                } footer: {
                    Text("左滑可以删除。")
                }

                Section {
                    if chat.connection.isLoggedIn {
                        Label("已登录 · GPT-6 Sol", systemImage: "checkmark.circle.fill").foregroundStyle(.blue)
                        Button("退出登录", role: .destructive) { chat.signOut() }
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
                } header: {
                    Text("对话模型")
                } footer: {
                    Text("登录即表示同意：你说的话、拍的照片和回答需要的相关库存、笔记会发给你登录的 OpenAI 账号处理；库存、笔记和对话记录保存在这台 iPhone。退出登录后不再发送。")
                }

                Section {
                    if chat.jev.isConfigured {
                        Label("已接入 Jev · \(JevClient.model)", systemImage: "checkmark.circle.fill").foregroundStyle(.blue)
                        LabeledContent("本次打开后调用", value: "\(chat.jev.callsThisSession) 次")
                        Button("移除密钥", role: .destructive) { chat.jev.removeKey() }
                    } else {
                        SecureField("粘贴 Jev API 密钥", text: $jevKey)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("保存") {
                            try? chat.jev.saveKey(jevKey)
                            jevKey = ""
                        }
                        .disabled(jevKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Jev 条件判断")
                } footer: {
                    Text("接入后，管家每次查家里的东西、每次提出修改，都会先请 Jev 核对：说的是哪一件、数字是剩余还是用掉、是新买还是纠正、日期是不是你说的。不填也能完整使用，只是少这一道核对。密钥保存在系统钥匙串。")
                }

                Section {
                    Button("清空对话记录", role: .destructive) { confirmClear = true }
                        .disabled(chat.turns.isEmpty || chat.working)
                } footer: {
                    Text("只清空聊天内容和聊天里的照片，不影响库存和管家记住的事。")
                }

                Section {
                    LabeledContent("版本", value: Self.version)
                    Link("隐私政策", destination: OnboardingView.privacyURL)
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task(id: chat.connection.deviceCode?.id) { await chat.connection.awaitApproval() }
            .onChange(of: chat.connection.isLoggedIn) { _, loggedIn in
                if loggedIn { chat.didSignIn() }
            }
            .onDisappear { chat.connection.cancelLogin() }
            .task { await refreshNotificationStatus() }
            .onChange(of: leadDays) { _, _ in rescheduleReminders() }
            .onChange(of: reminderMinutes) { _, _ in rescheduleReminders() }
            .confirmationDialog("清空全部对话记录？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) { chat.clearHistory() }
            }
        }

        .presentationDetents([.large])
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

    private static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }
}

private struct MemoriesView: View {
    let chat: ButlerChat

    var body: some View {
        List {
            let records = chat.tools?.notes.records ?? []
            if records.isEmpty {
                Text("还没有记下的习惯。在对话里告诉管家，比如“饮用水我都放卫生间”“盒马的麻薯我一般买小盒”。")
                    .foregroundStyle(.secondary)
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
        }
        .navigationTitle("习惯和偏好").navigationBarTitleDisplayMode(.inline)
    }
}
