import CoreHaptics
import SwiftUI

@MainActor
protocol VoicePressRecording: AnyObject {
    var text: String { get }
    var error: String? { get }
    var finalizationTimeout: Duration { get }
    func start(ready: @escaping () -> Void) async -> Bool
    func stop() async -> String
    func cancel()
}

extension VoicePressRecording {
    var finalizationTimeout: Duration { .seconds(3) }
}

@MainActor
final class LiveVoicePressRecorder: VoicePressRecording {
    let dictation = LiveDictation()
    var text: String { dictation.text }
    var error: String? { dictation.error }
    var finalizationTimeout: Duration { dictation.finalizationTimeout }
    func start(ready: @escaping () -> Void) async -> Bool {
        await dictation.start(after: "", onRecordingStarted: ready)
        return dictation.listening
    }
    func stop() async -> String { await dictation.stop() }
    func cancel() { dictation.cancel() }
    nonisolated deinit {}
}

@MainActor
protocol VoicePressFeedback: AnyObject {
    func begin()
    func fade()
    func stop()
    func boundary()
}

/// One continuous event, never a second impact at microphone readiness.
@MainActor
final class ContinuousPressFeedback: VoicePressFeedback {
    private var engine: CHHapticEngine?
    private var player: (any CHHapticPatternPlayer)?
    private var preparedPlayer: (any CHHapticPatternPlayer)?
    private var engineReady = false
    private var generation = UUID()
    private var beganAt = 0.0
    private let fallback = UIImpactFeedbackGenerator(style: .soft)
    private let selection = UISelectionFeedbackGenerator()
    nonisolated deinit {}

    func prepare() {
        fallback.prepare()
        selection.prepare()
        guard engine == nil, CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        let token = UUID()
        generation = token
        do {
            let engine = try CHHapticEngine(audioSession: nil)
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = false
            self.engine = engine
            engine.stoppedHandler = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.engineReady = false
                    self.player = nil
                    self.preparedPlayer = nil
                    // Do not restart a sensation halfway through a press.
                    self.restart(token: token)
                }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.engineReady = false
                    self.player = nil
                    self.preparedPlayer = nil
                    self.restart(token: token)
                }
            }
            restart(token: token)
        } catch { self.engine = nil }
    }

    private func restart(token: UUID) {
        engine?.start { [weak self] error in
            let succeeded = error == nil
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.engineReady = succeeded
                if succeeded { self.preparePlayer() }
            }
        }
    }

    private func preparePlayer() {
        guard engineReady, preparedPlayer == nil, let engine else { return }
        do {
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                .init(parameterID: .hapticIntensity, value: 1),
                .init(parameterID: .hapticSharpness, value: 0.25)
            ], relativeTime: 0, duration: 0.8)
            let curve = CHHapticParameterCurve(parameterID: .hapticIntensityControl,
                controlPoints: PressFeedbackEnvelope.points.map {
                    .init(relativeTime: $0.time, value: $0.intensity)
                }, relativeTime: 0)
            preparedPlayer = try engine.makePlayer(with: CHHapticPattern(events: [event], parameterCurves: [curve]))
        } catch {
            ChatDiagnostics.log("voice trial: player preparation failed")
        }
    }

    func begin() {
        // No engine startup, pattern creation, or player allocation on the touch-down path.
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        beganAt = ProcessInfo.processInfo.systemUptime
        guard engineReady, let next = preparedPlayer else {
            fallback.impactOccurred(intensity: 0.85)
            ChatDiagnostics.log("voice trial: immediate fallback feedback")
            return
        }
        preparedPlayer = nil
        do {
            try next.start(atTime: CHHapticTimeImmediate)
            player = next
            let elapsed = (ProcessInfo.processInfo.systemUptime - beganAt) * 1000
            ChatDiagnostics.log("voice trial: prepared player start returned in \(String(format: "%.1f", elapsed))ms")
        } catch {
            // Do not queue a second impact or replay later in this press.
            ChatDiagnostics.log("voice trial: prepared player start failed")
        }
    }

    func fade() {
        guard let player else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - beganAt
        guard elapsed < 0.8 else { stop(); return }
        let level = PressFeedbackEnvelope.intensity(at: elapsed)
        do {
            try player.scheduleParameterCurve(CHHapticParameterCurve(
                parameterID: .hapticIntensityControl, controlPoints: [
                    .init(relativeTime: 0, value: Float(level)),
                    .init(relativeTime: 0.045, value: 0)
                ], relativeTime: 0), atTime: CHHapticTimeImmediate)
            // Keep the player until release so cancellation always stops it synchronously.
            if let engine { try player.stop(atTime: engine.currentTime + 0.05) }
        } catch { stop() }
    }

    func stop() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        preparePlayer()
        fallback.prepare()
    }
    func boundary() { selection.selectionChanged(); selection.prepare() }
    func suspend() {
        generation = UUID()
        engineReady = false
        stop()
        preparedPlayer = nil
        engine?.stoppedHandler = { _ in }
        engine?.resetHandler = {}
        engine?.stop(completionHandler: nil)
        engine = nil
    }
}

/// An immediate, distinct onset settling into the same continuous event, without a second pulse.
enum PressFeedbackEnvelope {
    static let points: [(time: Double, intensity: Float)] = [
        (0, 0.60), (0.04, 0.40), (0.45, 0.44), (0.65, 0.44), (0.8, 0)
    ]
    static func intensity(at time: Double) -> Float {
        for (left, right) in zip(points, points.dropFirst()) where time <= right.time {
            let fraction = Float(max(0, time - left.time) / (right.time - left.time))
            return left.intensity + (right.intensity - left.intensity) * fraction
        }
        return 0
    }
}

/// Shared by the dock and trial page. Tap and hold commit to mutually exclusive actions.
@MainActor @Observable
final class VoicePressInteraction {
    enum Phase { case idle, preparing, recording, finishing }
    private(set) var phase: Phase = .idle
    private(set) var cancelling = false
    private(set) var message = "按住下方水晶球试着说句话"
    private(set) var attempts = 0
    private(set) var voiceCommitted = false
    private(set) var issue: String?
    private var pressedAt: TimeInterval = 0
    private var movedBeyondTap = false
    private var onTap: (() -> Void)?
    private var onVoice: (() -> Void)?
    private var onTranscript: ((String) -> Void)?
    private let now: () -> TimeInterval
    private let recorder: any VoicePressRecording
    private let feedback: any VoicePressFeedback
    private var session: UUID?
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private let holdDelay: Duration
    private let prepareLimit: Duration
    private let finishLimit: Duration?
    var held: Bool { phase == .preparing || phase == .recording }
    nonisolated deinit {}

    init(recorder: any VoicePressRecording, feedback: any VoicePressFeedback,
         holdDelay: Duration = .milliseconds(300), prepareLimit: Duration = .seconds(5),
         finishLimit: Duration? = nil, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.recorder = recorder
        self.feedback = feedback
        self.holdDelay = holdDelay
        self.prepareLimit = prepareLimit
        self.finishLimit = finishLimit
        self.now = now
    }

    func begin(onTap: (() -> Void)? = nil, onVoice: (() -> Void)? = nil, onTranscript: ((String) -> Void)? = nil) {
        guard phase == .idle else { return }
        feedback.begin()
        self.onTap = onTap
        self.onVoice = onVoice
        self.onTranscript = onTranscript
        pressedAt = now()
        voiceCommitted = false
        movedBeyondTap = false
        issue = nil
        let token = UUID()
        session = token
        attempts += 1
        phase = .preparing
        cancelling = false
        message = "正在准备麦克风…"
        ChatDiagnostics.log("voice trial: press began \(attempts)")
        deadline = Task { [weak self, prepareLimit] in
            do { try await Task.sleep(for: prepareLimit) } catch { return }
            guard let self, self.session == token, self.phase == .preparing else { return }
            self.cancel(message: "麦克风准备时间太长，请松手重试")
        }
        work = Task { [weak self, holdDelay] in
            do { try await Task.sleep(for: holdDelay) } catch { return }
            guard let self, self.session == token else { return }
            self.voiceCommitted = true
            self.onVoice?()
            let started = await self.recorder.start { [weak self] in
                guard let self, self.session == token, self.phase == .preparing else { return }
                self.deadline?.cancel()
                self.phase = .recording
                self.message = "说吧，松手结束"
                self.feedback.fade()
                ChatDiagnostics.log("voice trial: microphone ready")
            }
            guard self.session == token, !Task.isCancelled else { return }
            if !started { self.cancel(message: self.recorder.error ?? "麦克风未能启动，请重试") }
        }
    }

    func move(y: CGFloat) {
        move(translation: CGSize(width: 0, height: y))
    }

    func move(translation: CGSize) {
        guard held else { return }
        if hypot(translation.width, translation.height) > 12 { movedBeyondTap = true }
        let y = translation.height
        let next = y < (cancelling ? -64 : -84)
        guard next != cancelling else { return }
        cancelling = next
        // A boundary is the only distinct selection tick during a press.
        feedback.boundary()
    }

    func release() {
        guard held else { return }
        let elapsed = now() - pressedAt
        let threshold = Double(holdDelay.components.seconds) + Double(holdDelay.components.attoseconds) / 1e18
        if !voiceCommitted && !movedBeyondTap && !cancelling && elapsed < threshold {
            let tap = onTap
            cancel()
            tap?()
            return
        }
        if cancelling { cancel(); return }
        guard phase == .recording else {
            cancel(message: voiceCommitted || elapsed >= threshold ? "语音还没准备好，请再次按住说话。" : nil)
            return
        }
        feedback.stop()
        deadline?.cancel()
        phase = .finishing
        message = "正在整理刚才的话…"
        let token = session
        let finishLimit = finishLimit ?? recorder.finalizationTimeout
        deadline = Task { [weak self, finishLimit] in
            do { try await Task.sleep(for: finishLimit) } catch { return }
            guard let self, self.session == token, self.phase == .finishing else { return }
            let text = self.recorder.text
            self.cancel(message: text.isEmpty ? "整理超时，请重试" : "未发送：\(text)")
        }
        work = Task { [weak self] in
            guard let self else { return }
            let text = await self.recorder.stop().trimmingCharacters(in: .whitespacesAndNewlines)
            guard self.session == token, !Task.isCancelled else { return }
            self.deadline?.cancel()
            self.session = nil
            self.phase = .idle
            self.voiceCommitted = false
            self.message = self.recorder.error ?? (text.isEmpty ? "没有听清，再试一次" : text)
            self.issue = self.recorder.error != nil || text.isEmpty ? self.message : nil
            let deliver = self.onTranscript
            self.onTap = nil; self.onVoice = nil; self.onTranscript = nil
            if !text.isEmpty, self.issue == nil { deliver?(text) }
        }
    }

    func cancel(message: String? = nil) {
        session = nil
        work?.cancel(); work = nil
        deadline?.cancel(); deadline = nil
        feedback.stop()
        recorder.cancel()
        phase = .idle
        voiceCommitted = false
        cancelling = false
        self.message = message ?? "已取消，可以再次按住"
        self.issue = message
        onTap = nil; onVoice = nil; onTranscript = nil
        ChatDiagnostics.log("voice trial: cleared, ready for next press")
    }

    func dismissIssue() { issue = nil }
}
