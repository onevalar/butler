import Foundation

@MainActor
protocol SpeechSocket: AnyObject {
    var statusCode: Int? { get }
    func resume()
    func send(_ text: String) async throws
    func receive() async throws -> Data
    func cancel()
}

@MainActor
private final class NetworkSpeechSocket: SpeechSocket {
    nonisolated deinit {}
    private let session = URLSession(configuration: .ephemeral, delegate: SpeechRedirectPolicy(), delegateQueue: nil)
    private var task: URLSessionWebSocketTask!
    init(configuration: CustomSpeechConfiguration) {
        var request = URLRequest(url: configuration.realtimeEndpoint)
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 12
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 1_000_000
    }
    var statusCode: Int? { (task.response as? HTTPURLResponse)?.statusCode }
    func resume() { task.resume() }
    func send(_ text: String) async throws { try await task.send(.string(text)) }
    func receive() async throws -> Data {
        switch try await task.receive() {
        case .string(let text): return Data(text.utf8)
        case .data(let data): return data
        @unknown default: throw SpeechServiceError.invalidResponse
        }
    }
    func cancel() { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}

/// One press owns one socket and one ordered audio stream. The microphone is never restarted
/// for network setup, and cancel invalidates both directions before the next press begins.
@MainActor
final class RealtimeSpeechClient {
    private let socket: any SpeechSocket
    private var receiving: Task<Void, Never>?
    private var sending: Task<Void, Never>?
    private var ready = false
    private var completed = false
    private var cancelled = false
    private var failure: Error?
    private var transcript = ""
    private var byteCount = 0
    private var onText: ((String) -> Void)?
    private var onFailure: ((String) -> Void)?
    nonisolated deinit {}

    init(configuration: CustomSpeechConfiguration, socket: (any SpeechSocket)? = nil) {
        self.socket = socket ?? NetworkSpeechSocket(configuration: configuration)
    }

    static func sessionUpdate(model: String) throws -> String {
        try encode(["type": "session.update", "session": [
            "type": "transcription", "audio": ["input": [
                "format": ["type": "audio/pcm", "rate": 24000],
                "transcription": ["model": model, "languages": ["zh", "en"]],
                "turn_detection": NSNull(), "noise_reduction": ["type": "near_field"]
            ]]
        ]])
    }

    /// Authenticates and waits for the service to accept session configuration; no microphone
    /// access or audio upload. This proves connectivity, not transcription accuracy.
    func checkConnection(model: String) async throws {
        let (audio, continuation) = AsyncStream<Data>.makeStream()
        defer { continuation.finish(); cancel() }
        start(model: model, audio: audio, onText: { _ in }, onFailure: { _ in })
        let deadline = ContinuousClock.now + .seconds(13)
        while !ready {
            try check()
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
        try check()
    }

    func start(model: String, audio: AsyncStream<Data>, onText: @escaping (String) -> Void,
               onFailure: @escaping (String) -> Void) {
        self.onText = onText
        self.onFailure = onFailure
        socket.resume()
        receiving = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled, !cancelled {
                    let data = try await socket.receive()
                    try check()
                    try consume(data)
                    if completed { return }
                }
            } catch { fail(error) }
        }
        sending = Task { [weak self] in
            guard let self else { return }
            do {
                try await socket.send(Self.sessionUpdate(model: model))
                let deadline = ContinuousClock.now + .seconds(12)
                while !ready {
                    try check()
                    guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
                    try await Task.sleep(for: .milliseconds(20))
                }
                ChatDiagnostics.log("speech realtime: session configured")
                for await chunk in audio {
                    try check()
                    byteCount += chunk.count
                    guard byteCount <= 24_000 * 2 * 120 else { throw SpeechServiceError.tooLong }
                    try await socket.send(Self.encode(["type": "input_audio_buffer.append", "audio": chunk.base64EncodedString()]))
                }
                try check()
            } catch { fail(error) }
        }
    }

    /// The owner must finish its audio continuation before calling this method.
    func finish() async throws -> String {
        await sending?.value
        try check()
        guard byteCount >= 4_800 else { throw SpeechServiceError.emptyAudio }
        try await socket.send(Self.encode(["type": "input_audio_buffer.commit"]))
        let deadline = ContinuousClock.now + .seconds(30)
        while !completed {
            try check()
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
        try check()
        let result = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw SpeechServiceError.emptyAudio }
        return result
    }

    func cancel() {
        cancelled = true
        onText = nil
        onFailure = nil
        receiving?.cancel(); receiving = nil
        sending?.cancel(); sending = nil
        socket.cancel()
    }

    private func check() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
        if let failure { throw failure }
    }

    private func consume(_ data: Data) throws {
        guard data.count < 1_000_000,
              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { throw SpeechServiceError.invalidResponse }
        switch type {
        case "session.updated": ready = true
        case "conversation.item.input_audio_transcription.delta":
            guard let delta = event["delta"] as? String else { throw SpeechServiceError.invalidResponse }
            transcript += delta
            onText?(transcript)
        case "conversation.item.input_audio_transcription.completed":
            guard let text = event["transcript"] as? String else { throw SpeechServiceError.invalidResponse }
            transcript = text
            completed = true
            onText?(text)
            ChatDiagnostics.log("speech realtime: transcript completed")
        case "error", "conversation.item.input_audio_transcription.failed":
            if let reason = SpeechRejectionReason.parse(data) { throw SpeechServiceError.rejected(403, reason) }
            throw SpeechServiceError.realtime
        default: break
        }
    }

    private func fail(_ error: Error) {
        guard !cancelled, failure == nil, !Task.isCancelled else { return }
        let safe: Error
        if let status = socket.statusCode, status >= 300 {
            safe = SpeechServiceError.http(status)
            ChatDiagnostics.log("speech realtime: handshake HTTP \(status)")
        } else if let known = error as? SpeechServiceError {
            safe = known
        } else if (error as? URLError)?.code == .timedOut {
            safe = SpeechServiceError.invalidConfiguration("实时语音连接超时，请检查网络后重试。")
        } else { safe = SpeechServiceError.realtime }
        failure = safe
        ChatDiagnostics.log("speech realtime: \(safe.localizedDescription)")
        onFailure?(safe.localizedDescription)
        socket.cancel()
    }

    private static func encode(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}
