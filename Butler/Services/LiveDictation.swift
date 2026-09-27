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
    /// What was in the box before listening, plus everything heard so far.
    private(set) var text = ""
    var error: String?

    private var base = ""
    private var finalized = ""
    private var volatile = ""
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var legacyRequest: SFSpeechAudioBufferRecognitionRequest?
    private var legacyTask: SFSpeechRecognitionTask?

    nonisolated deinit {}

    static let locale = Locale(identifier: "zh-CN")

    func start(after existing: String) async {
        guard !listening, !preparing else { return }
        error = nil
        preparing = true
        defer { preparing = false }
        guard await Self.authorize() else {
            error = "没有麦克风或语音识别权限，可以在系统设置里打开。"
            return
        }
        base = existing
        finalized = ""
        volatile = ""
        text = base
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            do {
                try await startAnalyzer()
            } catch {
                try startLegacy()
            }
            listening = true
        } catch {
            teardown()
            self.error = "语音识别没能启动，先打字吧。"
        }
    }

    /// Stops listening and returns the full text once the last sentence is finalized.
    @discardableResult
    func stop() async -> String {
        guard listening else { return text }
        listening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        input?.finish()
        legacyRequest?.endAudio()
        if let analyzer { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        if legacyTask != nil { try? await Task.sleep(for: .milliseconds(500)) }
        await resultsTask?.value
        teardown()
        text = base + finalized + volatile
        return text
    }

    func cancel() {
        listening = false
        resultsTask?.cancel()
        legacyTask?.cancel()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        teardown()
    }

    // MARK: - Speech analyzer (iOS 26)

    private func startAnalyzer() async throws {
        let module: any SpeechModule
        if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Self.locale) {
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            module = transcriber
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.heard(String(result.text.characters), final: result.isFinal)
                    }
                } catch { self?.failed() }
            }
        } else if let locale = await DictationTranscriber.supportedLocale(equivalentTo: Self.locale) {
            let transcriber = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                                   reportingOptions: [.volatileResults, .frequentFinalization],
                                                   attributeOptions: [])
            module = transcriber
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.heard(String(result.text.characters), final: result.isFinal)
                    }
                } catch { self?.failed() }
            }
        } else {
            throw VoiceError.setupFailed
        }
        // First use: the Chinese speech model isn't on the phone yet. Download it in the background
        // and listen right away with the classic recognizer; next time the new one is ready.
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            resultsTask?.cancel()
            resultsTask = nil
            Task.detached {
                if let request = try? await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    try? await request.downloadAndInstall()
                }
            }
            throw VoiceError.setupFailed
        }
        do {
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            let analyzer = SpeechAnalyzer(modules: [module])
            let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
            let natural = engine.inputNode.outputFormat(forBus: 0)
            try await analyzer.prepareToAnalyze(in: target)
            try await analyzer.start(inputSequence: stream)
            self.analyzer = analyzer
            input = continuation
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: natural,
                                        block: Self.analyzerTap(from: natural, to: target, into: continuation))
            engine.prepare()
            try engine.start()
        } catch {
            resultsTask?.cancel()
            resultsTask = nil
            input?.finish()
            input = nil
            analyzer = nil
            throw error
        }
    }

    /// Runs on the audio thread: converts mic buffers to the analyzer's format.
    nonisolated private static func analyzerTap(from source: AVAudioFormat, to target: AVAudioFormat?,
                                                into continuation: AsyncStream<AnalyzerInput>.Continuation) -> AVAudioNodeTapBlock {
        let converter = target.flatMap { $0 == source ? nil : AVAudioConverter(from: source, to: $0) }
        return { buffer, _ in
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

    private func startLegacy() throws {
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
                guard let self else { return }
                if let piece { self.heardLegacy(piece, final: isFinal) }
                if error != nil, result == nil { self.failed() }
            }
        }
        let natural = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: natural, block: Self.legacyTap(request))
        engine.prepare()
        try engine.start()
    }

    nonisolated private static func legacyTap(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    // MARK: - Results

    private func heard(_ piece: String, final: Bool) {
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

    private func failed() {
        guard listening else { return }
        error = "语音识别中断了，已听到的内容保留在输入框里。"
        Task { await stop() }
    }

    private func teardown() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        input?.finish()
        input = nil
        analyzer = nil
        resultsTask = nil
        legacyRequest = nil
        legacyTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        return speech && microphone
    }
}
