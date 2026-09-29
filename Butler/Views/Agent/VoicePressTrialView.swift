import SwiftUI

/// Isolated from the chat dock: a trial never sends a message or changes user data.
struct VoicePressTrialView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recorder: LiveVoicePressRecorder
    @State private var feedback: ContinuousPressFeedback
    @State private var trial: VoicePressInteraction
    @State private var handsFree = false

    init() {
        let recorder = LiveVoicePressRecorder()
        let feedback = ContinuousPressFeedback()
        _recorder = State(initialValue: recorder)
        _feedback = State(initialValue: feedback)
        _trial = State(initialValue: VoicePressInteraction(recorder: recorder, feedback: feedback))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("按住说话 · 触感试用")
                    .font(.title2.weight(.medium))
                Text("按下即有反馈，收音时自然收尾。\n上滑取消，松手结束。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
                Text(trial.cancelling ? "松开取消" : displayText)
                    .font(.title3)
                    .foregroundStyle(trial.cancelling ? .red : .primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .accessibilityIdentifier("voiceTrialStatus")
                if trial.phase == .finishing && recorder.dictation.usesCustomService {
                    Button("取消识别") { trial.cancel() }
                }
                Spacer()
                Text(trial.held ? "↑ 上滑取消" : " ")
                    .foregroundStyle(trial.cancelling ? .red : .secondary)
                    .font(.callout)
                ButlerOrb(size: 76, pressure: trial.held ? 0.18 : 0, contact: CGPoint(x: 0, y: -1))
                    .scaleEffect(x: trial.held ? 1.035 : 1, y: trial.held ? 0.96 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: trial.held)
                    .frame(width: 112, height: 112)
                    .overlay {
                        HStack(spacing: 104) { meter; meter }
                            .allowsHitTesting(false)
                    }
                    .overlay {
                        VoicePressControl(
                            onDown: {
                                if handsFree { handsFree = false; trial.cancel() }
                                trial.begin()
                                return trial.held
                            },
                            onMove: { trial.move(translation: $0) },
                            onUp: { trial.release() },
                            onCancel: { trial.cancel(); handsFree = false },
                            onActivate: {
                                if handsFree { trial.release(); handsFree = false }
                                else { trial.begin(); handsFree = trial.held }
                            })
                    }
                Text("语音仅在此页显示，不发送给管家。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("已试用 \(trial.attempts) 次")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 32)
            .padding(.bottom, 32)
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .onAppear { feedback.prepare() }
        .onDisappear { reset(); feedback.suspend() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { feedback.prepare() }
            else { reset(); feedback.suspend() }
        }
        .onChange(of: recorder.dictation.error) { _, error in
            if let error, trial.held { trial.cancel(message: error) }
        }
    }

    private var displayText: String {
        trial.phase == .recording && !recorder.dictation.text.isEmpty ? recorder.dictation.text : trial.message
    }

    private var meter: some View {
        HStack(spacing: 4) {
            ForEach(0..<4) { index in
                Capsule().fill(trial.cancelling ? Color.red : Color.primary.opacity(0.6))
                    .frame(width: 3, height: 3 + CGFloat(recorder.dictation.audioLevel) * CGFloat(34 - index * 6))
            }
        }
        .opacity(trial.phase == .recording ? 1 : 0)
    }

    private func reset() {
        handsFree = false
        trial.cancel()
    }
}
