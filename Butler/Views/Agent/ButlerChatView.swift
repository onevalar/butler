import AVFoundation
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
    var onGeneralChat: (() -> Void)? = nil
    var onSettingsChat: (() -> Void)? = nil
    var onOpenLot: ((UUID) -> Void)? = nil
    var hasOtherWork = false
    var diaryTurns: [ChatTurn]? = nil
    /// Typing needs the full height; the panel may be sitting at half height after something was said.
    var onNeedsRoom: (() -> Void)? = nil
    let onClose: () -> Void

    @Environment(\.butlerAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var scrollPolicy = ChatScrollPolicy()
    @State private var startTask: Task<Void, Never>?
    @State private var dictation = LiveDictation()
    @State private var voiceSession = ChatDictationSession()
    @State private var voiceTask: Task<Void, Never>?
    @State private var voiceDeadlineTask: Task<Void, Never>?
    @State private var visible = true
    @State private var attachmentTask: Task<Void, Never>?
    @State private var loadingAttachments = false
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
                        if case .brief(let reminder) = chat.scope {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("这次管家提醒 · \(reminder.day)").font(.caption).foregroundStyle(.secondary)
                                Text(reminder.text).font(.body).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                        }
                        if chat.turns.isEmpty { welcome }
                        ForEach(chat.turns) { turn in turnView(turn) }
                        if chat.working {
                            if !chat.liveReply.isEmpty {
                                Text(chat.liveReply)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            // Counts up after a few seconds, so a long wait never looks like nothing is happening.
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let seconds = Int(context.date.timeIntervalSince(chat.workingSince ?? context.date))
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text((chat.liveReply.isEmpty ? chat.workingStage : "正在回复…")
                                         + (seconds < 6 ? "" : " \(seconds) 秒")
                                         + (seconds < 25 ? "" : "，可以点停止"))
                                        .monospacedDigit()
                                }
                            }
                            .font(.subheadline).foregroundStyle(.secondary)
                            .padding(.leading, 4)
                        }
                        if let pending = chat.tools?.pending, !pending.isEmpty, !chat.working {
                            confirmCard(pending)
                        }
                        Color.clear.frame(height: 1).padding(.bottom, 12).id("bottom")
                    }
                    .padding(.horizontal, 16).padding(.top, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollEdgeEffectHidden(for: .bottom)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onScrollGeometryChange(for: ChatScrollPolicy.Geometry.self) { geometry in
                    Self.scrollGeometry(geometry)
                } action: { _, geometry in
                    scrollPolicy.geometryChanged(to: geometry)
                }
                .onScrollPhaseChange { _, phase, context in
                    // Sample the final drag/deceleration offset before switching to idle.
                    scrollPolicy.geometryChanged(to: Self.scrollGeometry(context.geometry))
                    switch phase {
                    case .idle: scrollPolicy.phaseChanged(to: .idle)
                    case .tracking: scrollPolicy.phaseChanged(to: .tracking)
                    case .interacting: scrollPolicy.phaseChanged(to: .interacting)
                    case .decelerating: scrollPolicy.phaseChanged(to: .decelerating)
                    case .animating: scrollPolicy.phaseChanged(to: .animating)
                    @unknown default: break
                    }
                }
                .onAppear { scrollPolicy.appear() }
                .onDisappear { scrollPolicy.disappear() }
                .task(id: scrollPolicy.revision) { @MainActor in
                    // Coalesce layout notifications, not a guessed keyboard duration. A new
                    // request, user touch, or disappearance cancels this view-owned task.
                    await Task.yield()
                    guard !Task.isCancelled, let scroll = scrollPolicy.takeScroll() else { return }
                    var transaction = Transaction(animation: scroll == .animated && !reduceMotion ? .default : nil)
                    transaction.disablesAnimations = reduceMotion || scroll == .immediate
                    withTransaction(transaction) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .background { ButlerBackground() }
            // Reserve room for the floating controls without a system bar backdrop or separator.
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ButlerOrb(size: 30, active: chat.working || dictation.listening)
                        .accessibilityHidden(true)
                }
                // The system puts its own glass disc behind toolbar items; the orb is glass already.
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(chat.contextTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(statusLine)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let onGeneralChat {
                            Button("通用对话", systemImage: "bubble.left.and.bubble.right") {
                                cancelListening(); onGeneralChat()
                            }
                        }
                        if let onSettingsChat {
                            Button("聊聊设置", systemImage: "slider.horizontal.3") {
                                cancelListening(); onSettingsChat()
                            }
                        }
                        Button("管家设置", systemImage: "gearshape") {
                            cancelListening(); showingSettings = true
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("对话与设置")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { cancelListening(); onClose() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    ButlerSettingsView(chat: chat, showsDone: true, hasOtherWork: hasOtherWork, diaryTurns: diaryTurns)
                        .toolbar {
                            if let onSettingsChat {
                                ToolbarItem(placement: .bottomBar) {
                                    Button("就设置与管家聊聊") {
                                        showingSettings = false
                                        onSettingsChat()
                                    }
                                }
                            }
                        }
                }
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
                startTask?.cancel()
                startTask = Task { @MainActor in
                    // Give the tab switch an executor turn; keyboard geometry drives scrolling.
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    switch start {
                    case .camera: cancelListening(); showingCamera = true
                    case .voice: startListening()
                    case .typing: cancelListening(); composing = true
                    }
                }
            }
            .onChange(of: composing) { _, focused in
                if focused { onNeedsRoom?() }
            }
            .onAppear { visible = true }
            .onDisappear {
                visible = false
                startTask?.cancel()
                startTask = nil
                cancelListening()
                attachmentTask?.cancel()
                attachmentTask = nil
                loadingAttachments = false
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { cancelListening() }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
                if let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                   AVAudioSession.InterruptionType(rawValue: raw) == .began {
                    cancelListening()
                }
            }
            .onChange(of: dictation.listening) { _, listening in
                // LiveDictation also stops itself when recognition is interrupted.
                if !listening, voiceSession.phase == .listening { cancelListening() }
            }
            .photosPicker(isPresented: $showingLibrary, selection: $pickedPhotos, maxSelectionCount: 4, matching: .images)
            .onChange(of: pickedPhotos) { _, items in
                guard !items.isEmpty else { return }
                pickedPhotos = []
                attachmentTask?.cancel()
                loadingAttachments = true
                attachmentTask = Task { @MainActor in
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self), let jpeg = UIImage(data: data)?.chatJPEG() {
                            guard !Task.isCancelled, visible else { return }
                            chat.photos.append(jpeg)
                        }
                    }
                    guard !Task.isCancelled else { return }
                    loadingAttachments = false
                    attachmentTask = nil
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

    private nonisolated static func scrollGeometry(_ geometry: ScrollGeometry) -> ChatScrollPolicy.Geometry {
        ChatScrollPolicy.Geometry(
            offset: geometry.contentOffset.y,
            contentHeight: geometry.contentSize.height,
            containerHeight: geometry.containerSize.height,
            containerWidth: geometry.containerSize.width,
            topInset: geometry.contentInsets.top,
            bottomInset: geometry.contentInsets.bottom
        )
    }

    private var statusLine: String {
        guard chat.connection.isLoggedIn else { return "未登录" }
        if chat.jev.isAvailable { return "GPT-6 Sol · Jev 已启用" }
        return chat.jev.isConfigured ? "GPT-6 Sol · Jev 已关闭" : "GPT-6 Sol"
    }

    // MARK: - Conversation

    private var welcomeContent: (title: String, detail: String, examples: [String]) {
        switch chat.scope {
        case .general:
            ("家里的事，直接跟我说", "买了什么、吃了什么、需要记住什么，或者让我安排提醒。这里保留你的通用对话。",
             ["盒马买了两盒草莓和一箱牛奶", "今晚用家里的食材做什么？", "11 点提醒我热剩饭"])
        case .inventory:
            ("一起看看家里的东西", "可以查询库存、整理位置，或记录新买和用掉的东西。这里保留关于库存的对话。",
             ["冰箱里有什么快过期了？", "哪些东西快用完了？", "帮我看看今天该补买什么"])
        case .lot:
            ("这件物品的事，在这里聊", "管家会读取这件物品的最新记录。你可以直接说“这个”，查询数量、调整位置或回顾变化。",
             ["这个还剩多少，什么时候用完合适？", "这个放到冷冻了", "看看这个物品之前的变动"])
        case .task:
            ("继续处理这个任务", "查看提醒规则和处理记录，也可以调整安排、暂停或完成这个任务。修改前会给你确认。",
             ["这个任务接下来怎么提醒？", "把这个任务暂停", "这个任务我已经完成了"])
        case .settings:
            ("把管家调成你喜欢的样子", "可以查看和修改已有配置，或补充关于你和家里的信息。系统授权和密钥在对应设置入口处理。",
             ["看看当前可以修改哪些设置", "把显示模式改成深色", "默认提醒时间改成早上八点半"])
        case .day(let day):
            ("聊聊这一天的安排", "这里关联 \(day) 的日程。可以查看已有任务，或为这一天安排提醒。",
             ["这天有哪些任务？", "这天有什么物品需要处理？", "帮我梳理这一天的安排"])
        case .brief:
            ("这些事，我们一起安排", "可以讨论上面整条提醒中的任何一件事，也可以一起调整安排。涉及修改时，会先给你确认。",
             ["帮我梳理一下这些事的先后顺序", "这些事还有什么处理办法？"])
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(welcomeContent.title).font(.title2.bold())
            Text(welcomeContent.detail)
                .font(.subheadline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(welcomeContent.examples, id: \.self) { example in
                    Button {
                        cancelListening()
                        if chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chat.draft = example }
                        else { chat.draft += (chat.draft.hasSuffix("\n") ? "" : "\n") + example }
                        composing = true
                    } label: {
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
                    Button("不登录，先用本机快速记一笔") { cancelListening(); onQuickCapture() }
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
            if let collection = turn.collection, let onOpenLot {
                InventoryResultView(collection: collection, onOpen: onOpenLot,
                                    onRemove: { chat.removeFromCollection(collection.id, lot: $0) })
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
        case .reminder, .cancelReminder, .taskPlan, .taskAction: .blue
        case .note, .settings: .gray
        case .add: .green
        default: .orange
        }
    }

    private func confirmCard(_ pending: [PendingChange]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(pending.enumerated()), id: \.element.id) { index, change in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(index + 1). \(change.title)").font(.body.weight(.medium))
                        if let detail = change.detail {
                            Text(detail).font(.subheadline).foregroundStyle(.secondary)
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
                .padding(.horizontal, 18).padding(.vertical, 12)
                if index < pending.count - 1 { RowDivider(inset: 18) }
            }
            Text("可点确认，也可以说“确认”或“确认第2项”")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 10)
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
            // The model's errors are already shown as the answer; only the microphone's own errors go here.
            if let error = dictation.error {
                Text(error).font(.footnote).foregroundStyle(.red)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
            }
            if let hint = composerHint {
                Text(hint).font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
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
                    .disabled(voiceSession.phase != .idle || loadingAttachments)
                    .accessibilityLabel("添加照片")

                    HStack(alignment: .bottom, spacing: 6) {
                        TextField(placeholder, text: $chat.draft, axis: .vertical)
                            .lineLimit(1...6)
                            .focused($composing)
                            // Recognition owns this draft until its last result is finalized.
                            // Never overwrite a manual edit with a late partial transcript.
                            .disabled(!composerPolicy.canEditText)
                            .padding(.leading, 18)
                            .padding(.vertical, 15)
                            .padding(.trailing, composerPolicy.showsInlineMicrophone ? 0 : 18)
                        if composerPolicy.showsInlineMicrophone {
                            Button(action: startListening) {
                                Image(systemName: "mic")
                                    .font(.system(size: 20, weight: .regular))
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .disabled(!composerPolicy.canStartVoice || loadingAttachments)
                            .accessibilityLabel("用语音补充")
                            .accessibilityHint(chat.working ? "管家回答结束后可用" : "停止听写后可编辑和发送")
                            .padding(.trailing, 4).padding(.bottom, 4)
                        }
                    }
                    .frame(minHeight: 52)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 26, style: .continuous))

                    trailingButton
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .onChange(of: dictation.text) { _, text in
            if visible, voiceSession.phase == .listening || voiceSession.phase == .finishing {
                chat.draft = text
            }
        }
    }

    private var composerPolicy: ChatComposerPolicy {
        ChatComposerPolicy(draft: chat.draft, photoCount: chat.photos.count + (loadingAttachments ? 1 : 0),
                           working: chat.working, voicePhase: voiceSession.phase)
    }

    private var placeholder: String {
        switch voiceSession.phase {
        case .preparing: "正在准备语音…"
        case .listening: "正在听，说完点停止"
        case .finishing: "正在整理最后一句…"
        case .idle: "和管家说…"
        }
    }

    private var composerHint: String? {
        switch voiceSession.phase {
        case .preparing: return "正在准备麦克风，点右侧可取消。"
        case .listening: return "正在听写，停止后可以修改文字再发送。"
        case .finishing: return "正在整理最后一句，点右侧可保留当前文字。"
        case .idle: break
        }
        if loadingAttachments { return "正在添加照片…" }
        if chat.draft.count > 8_000 { return "内容超过 8,000 字，请分成几条发送。" }
        if composerPolicy.hasContent, !chat.connection.isLoggedIn, !chat.canSend { return "请先在管家设置里登录，草稿会保留。" }
        if composerPolicy.hasContent, chat.tools == nil { return "暂时无法读取本机资料，草稿已保留。" }
        return nil
    }

    @ViewBuilder
    private var trailingButton: some View {
        switch composerPolicy.action {
        case .stopResponse:
            composerButton("stop.fill", label: "停止生成") { chat.stop() }
        case .cancelPreparation:
            composerButton("xmark", label: "取消准备语音", busy: true) { cancelListening() }
        case .stopDictation:
            composerButton("stop.fill", label: "停止听写", tint: .red, glyph: .white) { stopListening() }
        case .finishDictation:
            composerButton("xmark", label: "保留当前文字并结束语音收尾", busy: true) { cancelListening() }
        case .send:
            composerButton("arrow.up", label: "发送", tint: accent.fill, glyph: accent.onFill) {
                guard chat.canSend, !loadingAttachments, voiceSession.phase == .idle else { return }
                scrollPolicy.sendToLatest()
                composing = false
                chat.send()
            }
            .disabled(!chat.canSend || loadingAttachments)
        case .voice:
            composerButton("mic.fill", label: "开始语音输入", tint: accent.fill, glyph: accent.onFill) { startListening() }
                .disabled(loadingAttachments)
        }
    }

    private func composerButton(_ symbol: String, label: String, tint: Color? = nil,
                                glyph: Color = .primary, busy: Bool = false,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if busy { ProgressView().controlSize(.small).offset(y: -9) }
                Image(systemName: symbol)
                    .font(.system(size: busy ? 11 : 20, weight: .semibold))
                    .offset(y: busy ? 10 : 0)
            }
            .foregroundStyle(glyph)
            .frame(width: 52, height: 52)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(tint.map { Glass.regular.tint($0).interactive() } ?? Glass.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
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

    private func startListening() {
        guard visible, composerPolicy.canStartVoice, !loadingAttachments,
              let id = voiceSession.begin() else { return }
        composing = false
        voiceTask = Task { @MainActor in
            await dictation.start(after: chat.draft)
            guard !Task.isCancelled, visible, voiceSession.accepts(id) else { return }
            voiceSession.prepared(id, listening: dictation.listening)
            voiceTask = nil
        }
    }

    private func stopListening() {
        guard let id = voiceSession.finish() else { return }
        let finalizationTimeout = dictation.finalizationTimeout
        voiceTask = Task { @MainActor in
            let text = await dictation.stop()
            guard !Task.isCancelled, visible, voiceSession.end(id) else { return }
            chat.draft = text
            voiceDeadlineTask?.cancel()
            voiceDeadlineTask = nil
            voiceTask = nil
        }
        // Speech services must not leave sending or manual editing blocked indefinitely.
        voiceDeadlineTask = Task { @MainActor in
            try? await Task.sleep(for: finalizationTimeout)
            guard !Task.isCancelled, voiceSession.accepts(id) else { return }
            cancelListening()
            dictation.error = "语音收尾超时，已保留识别文字，请检查后发送。"
        }
    }

    private func cancelListening() {
        if voiceSession.phase == .listening || voiceSession.phase == .finishing {
            chat.draft = dictation.text
        }
        voiceSession.cancel()
        voiceTask?.cancel()
        voiceTask = nil
        voiceDeadlineTask?.cancel()
        voiceDeadlineTask = nil
        dictation.cancel()
    }
}
