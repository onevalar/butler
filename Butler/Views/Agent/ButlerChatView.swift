import SwiftUI

/// How the chat was opened from home: typing, talking, or taking a photo.
enum ChatStart: Hashable, Identifiable {
    case typing, voice, camera
    var id: Self { self }
}

/// 和管家聊聊: the main way to tell Butler things, ask about home, and change inventory.
struct ButlerChatView: View {
    @Bindable var chat: ButlerChat
    var start: ChatStart = .typing
    var onQuickCapture: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var dictation = LiveDictation()
    @State private var showingSettings = false
    @State private var showingCamera = false
    @State private var started = false
    @FocusState private var composing: Bool

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
                    Button { close() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭")
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        SealView(glyph: "管", style: .solid, size: 24)
                        Text("小当家").font(Theme.display(17))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("设置")
                }
            }
            .toolbarBackground(Theme.ground, for: .navigationBar)
            .sheet(isPresented: $showingSettings) { ButlerSettingsView(chat: chat) }
            .fullScreenCover(isPresented: $showingCamera) {
                PhotoCapture(onPhoto: { image in
                    if let data = image.chatJPEG() { chat.photos.append(data) }
                    showingCamera = false
                }, onCancel: { showingCamera = false })
                .ignoresSafeArea()
            }
            .task {
                guard !started else { return }
                started = true
                switch start {
                case .camera: showingCamera = true
                case .voice: await startListening()
                case .typing: composing = true
                }
            }
            .onDisappear { dictation.cancel() }
        }
        .tint(Theme.cobalt)
    }

    private func close() {
        dictation.cancel()
        dismiss()
    }

    // MARK: - Conversation

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("家里的事，\n直接跟我说。")
                .font(Theme.display(30)).foregroundStyle(Theme.ink).lineSpacing(6)
            Text("买了什么、吃了什么、放在哪，或者问我家里还有什么、什么快过期。也可以拍一张买回来的东西或小票。")
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
                if let onQuickCapture {
                    Button("不登录，先用本机快速记一笔") { dictation.cancel(); onQuickCapture() }
                        .font(Theme.body(14)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 20)
    }

    private func turnView(_ turn: ChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let names = turn.photos, !names.isEmpty, let directory = chat.photoDirectory {
                HStack(spacing: 6) {
                    Spacer(minLength: 48)
                    ForEach(names, id: \.self) { name in
                        if let image = UIImage(contentsOfFile: directory.appendingPathComponent(name).path) {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }
            }
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
                        switch change.check {
                        case .passed:
                            Label("Jev 已核对", systemImage: "checkmark.seal")
                                .font(Theme.body(12)).foregroundStyle(Theme.cobalt)
                        case .concern(let concern):
                            Label("Jev 提醒：\(concern)", systemImage: "exclamationmark.triangle")
                                .font(Theme.body(12)).foregroundStyle(Theme.vermilion)
                        case nil:
                            EmptyView()
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
        VStack(alignment: .leading, spacing: 8) {
            if let error = dictation.error ?? (chat.working ? nil : chat.error) {
                Text(error).font(Theme.body(13)).foregroundStyle(Theme.vermilion)
            }
            if !chat.photos.isEmpty { attachedPhotos }
            HStack(alignment: .bottom, spacing: 8) {
                circleButton("camera", label: "拍照") { showingCamera = true }
                    .disabled(chat.working || dictation.listening)

                ZStack(alignment: .trailing) {
                    TextField("", text: $chat.draft,
                              prompt: Text(dictation.preparing ? "正在准备语音…" : dictation.listening ? "正在听，说完点停止" : "和管家说…")
                                .foregroundStyle(Theme.faint),
                              axis: .vertical)
                        .font(Theme.body(16))
                        .lineLimit(1...6)
                        .focused($composing)
                        .padding(.leading, 14).padding(.trailing, 44).padding(.vertical, 11)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    Button(action: toggleVoice) {
                        Image(systemName: dictation.listening ? "stop.circle.fill" : "mic")
                            .font(.system(size: dictation.listening ? 24 : 18, weight: .regular))
                            .foregroundStyle(dictation.listening ? Theme.vermilion : Theme.muted)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .disabled(chat.working || dictation.preparing)
                    .accessibilityLabel(dictation.listening ? "停止听写" : "说话")
                    .padding(.trailing, 2)
                }

                if chat.working {
                    circleButton("stop.fill", label: "停止") { chat.stop() }
                } else {
                    Button {
                        Task {
                            if dictation.listening { chat.draft = await dictation.stop() }
                            composing = false
                            chat.send()
                        }
                    } label: {
                        Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white).frame(width: 44, height: 44)
                            .background(Circle().fill(Theme.cobaltFill))
                    }
                    .buttonStyle(.plain)
                    .disabled(!chat.canSend && !dictation.listening)
                    .opacity(chat.canSend || dictation.listening ? 1 : 0.35)
                    .accessibilityLabel("发送")
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
        .background(Theme.ground)
        .onChange(of: dictation.text) { _, text in
            if dictation.listening { chat.draft = text }
        }
    }

    private var attachedPhotos: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(chat.photos.enumerated()), id: \.offset) { index, data in
                    if let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                Button { chat.photos.remove(at: index) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.55))
                                        .font(.system(size: 20))
                                }
                                .buttonStyle(.plain)
                                .padding(3)
                                .accessibilityLabel("去掉这张照片")
                            }
                    }
                }
            }
        }
    }

    private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.surface))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func toggleVoice() {
        Task {
            if dictation.listening {
                chat.draft = await dictation.stop()
            } else {
                await startListening()
            }
        }
    }

    private func startListening() async {
        composing = false
        await dictation.start(after: chat.draft)
    }
}
