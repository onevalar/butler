import SwiftUI
import SwiftData

/// 和管家聊聊: the main way to tell Butler things, ask about home, and change inventory.
struct ButlerChatView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var chat: ButlerChat
    @State private var voice = VoiceManager()
    @State private var listening = false
    @State private var showingSettings = false
    @State private var showingNotes = false
    @State private var jevKey = ""
    @FocusState private var composing: Bool

    init(container: ModelContainer) {
        _chat = State(initialValue: ButlerChat(container: container))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            if chat.turns.isEmpty { welcome }
                            ForEach(chat.turns) { turn in turnView(turn) }
                            if chat.working {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("正在想，需要时会查家里的东西…")
                                }
                                .font(Theme.body(14)).foregroundStyle(Theme.muted)
                            }
                            if let pending = chat.tools?.pending, !pending.isEmpty, !chat.working {
                                confirmCard(pending)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 20).padding(.vertical, 16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: chat.turns) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: chat.working) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                composer
            }
            .background(Theme.ground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { chat.stop(); voice.cancel(); dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭")
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        SealView(glyph: "管", style: .solid, size: 24)
                        Text("小当家").font(Theme.display(17))
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingNotes = true } label: { Image(systemName: "book.closed") }
                        .accessibilityLabel("管家记住的事")
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("设置")
                }
            }
            .toolbarBackground(Theme.ground, for: .navigationBar)
            .sheet(isPresented: $showingSettings, onDismiss: { chat.connection.cancelLogin() }) { settings }
            .sheet(isPresented: $showingNotes) { notesView }
            .onDisappear { chat.stop(); voice.cancel() }
        }
        .tint(Theme.cobalt)
    }

    // MARK: - Conversation

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("家里的事，\n直接跟我说。")
                .font(Theme.display(30)).foregroundStyle(Theme.ink).lineSpacing(6)
            Text("买了什么、吃了什么、放在哪，或者问我家里还有什么、什么快过期。")
                .font(Theme.body(15)).foregroundStyle(Theme.inkSoft)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(["盒马买了两盒草莓和一箱牛奶", "鸡蛋还剩4个", "冰箱里有什么快过期了？"], id: \.self) { example in
                    Button { chat.draft = example; composing = true } label: {
                        Text("“\(example)”").font(Theme.display(15, weight: .regular)).foregroundStyle(Theme.cobalt)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
            if !chat.connection.isLoggedIn {
                Button { showingSettings = true } label: {
                    Text("先登录订阅，再开始对话")
                }
                .buttonStyle(PillButtonStyle(kind: .primary, height: 50))
                .padding(.top, 8)
            }
        }
        .padding(.vertical, 20)
    }

    private func turnView(_ turn: ChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 48)
                Text(turn.question)
                    .font(Theme.body(16)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
            }
            if !turn.answer.isEmpty {
                Text(turn.answer)
                    .font(Theme.body(16))
                    .foregroundStyle(turn.failed ? Theme.vermilion : Theme.ink)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
            if !turn.receipts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(turn.receipts.enumerated()), id: \.offset) { _, line in
                        Text(line).font(Theme.body(13))
                            .foregroundStyle(line.hasPrefix("✗") ? Theme.vermilion : Theme.muted)
                    }
                }
            }
        }
    }

    private func confirmCard(_ pending: [PendingChange]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("确认后才会保存", color: Theme.muted)
            ForEach(pending) { change in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(change.title).font(Theme.display(16, weight: .semibold)).foregroundStyle(Theme.ink)
                        if let detail = change.detail {
                            Text(detail).font(Theme.body(13)).foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { chat.tools?.removePending(change.id) } label: {
                        Image(systemName: "minus.circle").foregroundStyle(Theme.faint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("去掉这一条")
                }
            }
            HStack(spacing: 10) {
                Button("取消") { chat.discard() }
                    .buttonStyle(PillButtonStyle(kind: .quiet, height: 46))
                    .frame(maxWidth: 110)
                Button(pending.count == 1 ? "确认" : "全部确认（\(pending.count)）") { chat.confirm() }
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 46))
            }
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = chat.error, !chat.working {
                Text(error).font(Theme.body(13)).foregroundStyle(Theme.vermilion)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button(action: toggleVoice) {
                    Image(systemName: listening ? "stop.fill" : "mic")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(listening ? .white : Theme.ink)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(listening ? Theme.vermilionFill : Theme.surface))
                }
                .buttonStyle(.plain)
                .disabled(chat.working)
                .accessibilityLabel(listening ? "说完了" : "说话")

                TextField("", text: $chat.draft,
                          prompt: Text(listening ? "正在听…" : "和管家说…").foregroundStyle(Theme.faint),
                          axis: .vertical)
                    .font(Theme.body(16))
                    .lineLimit(1...5)
                    .focused($composing)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                if chat.working {
                    Button { chat.stop() } label: {
                        Image(systemName: "stop.fill").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("停止")
                } else {
                    Button {
                        if listening { stopVoice() }
                        composing = false
                        chat.send()
                    } label: {
                        Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white).frame(width: 44, height: 44)
                            .background(Circle().fill(Theme.cobaltFill))
                    }
                    .buttonStyle(.plain)
                    .disabled(!chat.canSend && !listening)
                    .opacity(chat.canSend || listening ? 1 : 0.35)
                    .accessibilityLabel("发送")
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
        .background(Theme.ground)
        .onChange(of: voice.transcribedText) { _, text in
            if listening, !text.isEmpty { chat.draft = text }
        }
    }

    private func toggleVoice() {
        if listening { stopVoice(); return }
        Task {
            guard await voice.requestAuthorization() else {
                chat.error = "没有麦克风或语音识别权限，可以在系统设置里打开。"
                return
            }
            do {
                try voice.startRecording(requiresOnDeviceRecognition: false)
                listening = true
                composing = false
            } catch {
                chat.error = (error as? LocalizedError)?.errorDescription ?? "语音暂时用不了，先打字吧。"
            }
        }
    }

    private func stopVoice() {
        listening = false
        Task {
            if let text = await voice.stopRecordingAndTranscribe(), !text.isEmpty { chat.draft = text }
        }
    }

    // MARK: - Settings

    private var settings: some View {
        NavigationStack {
            Form {
                Section {
                    if chat.connection.isLoggedIn {
                        Label("已登录 · GPT-6 Sol", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.cobalt)
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
                    if let error = chat.connection.error { Text(error).foregroundStyle(Theme.vermilion) }
                } header: {
                    Text("对话模型")
                } footer: {
                    Text("你说的话和相关的库存、笔记会发给模型来理解；库存和笔记保存在这台 iPhone。")
                }

                Section {
                    if chat.jev.isConfigured {
                        Label("已接入 Jev · \(JevClient.model)", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.cobalt)
                        Text("本次打开后调用 \(chat.jev.callsThisSession) 次").foregroundStyle(Theme.muted)
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
                    Text("接入后，管家在分不清你说的是哪件东西、是纠正还是新增时，会请 Jev 帮忙判断。密钥保存在系统钥匙串。")
                }

                Section {
                    Button("清空对话记录", role: .destructive) { chat.clearHistory() }
                        .disabled(chat.turns.isEmpty || chat.working)
                } footer: {
                    Text("只清空聊天内容，不影响库存和管家记住的事。")
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingSettings = false } } }
            .task(id: chat.connection.deviceCode?.id) { await chat.connection.awaitApproval() }
            .onChange(of: chat.connection.isLoggedIn) { _, loggedIn in
                if loggedIn { chat.didSignIn(); showingSettings = false }
            }
        }
    }

    private var notesView: some View {
        NavigationStack {
            List {
                let records = chat.tools?.notes.records ?? []
                if records.isEmpty {
                    Text("还没有记住的事。告诉管家你的习惯，比如“盒马的麻薯我一般买小盒，放冰箱上层”。")
                        .foregroundStyle(Theme.muted)
                }
                ForEach(records) { note in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(note.title).font(Theme.display(16, weight: .semibold))
                        Text(note.text).font(Theme.body(14)).foregroundStyle(Theme.inkSoft)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("管家记住的事").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingNotes = false } } }
        }
    }
}
