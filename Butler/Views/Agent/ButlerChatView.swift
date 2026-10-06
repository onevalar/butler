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

    @Environment(\.butlerAccent) var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var startTask: Task<Void, Never>?
    @State var dictation = LiveDictation()
    @State var voiceSession = ChatDictationSession()
    @State var voiceTask: Task<Void, Never>?
    @State var voiceDeadlineTask: Task<Void, Never>?
    @State var visible = true
    @State private var attachmentTask: Task<Void, Never>?
    @State var loadingAttachments = false
    @State var showingCamera = false
    @State var showingLibrary = false
    @State var showingFiles = false
    @State private var inboxRefresh = UUID()
    @State var attachmentNotice: String?
    @State var hasImportedFiles = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var showingSettings = false
    @FocusState var composing: Bool

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
                        if chat.working, chat.replyProgress.turnID == nil {
                            workingIndicator
                        }
                        if let pending = chat.tools?.pending, !pending.isEmpty {
                            confirmCard(pending)
                        }
                        FolderAccessPrompt(chat: chat, hasOtherWork: hasOtherWork || loadingAttachments)
                        if chat.scope == .general {
                            ShareInboxView(chat: chat, hasOtherWork: hasOtherWork || loadingAttachments, refreshID: inboxRefresh)
                        }
                        Color.clear.frame(height: 1).padding(.bottom, 12).id("bottom")
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 16).padding(.top, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollEdgeEffectHidden(for: .bottom)
                .defaultScrollAnchor(chat.scrollPolicy.followingBottom ? .bottom : .top, for: .initialOffset)
                .scrollPosition(id: Binding(
                    get: { chat.scrollPolicy.visibleTurnID },
                    set: { chat.scrollPolicy.positionChanged(to: $0) }
                ), anchor: .top)
                .onScrollGeometryChange(for: ChatScrollPolicy.Geometry.self) { geometry in
                    Self.scrollGeometry(geometry)
                } action: { _, geometry in
                    chat.scrollPolicy.geometryChanged(to: geometry)
                }
                .onScrollPhaseChange { _, phase, context in
                    // Sample the final drag/deceleration offset before switching to idle.
                    chat.scrollPolicy.geometryChanged(to: Self.scrollGeometry(context.geometry))
                    switch phase {
                    case .idle: chat.scrollPolicy.phaseChanged(to: .idle)
                    case .tracking: chat.scrollPolicy.phaseChanged(to: .tracking)
                    case .interacting: chat.scrollPolicy.phaseChanged(to: .interacting)
                    case .decelerating: chat.scrollPolicy.phaseChanged(to: .decelerating)
                    case .animating: chat.scrollPolicy.phaseChanged(to: .animating)
                    @unknown default: break
                    }
                }
                .onAppear { chat.scrollPolicy.appear(validTurnIDs: Set(chat.turns.map(\.id))) }
                .onDisappear { chat.scrollPolicy.disappear() }
                .task(id: chat.scrollPolicy.revision) { @MainActor in
                    // Coalesce layout notifications, not a guessed keyboard duration. A new
                    // request, user touch, or disappearance cancels this view-owned task.
                    await Task.yield()
                    guard !Task.isCancelled, let scroll = chat.scrollPolicy.takeScroll() else { return }
                    var transaction = Transaction(animation: scroll == .animated && !reduceMotion ? .default : nil)
                    transaction.disablesAnimations = reduceMotion || scroll == .immediate
                    withTransaction(transaction) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .background { ButlerBackground() }
            // The latest button reserves its own space rather than covering a
            // history paragraph or a confirmation button, including at large type.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if chat.scrollPolicy.showsReturnToLatest {
                        HStack {
                            Spacer(minLength: 0)
                            Button { chat.scrollPolicy.sendToLatest() } label: {
                                Label("回到最新", systemImage: "arrow.down")
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 14).frame(minHeight: 44)
                                    .glassEffect(.regular.interactive(), in: .capsule)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("跳到对话底部并继续跟随回复；不会发送消息或确认操作")
                        }
                        .padding(.horizontal, 16).padding(.vertical, 4)
                    }
                    composer
                }
            }
            .toolbar {
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
                ToolbarItem(placement: .topBarLeading) {
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
                    do {
                        guard !hasOtherWork, let data = image.chatJPEG() else { throw ShareInbox.Failure("暂时无法添加照片，请稍后重试。") }
                        try chat.appendPhotos([data]); attachmentNotice = nil
                    } catch { attachmentNotice = error.localizedDescription }
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
                    defer {
                        if !Task.isCancelled { loadingAttachments = false; attachmentTask = nil }
                    }
                    do {
                        guard chat.photos.count + items.count <= 4 else { throw ShareInbox.Failure("每条消息最多4张图片，请先移除部分附件。本次未添加。") }
                        var additions: [Data] = [], total = 0
                        for item in items {
                            try Task.checkCancellation()
                            guard let data = try await item.loadTransferable(type: Data.self) else { throw ShareInbox.Failure("照片暂时无法读取，本次选择未添加，请重试。") }
                            total += data.count
                            guard total <= ShareInbox.maxTotalBytes else { throw ShareInbox.Failure("本次图片合计超过40 MB，未添加。") }
                            let jpeg = try await Task.detached(priority: .userInitiated) { try ShareContentReader.image(data) }.value
                            additions.append(jpeg)
                        }
                        try Task.checkCancellation()
                        guard visible, !hasOtherWork else { throw ShareInbox.Failure("对话正在处理其他内容，请稍后重试。") }
                        try chat.appendPhotos(additions); attachmentNotice = nil
                    } catch is CancellationError {
                    } catch {
                        if !Task.isCancelled { attachmentNotice = "本次照片未添加：\(error.localizedDescription)" }
                    }
                }
            }
            .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.image, .pdf, .plainText], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): importFiles(urls)
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { attachmentNotice = "文件未添加：\(error.localizedDescription)" }
                }
            }
        }
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty, !loadingAttachments else { return }
        loadingAttachments = true; attachmentNotice = nil
        attachmentTask = Task { @MainActor in
            defer {
                if !Task.isCancelled { loadingAttachments = false; attachmentTask = nil }
            }
            do {
                let inbox = try ShareInbox.onDevice(), id = UUID()
                let sources = urls.map { (url: $0, type: UTType(filenameExtension: $0.pathExtension)?.identifier ?? UTType.data.identifier) }
                let copy = Task.detached(priority: .userInitiated) { try inbox.importFiles(sources, id: id) }
                _ = try await withTaskCancellationHandler { try await copy.value } onCancel: { copy.cancel() }
                try Task.checkCancellation()
                guard visible else { return }
                inboxRefresh = UUID()
                hasImportedFiles = true
                attachmentNotice = chat.scope == .general
                    ? "原件已保存到本对话的“分享资料”。可查看原件，再点“加入草稿，继续聊”；尚未发送。"
                    : "原件已保存到通用对话的“分享资料”，请在那里预览并加入草稿；当前草稿未改动。"
            } catch is CancellationError {
                // If publishing already finished, keep the inbox record for the next opening.
            } catch {
                if !Task.isCancelled { attachmentNotice = "本次文件未导入：\(error.localizedDescription)；来源文件未修改。" }
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

    private var workingIndicator: some View {
        ChatWorkingIndicator(label: chat.workingStage)
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
            if let collection = turn.collection, let onOpenLot {
                InventoryResultView(collection: collection, onOpen: onOpenLot,
                                    onRemove: { chat.removeFromCollection(collection.id, lot: $0) },
                                    allowsRemoval: !chat.working && !hasOtherWork && !loadingAttachments,
                                    notice: turn.collectionNotice)
            }
            ChatReplyBubble(turn: turn, progress: chat.replyProgress,
                            workingStage: chat.workingStage)
            if turn.replyState == .interrupted {
                Text("上次回复中断，未自动重发。已保存的消息和操作回执仍保留，请核对后继续。")
                    .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            } else if turn.replyState == .stopped {
                Text("已停止回复；已经完成的操作不会因此撤销。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let results = turn.confirmationResults, !results.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.title).font(.subheadline.weight(.semibold))
                            Text(result.state.label).font(.caption.weight(.semibold))
                                .foregroundStyle(result.state == .failed ? Color.red : .secondary)
                            Text(result.message).font(.footnote).textSelection(.enabled)
                            proposalSource(result.requestTurnID)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        if index < results.count - 1 { RowDivider(inset: 14) }
                    }
                }
                .glassCard(radius: 18)
                .padding(.trailing, 40)
            }
            ForEach(Array(turn.additionalReceipts.enumerated()), id: \.offset) { _, line in
                Text(line).font(.footnote)
                    .foregroundStyle(line.hasPrefix("✗") ? Color.red : .secondary)
                    .textSelection(.enabled).padding(.leading, 6)
            }
            ForEach(Array(turn.localHealthResults.enumerated()), id: \.offset) { _, line in
                Text(line).font(.footnote)
                    .foregroundStyle(line.hasPrefix("✗") ? Color.red : .secondary)
                    .textSelection(.enabled).privacySensitive().padding(.leading, 6)
            }
        }
    }

    private func proposalSource(_ id: UUID?) -> some View {
        let text: String
        if let id, let source = chat.turns.first(where: { $0.id == id }) { text = "来源请求：" + source.question }
        else { text = id == nil ? "旧提案：未记录来源请求" : "来源请求当前不可用" }
        return Text(text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
        let blocked = chat.working || hasOtherWork || loadingAttachments
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(pending.enumerated()), id: \.element.id) { index, change in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(index + 1). \(change.title)").font(.body.weight(.medium))
                        if let detail = change.detail {
                            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text("待你确认 · 尚未执行").font(.caption).foregroundStyle(.secondary)
                        proposalSource(change.requestTurnID)
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
                    Button { chat.discard(ids: [change.id]) } label: {
                        Image(systemName: "minus.circle.fill").font(.title3).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(blocked)
                    .accessibilityLabel("去掉\(change.title)")
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                if index < pending.count - 1 { RowDivider(inset: 18) }
            }
            Text(blocked ? "正在处理，请稍后核对确认；卡片中的待确认项尚未执行。"
                 : "可点确认，也可以说“确认”或“确认第2项”")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 10)
            HStack(spacing: 10) {
                Button("取消") { chat.discard(ids: Set(pending.map(\.id))) }
                    .buttonStyle(QuietButtonStyle())
                Button(pending.count == 1 ? "确认" : "确认 \(pending.count) 项") { chat.confirm(ids: Set(pending.map(\.id))) }
                    .buttonStyle(AccentButtonStyle())
            }
            .disabled(blocked)
            .padding(12)
        }
        .glassCard()
        .padding(.trailing, 32)
    }

}
