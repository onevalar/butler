import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// How the chat was opened from home: typing, talking, or taking a photo.
enum ChatStart: Hashable, Identifiable {
    case typing, voice, camera
    var id: Self { self }
}

/// Another tab asked the conversation to open ready to type or listen.
struct ChatRequest: Equatable {
    let id = UUID()
    let start: ChatStart
}

/// 和管家聊聊: the main way to tell Butler things, ask about home, and change inventory.
struct ButlerChatView: View {
    @Bindable var chat: ButlerChat
    @Binding var request: ChatRequest?
    var onQuickCapture: (() -> Void)? = nil
    let onClose: () -> Void

    @Environment(\.butlerAccent) private var accent
    @State private var dictation = LiveDictation()
    @State private var showingCamera = false
    @State private var showingLibrary = false
    @State private var showingFiles = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var showingSettings = false
    @FocusState private var composing: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if chat.turns.isEmpty { welcome }
                        ForEach(chat.turns) { turn in turnView(turn) }
                        if chat.working {
                            // Counts up after a few seconds, so a long wait never looks like nothing is happening.
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let seconds = Int(context.date.timeIntervalSince(chat.workingSince ?? context.date))
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text(seconds < 6 ? "正在想，需要时会查家里的东西…"
                                         : seconds < 25 ? "还在想… \(seconds) 秒" : "这次有点慢… \(seconds) 秒，可以点停止")
                                        .monospacedDigit()
                                }
                            }
                            .font(.subheadline).foregroundStyle(.secondary)
                            .padding(.leading, 4)
                        }
                        if let pending = chat.tools?.pending, !pending.isEmpty, !chat.working {
                            confirmCard(pending)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.turns) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: chat.working) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: chat.tools?.pending.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .background { ButlerBackground() }
            .safeAreaBar(edge: .bottom) { composer }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        ButlerOrb(size: 30, active: chat.working || dictation.listening)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("小当家").font(.subheadline.weight(.semibold))
                            Text(statusLine).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.trailing, 8)
                    .fixedSize()
                    .accessibilityElement(children: .combine)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dictation.cancel(); onClose() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingSettings) {
                NavigationStack { ButlerSettingsView(chat: chat, showsDone: true) }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                PhotoCapture(onPhoto: { image in
                    if let data = image.chatJPEG() { chat.photos.append(data) }
                    showingCamera = false
                }, onCancel: { showingCamera = false })
                .ignoresSafeArea()
            }
            .onChange(of: request, initial: true) { _, new in
                guard let start = new?.start else { return }
                request = nil
                Task {
                    // Let the tab switch finish before the keyboard or the mic comes up.
                    try? await Task.sleep(for: .milliseconds(250))
                    switch start {
                    case .camera: showingCamera = true
                    case .voice: await startListening()
                    case .typing: composing = true
                    }
                }
            }
            .onDisappear { dictation.cancel() }
            .photosPicker(isPresented: $showingLibrary, selection: $pickedPhotos, maxSelectionCount: 4, matching: .images)
            .onChange(of: pickedPhotos) { _, items in
                guard !items.isEmpty else { return }
                pickedPhotos = []
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self), let jpeg = UIImage(data: data)?.chatJPEG() {
                            chat.photos.append(jpeg)
                        }
                    }
                }
            }
            .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                for url in urls.prefix(4) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url), let jpeg = UIImage(data: data)?.chatJPEG() {
                        chat.photos.append(jpeg)
                    }
                }
            }
        }
    }

    private var statusLine: String {
        guard chat.connection.isLoggedIn else { return "未登录" }
        return chat.jev.isConfigured ? "GPT-6 Sol · Jev 已接入" : "GPT-6 Sol"
    }

    // MARK: - Conversation

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("家里的事，直接跟我说").font(.title2.bold())
            Text("买了什么、吃了什么、放在哪，或者问我家里还有什么、什么快过期。也可以拍一张买回来的东西或小票，或者让我到点提醒你。")
                .font(.subheadline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(["盒马买了两盒草莓和一箱牛奶", "鸡蛋还剩 4 个", "冰箱里有什么快过期了？", "11 点提醒我热剩饭"], id: \.self) { example in
                    Button { chat.draft = example; composing = true } label: {
                        Text(example)
                            .font(.subheadline)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
            if !chat.connection.isLoggedIn {
                Button("先登录订阅，再开始对话") { showingSettings = true }
                    .buttonStyle(AccentButtonStyle())
                    .padding(.top, 8)
                if let onQuickCapture {
                    Button("不登录，先用本机快速记一笔") { dictation.cancel(); onQuickCapture() }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 16)
    }

    private func turnView(_ turn: ChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let names = turn.photos, !names.isEmpty, let directory = chat.photoDirectory {
                HStack(spacing: 6) {
                    Spacer(minLength: 48)
                    ForEach(names, id: \.self) { name in
                        if let image = UIImage(contentsOfFile: directory.appendingPathComponent(name).path) {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: 110, height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }
                }
            }
            HStack {
                Spacer(minLength: 56)
                Text(turn.question)
                    .foregroundStyle(accent.onFill)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(accent.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
            }
            if !turn.answer.isEmpty {
                HStack {
                    Text(turn.answer)
                        .foregroundStyle(turn.failed ? Color.red : .primary)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .glassCard(radius: 18)
                        .textSelection(.enabled)
                    Spacer(minLength: 40)
                }
            }
            if !turn.receipts.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(turn.receipts.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.footnote)
                            .foregroundStyle(line.hasPrefix("✗") ? Color.red : .secondary)
                    }
                }
                .padding(.leading, 6)
            }
        }
    }

    private func color(for change: PendingChange) -> Color {
        switch change.kind {
        case .reminder, .cancelReminder: .blue
        case .note: .gray
        case .add: .green
        default: .orange
        }
    }

    private func confirmCard(_ pending: [PendingChange]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(pending.enumerated()), id: \.element.id) { index, change in
                HStack(alignment: .center, spacing: 12) {
                    KindBar(color: color(for: change), height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(change.title).font(.body)
                        if let detail = change.detail {
                            Text(detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        switch change.check {
                        case .passed:
                            Label("Jev 已核对", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.blue)
                        case .concern(let concern):
                            Label("Jev 提醒：\(concern)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                        case nil:
                            EmptyView()
                        }
                    }
                    Spacer(minLength: 0)
                    Button { chat.tools?.removePending(change.id) } label: {
                        Image(systemName: "minus.circle.fill").font(.title3).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("去掉这一条")
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                if index < pending.count - 1 { RowDivider(inset: 30) }
            }
            HStack(spacing: 10) {
                Button("取消") { chat.discard() }
                    .buttonStyle(QuietButtonStyle())
                Button(pending.count == 1 ? "确认" : "确认 \(pending.count) 项") { chat.confirm() }
                    .buttonStyle(AccentButtonStyle())
            }
            .padding(12)
        }
        .glassCard()
        .padding(.trailing, 32)
        .sensoryFeedback(.success, trigger: chat.turns.last?.receipts.count ?? 0)
    }

    // MARK: - Composer (floating Liquid Glass)

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = dictation.error ?? (chat.working ? nil : chat.error) {
                Text(error).font(.footnote).foregroundStyle(.red)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
            }
            if !chat.photos.isEmpty { attachedPhotos }
            GlassEffectContainer(spacing: 10) {
                HStack(alignment: .bottom, spacing: 10) {
                    Menu {
                        Button { showingCamera = true } label: { Label("拍照", systemImage: "camera") }
                        Button { showingLibrary = true } label: { Label("照片图库", systemImage: "photo.on.rectangle") }
                        Button { showingFiles = true } label: { Label("选择文件", systemImage: "folder") }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 20, weight: .medium)).frame(width: 52, height: 52)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .disabled(chat.working || dictation.listening)
                    .accessibilityLabel("添加照片")

                    HStack(alignment: .bottom, spacing: 6) {
                        TextField(placeholder, text: $chat.draft, axis: .vertical)
                            .lineLimit(1...6)
                            .focused($composing)
                            .padding(.leading, 18)
                            .padding(.vertical, 15)
                        trailingButton
                            .padding(.trailing, 6).padding(.bottom, 6)
                    }
                    .frame(minHeight: 52)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .onChange(of: dictation.text) { _, text in
            if dictation.listening { chat.draft = text }
        }
    }

    private var placeholder: String {
        dictation.preparing ? "正在准备语音…" : dictation.listening ? "正在听，说完点停止" : "和管家说…"
    }

    /// Mic when empty, send when there's something to send, stop while listening or thinking.
    @ViewBuilder
    private var trailingButton: some View {
        if chat.working {
            GlassCircleButton(systemImage: "stop.fill") { chat.stop() }
                .accessibilityLabel("停止")
        } else if dictation.listening {
            GlassCircleButton(systemImage: "stop.fill", tint: .red) { Task { chat.draft = await dictation.stop() } }
                .accessibilityLabel("停止听写")
        } else if chat.canSend {
            GlassCircleButton(systemImage: "arrow.up", tint: accent.fill, glyph: accent.onFill) {
                composing = false
                chat.send()
            }
            .accessibilityLabel("发送")
        } else {
            GlassCircleButton(systemImage: "mic.fill", tint: accent.fill, glyph: accent.onFill) { Task { await startListening() } }
                .disabled(dictation.preparing)
                .accessibilityLabel("说话")
        }
    }

    private var attachedPhotos: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(chat.photos.enumerated()), id: \.offset) { index, data in
                    if let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            .padding(6)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func startListening() async {
        composing = false
        await dictation.start(after: chat.draft)
    }
}
