import Foundation

/// Refuse redirects: neither voice nor authorization may be forwarded to another destination.
final class SpeechRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                               completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
struct CustomSpeechClient {
    private static let network = URLSession(configuration: .ephemeral, delegate: SpeechRedirectPolicy(), delegateQueue: nil)
    var session: URLSession = Self.network

    static func request(configuration: CustomSpeechConfiguration, audio: Data, boundary: String = UUID().uuidString) throws -> URLRequest {
        guard !audio.isEmpty, audio.count < 24_000_000 else { throw SpeechServiceError.emptyAudio }
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 40
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        for (name, value) in [("model", configuration.model), ("response_format", "json")] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        request.httpBody = body
        return request
    }

    func transcribe(audio: Data, configuration: CustomSpeechConfiguration) async throws -> String {
        try Task.checkCancellation()
        let request = try Self.request(configuration: configuration, audio: audio)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw SpeechServiceError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let reason = SpeechRejectionReason.parse(data)
            ChatDiagnostics.log("speech: HTTP \(response.statusCode), reason=\(reason?.rawValue ?? "unclassified")")
            if let reason { throw SpeechServiceError.rejected(response.statusCode, reason) }
            throw SpeechServiceError.http(response.statusCode)
        }
        guard data.count < 1_000_000 else { throw SpeechServiceError.invalidResponse }
        struct Transcript: Decodable { let text: String }
        guard let result = try? JSONDecoder().decode(Transcript.self, from: data) else { throw SpeechServiceError.invalidResponse }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SpeechServiceError.invalidResponse }
        return text
    }
}
