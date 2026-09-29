import AVFoundation
import Observation
import Speech

/// Continuous Chinese dictation for the chat box. Finished sentences accumulate and only the
/// sentence in progress is rewritten, so nothing already said disappears while talking.
/// Uses the iOS 26 long-form speech analyzer; falls back to the classic recognizer (server mode).
@MainActor @Observable
final class LiveDictation {
    private(set) var listening = false
    private(set) var preparing = false
    /// Smoothed microphone energy, normalized to 0...1 for the voice light.
    private(set) var audioLevel: CGFloat = 0
    /// What was in the box before listening, plus everything heard so far.
    private(set) var text = ""
    var error: String?

    /// When the owner asked for dictation, for the timing record (uptime seconds).
    var askedAt: TimeInterval?
    private var firstWordLogged = false
    private var base = ""
    private var finalized = ""
    private var volatile = ""
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    /// Brings the recognizer up while the microphone is already recording; resolves when it has caught up.
    private var recognizerSetup: Task<Void, Never>?
    private var relay: AudioRelay?
    private var legacyRequest: SFSpeechAudioBufferRecognitionRequest?
    private var legacyTask: SFSpeechRecognitionTask?
    private var sessionID: UUID?
    private var tapInstalled = false

    nonisolated deinit {}

    static let locale = Locale(identifier: "zh-CN")

    func start(after existing: String) async {
        guard sessionID == nil, !Task.isCancelled else { return }
        askedAt = ProcessInfo.processInfo.systemUptime
        firstWordLogged = false
        let id = UUID()
        sessionID = id
        error = nil
        preparing = true
        await withTaskCancellationHandler {
            await prepare(after: existing, session: id)
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == id else { return }
                self.cancel()
            }
        }
    }

    private func checkSession(_ id: UUID) throws {
        try Task.checkCancellation()
        guard sessionID == id else { throw CancellationError() }
    }

    /// The microphone starts as soon as permission and the audio session allow it. Everything heard from then on is
    /// kept, and handed to the recognizer once it is ready, so the first words are never lost to start-up time.
    private func prepare(after existing: String, session id: UUID) async {
        defer { if sessionID == id { preparing = false } }
        do {
            let authorized = await authorize(session: id)
            try checkSession(id)
            guard authorized else {
                error = "没有麦克风或语音识别权限，可以在系统设置里打开。"
                preparing = false
                sessionID = nil
                return
            }
            base = existing
            finalized = ""
            volatile = ""
            text = base
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let relay = AudioRelay()
            self.relay = relay
            let natural = engine.inputNode.outputFormat(forBus: 0)
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: natural,
                                        block: Self.captureTap(relay, meter: makeMeter(session: id)))
            tapInstalled = true
            engine.prepare()
            try checkSession(id)
            try engine.start()
            listening = true
            preparing = false
            ChatDiagnostics.log("voice: recording began \(elapsed())s after the request")
            recognizerSetup = Task { [weak self] in
                await self?.bringUpRecognizer(session: id, relay: relay, natural: natural)
            }
        } catch {
            guard sessionID == id else { return }
            let cancelled = error is CancellationError || Task.isCancelled
            cancel()
            if !cancelled { self.error = "语音识别没能启动，先打字吧。" }
        }
    }

    private func elapsed() -> String {
        String(format: "%.2f", ProcessInfo.processInfo.systemUptime - (askedAt ?? ProcessInfo.processInfo.systemUptime))
    }

    private func bringUpRecognizer(session id: UUID, relay: AudioRelay, natural: AVAudioFormat) async {
        do {
            do {
                try await startAnalyzer(session: id, relay: relay, natural: natural)
            } catch {
                try checkSession(id)
                if error is CancellationError { throw error }
                teardownRecognizer()
                try startLegacy(session: id, relay: relay)
            }
            try checkSession(id)
            ChatDiagnostics.log("voice: recognizer caught up \(elapsed())s after the request")
        } catch {
            guard sessionID == id else { return }
            if error is CancellationError || Task.isCancelled { return }
            cancel()
            self.error = "语音识别没能启动，先打字吧。"
        }
    }

    /// Stops listening and returns the full text once the last sentence is finalized.
    @discardableResult
    func stop() async -> String {
        guard listening, let id = sessionID else {
            if preparing { cancel() }
            return text
        }
        let stoppedText = text
        listening = false
        audioLevel = 0
        engine.stop()
        removeTap()
        // What was heard while the recognizer was still starting is replayed to it first.
        await recognizerSetup?.value
        guard sessionID == id else { return stoppedText }
        input?.finish()
        legacyRequest?.endAudio()
        if let analyzer { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        guard sessionID == id else { return stoppedText }
        if legacyTask != nil { try? await Task.sleep(for: .milliseconds(500)) }
        guard sessionID == id else { return stoppedText }
        await resultsTask?.value
        guard sessionID == id else { return stoppedText }
        teardown()
        sessionID = nil
        text = base + finalized + volatile
        return text
    }

    func cancel() {
        sessionID = nil
        listening = false
        preparing = false
        teardown()
    }

    // MARK: - Speech analyzer (iOS 26)

    private func startAnalyzer(session id: UUID, relay: AudioRelay, natural: AVAudioFormat) async throws {
        let module: any SpeechModule
        if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Self.locale) {
            try checkSession(id)
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            module = transcriber
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard !Task.isCancelled, self?.sessionID == id else { return }
                        self?.heard(String(result.text.characters), final: result.isFinal)
                    }
                } catch {
                    guard !Task.isCancelled, self?.sessionID == id else { return }
                    self?.failed(session: id)
                }
            }
        } else {
            try checkSession(id)
            let locale = await DictationTranscriber.supportedLocale(equivalentTo: Self.locale)
            try checkSession(id)
            guard let locale else { throw VoiceError.setupFailed }
            let transcriber = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                                   reportingOptions: [.volatileResults, .frequentFinalization],
                                                   attributeOptions: [])
            module = transcriber
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard !Task.isCancelled, self?.sessionID == id else { return }
                        self?.heard(String(result.text.characters), final: result.isFinal)
                    }
                } catch {
                    guard !Task.isCancelled, self?.sessionID == id else { return }
                    self?.failed(session: id)
                }
            }
        }
        // First use: the Chinese speech model isn't on the phone yet. Download it in the background
        // and listen right away with the classic recognizer; next time the new one is ready.
        let status = await AssetInventory.status(forModules: [module])
        try checkSession(id)
        guard status == .installed else {
            resultsTask?.cancel()
            resultsTask = nil
            Task.detached {
                if let request = try? await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    try? await request.downloadAndInstall()
                }
            }
            throw VoiceError.setupFailed
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        input = continuation
        let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        try checkSession(id)
        try await analyzer.prepareToAnalyze(in: target)
        try checkSession(id)
        try await analyzer.start(inputSequence: stream)
        try checkSession(id)
        // Levels are already measured by the capture tap; this side only converts and forwards.
        let convert = Self.analyzerTap(from: natural, to: target, into: continuation, meter: MicrophoneMeter { _ in })
        relay.attach { buffer in convert(buffer, AVAudioTime(sampleTime: 0, atRate: natural.sampleRate)) }
    }

    /// Runs on the audio thread: converts mic buffers to the analyzer's format.
    nonisolated private static func analyzerTap(from source: AVAudioFormat, to target: AVAudioFormat?,
                                                into continuation: AsyncStream<AnalyzerInput>.Continuation,
                                                meter: MicrophoneMeter) -> AVAudioNodeTapBlock {
        let converter = target.flatMap { $0 == source ? nil : AVAudioConverter(from: source, to: $0) }
        return { buffer, _ in
            meter.consume(buffer)
            guard let converter, let target else {
                continuation.yield(AnalyzerInput(buffer: buffer))
                return
            }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / source.sampleRate) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var delivered = false
            var failure: NSError?
            converter.convert(to: converted, error: &failure) { _, status in
                if delivered {
                    status.pointee = .noDataNow
                    return nil
                }
                delivered = true
                status.pointee = .haveData
                return buffer
            }
            if failure == nil, converted.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: converted)) }
        }
    }

    // MARK: - Classic recognizer fallback

    private func startLegacy(session id: UUID, relay: AudioRelay) throws {
        try checkSession(id)
        guard let recognizer = SFSpeechRecognizer(locale: Self.locale), recognizer.isAvailable else { throw VoiceError.setupFailed }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = false
        legacyRequest = request
        legacyTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let piece = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                guard let self, self.sessionID == id else { return }
                if let piece { self.heardLegacy(piece, final: isFinal) }
                if error != nil, result == nil { self.failed(session: id) }
            }
        }
        try checkSession(id)
        relay.attach { buffer in request.append(buffer) }
    }

    /// Runs on the audio thread: measure the level, and keep the audio for whoever is listening.
    nonisolated private static func captureTap(_ relay: AudioRelay, meter: MicrophoneMeter) -> AVAudioNodeTapBlock {
        { buffer, _ in
            meter.consume(buffer)
            relay.push(buffer)
        }
    }

    nonisolated private static func legacyTap(_ request: SFSpeechAudioBufferRecognitionRequest,
                                              meter: MicrophoneMeter) -> AVAudioNodeTapBlock {
        { buffer, _ in
            meter.consume(buffer)
            request.append(buffer)
        }
    }

    // MARK: - Microphone level

    private func makeMeter(session id: UUID) -> MicrophoneMeter {
        MicrophoneMeter { [weak self] level in
            Task { @MainActor in
                guard let self, self.sessionID == id, self.listening else { return }
                self.audioLevel = level
            }
        }
    }

    /// Only scalar levels cross to the main actor; PCM buffers stay on the audio thread.
    /// The lock protects the smoothing/throttle state if tap callbacks overlap.
    private final class MicrophoneMeter: @unchecked Sendable {
        nonisolated private let lock = NSLock()
        nonisolated private let publish: @Sendable (CGFloat) -> Void
        nonisolated(unsafe) private var smoothed = 0.0
        nonisolated(unsafe) private var lastUpdate = 0.0

        nonisolated init(publish: @escaping @Sendable (CGFloat) -> Void) {
            self.publish = publish
        }

        nonisolated func consume(_ buffer: AVAudioPCMBuffer) {
            // The input node's native PCM format is Float32. Respect its interleaving stride.
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard frames > 0, channelCount > 0 else { return }
            var energy = 0.0
            for channel in 0..<channelCount {
                let samples = buffer.format.isInterleaved ? channels[0] + channel : channels[channel]
                for frame in 0..<frames {
                    let sample = Double(samples[frame * buffer.stride])
                    energy += sample * sample
                }
            }
            let rms = sqrt(energy / Double(frames * channelCount))
            guard rms.isFinite else { return }
            // Gate room noise below -55 dBFS; normal speech spans the remaining range.
            let level = min(1, max(0, (20 * log10(max(rms, 0.000_001)) + 55) / 45))
            let duration = Double(frames) / buffer.format.sampleRate
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            let timeConstant = level > smoothed ? 0.06 : 0.18
            smoothed += (level - smoothed) * (1 - exp(-duration / timeConstant))
            let shouldPublish = now - lastUpdate >= 0.05
            let output = CGFloat(min(1, max(0, smoothed)))
            if shouldPublish { lastUpdate = now }
            lock.unlock()
            if shouldPublish { publish(output) }
        }
    }

    // MARK: - Results

    private func heard(_ piece: String, final: Bool) {
        if !firstWordLogged, !piece.isEmpty {
            firstWordLogged = true
            ChatDiagnostics.log("voice: first words \(elapsed())s after the request")
        }
        if final {
            finalized += piece
            volatile = ""
        } else {
            volatile = piece
        }
        text = base + finalized + volatile
    }

    /// The classic recognizer sometimes restarts its text after a pause. Keep what was already heard.
    private func heardLegacy(_ piece: String, final: Bool) {
        let previous = volatile
        if !previous.isEmpty, piece.count < previous.count / 2, !previous.hasPrefix(String(piece.prefix(2))) {
            finalized += previous
        }
        heard(piece, final: final)
    }

    private func failed(session id: UUID) {
        guard sessionID == id, listening else { return }
        error = "语音识别中断了，已听到的内容保留在输入框里。"
        Task {
            guard sessionID == id else { return }
            await stop()
        }
    }

    private func removeTap() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    /// Drops the recognizer but leaves the microphone recording.
    private func teardownRecognizer() {
        resultsTask?.cancel()
        legacyTask?.cancel()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        input?.finish()
        input = nil
        analyzer = nil
        resultsTask = nil
        legacyRequest = nil
        legacyTask = nil
    }

    private func teardown(deactivateSession: Bool = true) {
        audioLevel = 0
        if engine.isRunning { engine.stop() }
        removeTap()
        recognizerSetup?.cancel()
        recognizerSetup = nil
        relay = nil
        resultsTask?.cancel()
        legacyTask?.cancel()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        input?.finish()
        input = nil
        analyzer = nil
        resultsTask = nil
        legacyRequest = nil
        legacyTask = nil
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func authorize(session id: UUID) async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard sessionID == id, !Task.isCancelled else { return false }
        let microphone = await AVAudioApplication.requestRecordPermission()
        return speech && microphone
    }
}


/// Holds microphone audio until the recognizer is ready, then replays it in order and passes everything after it straight on.
/// Push runs on the audio thread; the backlog is replayed under the lock so the order can never be broken.
final class AudioRelay: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var backlog: [AVAudioPCMBuffer] = []
    nonisolated(unsafe) private var frames = 0
    nonisolated(unsafe) private var consumer: ((AVAudioPCMBuffer) -> Void)?
    /// About a minute of speech at most; a hold that long has bigger problems.
    nonisolated private static let limit = 48_000 * 60

    nonisolated init() {}
    // Released from whichever thread lets go last (the audio thread, a test); no main-actor hop.
    nonisolated deinit {}

    nonisolated func push(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if let consumer {
            lock.unlock()
            consumer(buffer)
            return
        }
        if frames < Self.limit, let copy = Self.copy(buffer) {
            backlog.append(copy)
            frames += Int(copy.frameLength)
        }
        lock.unlock()
    }

    nonisolated func attach(_ consumer: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.lock()
        let pending = backlog
        backlog = []
        frames = 0
        for buffer in pending { consumer(buffer) }
        self.consumer = consumer
        lock.unlock()
    }

    /// The tap reuses its buffers, so anything kept has to be a copy.
    nonisolated private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        if let source = buffer.floatChannelData, let target = copy.floatChannelData {
            let count = Int(buffer.frameLength) * (buffer.format.isInterleaved ? channels : 1)
            for channel in 0..<(buffer.format.isInterleaved ? 1 : channels) {
                target[channel].update(from: source[channel], count: count)
            }
            return copy
        }
        return nil
    }
}
