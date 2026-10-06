import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

extension ButlerChatView {
    // MARK: - Composer (floating Liquid Glass)

    var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let attachmentNotice {
                Text(attachmentNotice).font(.footnote).foregroundStyle(.secondary)
                    .textSelection(.enabled).padding(.horizontal, 8)
                if hasImportedFiles, chat.scope != .general, let onGeneralChat {
                    Button("前往通用对话查看资料", action: onGeneralChat)
                        .frame(minHeight: 44)
                }
            }
            // Storage/confirmation errors may not have an answer bubble at all.
            if let error = chat.error, !(chat.turns.last?.failed == true && chat.turns.last?.answer == error) {
                Text(error).font(.footnote).foregroundStyle(.red)
                    .textSelection(.enabled).padding(.horizontal, 8)
            }
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
            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    Menu {
                        Button { showingCamera = true } label: { Label("拍照", systemImage: "camera") }
                        Button { showingLibrary = true } label: { Label("照片图库", systemImage: "photo.on.rectangle") }
                        Button { showingFiles = true } label: { Label("选择文件", systemImage: "folder") }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 19, weight: .regular)).frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .disabled(voiceSession.phase != .idle || loadingAttachments || chat.working || hasOtherWork)
                    .accessibilityLabel("添加照片或文件")

                    inputField
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

    /// Like Messages: a capsule as tall as the ＋ button, text centred on one line and growing upwards
    /// when it wraps; one plain glyph at the right (waveform to talk, ↑ to send).
    private var inputField: some View {
        HStack(alignment: .bottom, spacing: 4) {
            TextField(placeholder, text: $chat.draft, axis: .vertical)
                .font(.body)
                .lineLimit(1...10)
                .focused($composing)
                // Recognition owns this draft until its last result is finalized.
                // Never overwrite a manual edit with a late partial transcript.
                .disabled(!composerPolicy.canEditText)
                .padding(.leading, 16)
                .padding(.vertical, 9)
            trailingButton
                .padding(.trailing, 4)
                .padding(.bottom, 4)
        }
        .frame(minHeight: 40)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var composerPolicy: ChatComposerPolicy {
        ChatComposerPolicy(draft: chat.draft, photoCount: chat.photos.count + (loadingAttachments ? 1 : 0),
                           working: chat.working, voicePhase: voiceSession.phase)
    }

    private var placeholder: String {
        switch voiceSession.phase {
        case .preparing: "正在准备语音…"
        case .listening: "正在听，说完点红色按钮"
        case .finishing: "正在整理最后一句…"
        case .idle: "和管家说…"
        }
    }

    private var composerHint: String? {
        switch voiceSession.phase {
        // The input's own placeholder already says what the voice is doing; no second line.
        case .preparing, .listening, .finishing: return nil
        case .idle: break
        }
        if loadingAttachments { return "正在读取附件…" }
        if chat.draft.count > 8_000 { return "内容超过 8,000 字，请分成几条发送。" }
        if composerPolicy.hasContent, !chat.connection.isLoggedIn, !chat.canSend { return "请先在管家设置里登录，草稿会保留。" }
        if composerPolicy.hasContent, chat.tools == nil { return "暂时无法读取本机资料，草稿已保留。" }
        return nil
    }

    /// Inside the input, bottom right, drawn the way Messages does: a plain waveform to start talking,
    /// a filled ↑ to send, a red stop while listening, a small spinner while getting ready or finishing.
    @ViewBuilder
    private var trailingButton: some View {
        switch composerPolicy.action {
        case .stopResponse:
            composerButton(label: "停止生成") { chat.stop() } content: {
                Image(systemName: "stop.circle.fill").font(.system(size: 28)).foregroundStyle(.secondary)
            }
        case .cancelPreparation:
            composerButton(label: "取消准备语音") { cancelListening() } content: { ProgressView().controlSize(.small) }
        case .stopDictation:
            composerButton(label: "停止听写") { stopListening() } content: {
                Image(systemName: "stop.circle.fill").font(.system(size: 28)).foregroundStyle(.white, .red)
            }
        case .finishDictation:
            composerButton(label: "保留当前文字并结束语音收尾") { cancelListening() } content: { ProgressView().controlSize(.small) }
        case .send:
            composerButton(label: "发送") {
                guard chat.canSend, !loadingAttachments, voiceSession.phase == .idle else { return }
                let previous = chat.turns.last?.id
                chat.send()
                if chat.turns.last?.id != previous { composing = false }
            } content: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                    .foregroundStyle(accent.onFill, accent.fill)
            }
            .disabled(!chat.canSend || loadingAttachments)
            .opacity(chat.canSend && !loadingAttachments ? 1 : 0.35)
        case .voice:
            composerButton(label: "开始语音输入") { startListening() } content: {
                Image(systemName: "waveform").font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
            }
            .disabled(loadingAttachments)
        }
    }

    private func composerButton<Content: View>(label: String, action: @escaping () -> Void,
                                               @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content().frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    func startListening() {
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

    func cancelListening() {
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
