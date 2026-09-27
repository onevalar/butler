import SwiftUI

/// First launch: what Butler does, consent + sign-in for the cloud model, reminders, calendar.
struct OnboardingView: View {
    let chat: ButlerChat
    let calendarFeed: CalendarFeed
    let onDone: () -> Void

    enum Step: Int, CaseIterable { case welcome, model, reminders, calendar }

    @State private var step: Step = .welcome
    @State private var notificationsAsked = false
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let privacyURL = URL(string: "https://claude.ai/artifact/G4GMTvaTqe1oWBJkU7rQmX")!

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ProgressDots(count: Step.allCases.count, current: step.rawValue)
                Spacer()
                if step != .welcome {
                    Button("跳过") { onDone() }
                        .buttonStyle(.glass)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .frame(height: 56)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch step {
                    case .welcome: welcome
                    case .model: model
                    case .reminders: reminders
                    case .calendar: calendar
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(step)
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background { ButlerBackground() }
        .safeAreaBar(edge: .bottom) { buttons }
        .animation(reduceMotion ? nil : .snappy, value: step)
        .onChange(of: chat.connection.isLoggedIn) { _, loggedIn in
            if loggedIn { chat.didSignIn() }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            ButlerOrb(size: 72)
            Text("小当家帮你\n管家里的事").font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 18) {
                Feature(systemImage: "mic.fill", color: .blue, title: "说一句就记下",
                        text: "“盒马买了两盒草莓和一箱牛奶”，或者拍一张小票。")
                Feature(systemImage: "clock.badge.exclamationmark", color: .orange, title: "快过期前提醒你",
                        text: "首页一眼看到这周要吃掉什么、什么快没了。")
                Feature(systemImage: "bell.fill", color: .red, title: "到点叫你",
                        text: "“11 点提醒我热剩饭”“每天晚上 9 点提醒我吃药”。")
            }
            .padding(.top, 8)
        }
    }

    private var model: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepIcon(systemImage: "bubble.left.and.text.bubble.right.fill", color: .blue)
            Text("连接对话模型").font(.largeTitle.bold())
            Text("小当家用你自己的 OpenAI（ChatGPT / Codex）订阅来理解你说的话。")
                .font(.body).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Label("你说的话、附上的照片，和回答需要的相关库存、笔记，会发给你登录的 OpenAI 账号处理。", systemImage: "arrow.up.circle")
                Label("家里的东西、对话记录和提醒保存在这台 iPhone 上，Butler 没有自己的服务器。", systemImage: "iphone")
                Label("随时可以在设置里退出登录，之后不会再发送任何内容。", systemImage: "hand.raised")
            }
            .font(.subheadline)
            .padding(16)
            .glassCard(radius: 22)
            Button("阅读隐私政策") { openURL(Self.privacyURL) }
                .font(.subheadline)
            SubscriptionLoginPanel(connection: chat.connection)
                .padding(.top, 4)
        }
    }

    private var reminders: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepIcon(systemImage: "bell.badge.fill", color: .red)
            Text("打开提醒").font(.largeTitle.bold())
            Text("东西快到期时、你设的提醒到点时，小当家会发通知给你。都是手机本地通知，不经过任何服务器。")
                .font(.body).foregroundStyle(.secondary)
            if notificationsAsked {
                Label("好了，之后可以在设置里调整提前几天、几点提醒。", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var calendar: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepIcon(systemImage: "calendar", color: .green)
            Text("首页显示日程？").font(.largeTitle.bold())
            Text("打开后，你日历里的会议和安排会出现在首页的时间线上。小当家只读取、不修改，也不会发给模型。")
                .font(.body).foregroundStyle(.secondary)
            Toggle("在首页显示系统日历", isOn: Binding(get: { calendarFeed.enabled && calendarFeed.canRead }, set: { on in
                calendarFeed.enabled = on
                if on { Task { if !(await calendarFeed.requestAccess()) { calendarFeed.enabled = false } } }
            }))
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .glassCard(radius: 22)
            Text("以后也可以在设置里打开或关闭。").font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        VStack(spacing: 10) {
            switch step {
            case .welcome:
                primary("开始") { step = .model }
            case .model:
                if chat.connection.isLoggedIn {
                    primary("继续") { step = .reminders }
                } else {
                    secondary("稍后再登录") { step = .reminders }
                }
            case .reminders:
                if notificationsAsked {
                    primary("继续") { step = .calendar }
                } else {
                    primary("打开通知") {
                        Task {
                            await NotificationManager.shared.requestAuthorization()
                            notificationsAsked = true
                        }
                    }
                    secondary("暂不") { step = .calendar }
                }
            case .calendar:
                primary("开始使用") { onDone() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(AccentButtonStyle(height: 50))
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }
}

/// Device-code sign-in for the ChatGPT/Codex subscription, shared by onboarding.
struct SubscriptionLoginPanel: View {
    let connection: SubscriptionConnection
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if connection.isLoggedIn {
                Label("已登录，可以开始对话了", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if let code = connection.deviceCode {
                Text("1. 复制登录码").font(.subheadline.weight(.semibold))
                HStack {
                    Text(code.code).font(.title2.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button("复制") { UIPasteboard.general.string = code.code }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                }
                Button("2. 打开 OpenAI 官方页面授权") { openURL(SubscriptionConnection.verificationURL) }
                    .buttonStyle(AccentButtonStyle())
                HStack(spacing: 8) { ProgressView(); Text("授权后回到这里，会自动完成登录").font(.footnote).foregroundStyle(.secondary) }
                Button("取消", role: .cancel) { connection.cancelLogin() }.font(.footnote)
            } else {
                Button(connection.signingIn ? "正在获取登录码…" : "同意并登录") {
                    Task { await connection.beginLogin() }
                }
                .buttonStyle(AccentButtonStyle(height: 50))
                .disabled(connection.signingIn)
            }
            if let error = connection.error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .task(id: connection.deviceCode?.id) { await connection.awaitApproval() }
    }
}

private struct StepIcon: View {
    let systemImage: String
    let color: Color
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 64, height: 64)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct Feature: View {
    let systemImage: String
    let color: Color
    let title: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProgressDots: View {
    let count: Int
    let current: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.primary : Color(.tertiaryLabel))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: current)
        .accessibilityElement()
        .accessibilityLabel("第 \(current + 1) 步，共 \(count) 步")
    }
}
