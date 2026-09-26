import SwiftUI
import SwiftData

/// 录入 → 追问 → 核对. One full-screen cover; the coordinator owns the plan, this view owns the mic.
struct CaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var coordinator: InventoryInputCoordinator?
    @State private var voice = VoiceManager()
    @State private var mode: Mode = .listening
    @State private var typed = ""
    @State private var carriedText = ""
    @State private var lastSubmitted = ""
    @State private var heard: [HeardItem] = []
    @State private var notice: String?
    @State private var startedAt = Date.now
    @FocusState private var typingFocused: Bool

    enum Mode { case listening, typing }

    struct HeardItem: Identifiable, Equatable {
        let id: String
        let name: String
        let quantity: Int
        let glyph: Character
        let needsQuestion: Bool
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.ground.ignoresSafeArea()
            if let coordinator, coordinator.state == .reviewing || coordinator.state == .executing {
                ReviewView(coordinator: coordinator, onAddMore: addMore, onBack: { coordinator.reset(); restart() })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                capture
                if let coordinator, coordinator.state == .clarifying, let question = coordinator.questions.first {
                    Color.black.opacity(0.38).ignoresSafeArea()
                        .transition(.opacity)
                    ClarifySheet(coordinator: coordinator, question: question)
                        .id(question)
                        .transition(.move(edge: .bottom))
                }
            }
        }
        .animation(.snappy(duration: 0.35), value: coordinator?.state)
        .animation(.snappy(duration: 0.35), value: coordinator?.questions.count)
        .task { await prepare() }
        .onChange(of: voice.transcribedText) { _, text in Task { await preview(text) } }
        .onChange(of: coordinator?.state) { _, state in
            if state == .completed {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                // Ask for reminders only once there is something worth reminding about.
                Task { await NotificationManager.shared.requestAuthorization() }
                dismiss()
            }
        }
        .onDisappear { voice.cancel() }
    }

    // MARK: Capture screen

    private var capture: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("取消") { voice.cancel(); dismiss() }
                    .font(Theme.display(16, weight: .regular))
                    .foregroundStyle(Theme.inkSoft)
                Spacer()
                Label("只在这台手机上识别", systemImage: "lock.fill")
                    .font(Theme.body(12, weight: .medium))
                    .foregroundStyle(Theme.cobalt)
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.surface))
            }
            .padding(.top, 6)

            transcript
                .padding(.top, 48)

            if !heard.isEmpty {
                heardRow
                    .padding(.top, 36)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            controls
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Eyebrow(statusTitle)
                if mode == .listening, voice.state == .recording {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        let seconds = Int(context.date.timeIntervalSince(startedAt))
                        Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                            .font(Theme.numeral(16))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
            if mode == .typing {
                TextField("", text: $typed, prompt: Text("买了一瓶牛奶，还有三包方便面").foregroundStyle(Theme.faint), axis: .vertical)
                    .font(Theme.display(26, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(10)
                    .focused($typingFocused)
                    .onChange(of: typed) { _, text in Task { await preview(text) } }
            } else {
                let spoken = [carriedText, voice.transcribedText].filter { !$0.isEmpty }.joined(separator: "，")
                Text(spoken.isEmpty ? "说说今天买了什么…" : spoken)
                    .font(Theme.display(27, weight: .medium))
                    .foregroundStyle(spoken.isEmpty ? Theme.faint : Theme.ink)
                    .lineSpacing(12)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            if let notice {
                Text(notice)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.vermilion)
            }
            if let message = coordinator?.errorMessage, coordinator?.state == .failed {
                Text(message)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.vermilion)
            }
        }
    }

    private var statusTitle: String {
        if coordinator?.state == .planning { return "正在整理" }
        if coordinator?.state == .failed { return "没太听懂" }
        return mode == .typing ? "写下来" : (voice.state == .recording ? "正在听" : "准备好了")
    }

    private var statusColor: Color {
        mode == .listening && voice.state == .recording ? Theme.vermilion : Theme.cobalt
    }

    private var heardRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("已经记住", color: Theme.muted)
            HStack(alignment: .top, spacing: 22) {
                ForEach(heard) { item in
                    VStack(spacing: 8) {
                        SealView(glyph: item.glyph, style: item.needsQuestion ? .solid : .quiet, size: 52,
                                 tilt: item == heard.last ? -6 : 0)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(item.name)
                                .font(Theme.body(12, weight: item.needsQuestion ? .semibold : .regular))
                                .foregroundStyle(item.needsQuestion ? Theme.cobalt : Theme.inkSoft)
                                .lineLimit(1)
                            Text("×\(item.quantity)")
                                .font(Theme.numeral(15))
                                .foregroundStyle(item.needsQuestion ? Theme.cobalt : Theme.muted)
                        }
                    }
                    .frame(maxWidth: 72)
                    .transition(.scale(scale: 1.3).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: heard)
            if let asking = heard.first(where: \.needsQuestion) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.cobalt).frame(width: 5, height: 5)
                    Text("\(asking.name)有一处要问你，等你说完")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.cobalt)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(alignment: .center) {
            sideButton(mode == .typing ? "说话" : "打字", systemImage: mode == .typing ? "mic" : "keyboard") {
                mode == .typing ? switchToVoice() : switchToTyping()
            }
            Spacer()
            mainButton
            Spacer()
            sideButton("重来", systemImage: "arrow.counterclockwise") { restart() }
                .opacity(heard.isEmpty && typed.isEmpty ? 0.35 : 1)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var mainButton: some View {
        let planning = coordinator?.state == .planning
        Button(action: finish) {
            ZStack {
                Circle().strokeBorder(Theme.hairline, lineWidth: 1).frame(width: 148, height: 148)
                Circle().strokeBorder(Theme.cobalt.opacity(0.25), lineWidth: 1.5).frame(width: 118, height: 118)
                    .scaleEffect(voice.state == .recording ? 1.04 : 1)
                    .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: voice.state == .recording)
                Circle().fill(Theme.cobaltFill).frame(width: 86, height: 86)
                if planning {
                    ProgressView().tint(.white)
                } else if mode == .listening && voice.state == .recording {
                    RoundedRectangle(cornerRadius: 5).fill(.white).frame(width: 22, height: 22)
                } else {
                    Image(systemName: mode == .typing ? "arrow.up" : "mic.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(planning)
        .accessibilityLabel(mode == .listening && voice.state == .recording ? "说完了" : "整理一下")
    }

    private func sideButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.ink)
                Text(title)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.muted)
            }
            .frame(width: 64)
        }
        .buttonStyle(.plain)
    }

    // MARK: Flow

    private func prepare() async {
        if coordinator == nil {
            let container = modelContext.container
            coordinator = InventoryInputCoordinator(
                provider: LocalInventoryPlanProvider(),
                lookup: CatalogProductLookup(modelContainer: container),
                repository: InventoryRepository(modelContainer: container)
            )
        }
        #if DEBUG
        if let scripted = ProcessInfo.processInfo.environment["BUTLER_CAPTURE_TEXT"], !scripted.isEmpty {
            typed = scripted
            mode = .typing
            finish()
            return
        }
        #endif
        await startListening()
    }

    private func startListening() async {
        notice = nil
        guard await voice.requestAuthorization() else {
            switchToTyping(note: "没有麦克风权限，先打字吧")
            return
        }
        do {
            try voice.startRecording(requiresOnDeviceRecognition: true)
            startedAt = .now
            mode = .listening
        } catch {
            switchToTyping(note: (error as? LocalizedError)?.errorDescription ?? "语音暂时用不了，先打字吧")
        }
    }

    private func switchToTyping(note: String? = nil) {
        let spoken = [carriedText, voice.transcribedText].filter { !$0.isEmpty }.joined(separator: "，")
        if mode == .listening { typed = spoken }
        carriedText = ""
        voice.cancel()
        mode = .typing
        notice = note
        typingFocused = true
    }

    private func switchToVoice() {
        carriedText = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        typingFocused = false
        Task { await startListening() }
    }

    private func finish() {
        guard let coordinator else { return }
        if mode == .listening && voice.state == .recording {
            Task {
                let spoken = await voice.stopRecordingAndTranscribe() ?? ""
                let text = [carriedText, spoken].filter { !$0.isEmpty }.joined(separator: "，")
                guard !text.isEmpty else { notice = "没听清，再说一次？"; await startListening(); return }
                lastSubmitted = text
                await coordinator.submit(text: text)
            }
        } else if mode == .typing {
            let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            typingFocused = false
            lastSubmitted = text
            Task { await coordinator.submit(text: text) }
        } else {
            Task { await startListening() }
        }
    }

    /// "漏了什么？接着说": keep everything said so far and keep talking.
    private func addMore() {
        coordinator?.reset()
        if mode == .typing {
            typed = lastSubmitted + "，"
            typingFocused = true
        } else {
            carriedText = lastSubmitted
            Task { await startListening() }
        }
    }

    private func restart() {
        voice.cancel()
        carriedText = ""
        typed = ""
        heard = []
        coordinator?.reset()
        if mode == .listening { Task { await startListening() } }
    }

    /// Runs the same local planner on the partial text so seals "land" while the user talks.
    private func preview(_ partial: String) async {
        let text = mode == .typing ? typed : [carriedText, partial].filter { !$0.isEmpty }.joined(separator: "，")
        guard !text.isEmpty else { heard = []; return }
        let input = InventoryPlanningInput(text: text, locale: .current, referenceDate: .now,
                                           timeZone: .current, inputID: UUID(), planID: UUID())
        guard let plan = try? await LocalInventoryPlanProvider().plan(for: input) else { return }
        var items: [HeardItem] = []
        for planned in plan.operations {
            guard case .addLot(let lot) = planned.operation,
                  let name = plan.operations.lazy.compactMap({ op -> String? in
                      if case .createProduct(let product) = op.operation, product.productID == lot.productID { return product.canonicalName }
                      return nil
                  }).first else { continue }
            let asks = plan.unresolvedFields.contains { $0.entityID == lot.lotID }
            let isMedicine = LotGlyph.isMedicine(name: name, category: nil)
            items.append(HeardItem(id: "\(name)#\(items.count)", name: name, quantity: lot.quantity,
                                   glyph: LotGlyph.glyph(for: name, isMedicine: isMedicine), needsQuestion: asks))
        }
        if items != heard { heard = items }
    }
}
