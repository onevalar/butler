import XCTest
import Security
@testable import Butler

@MainActor
final class CustomSpeechTests: XCTestCase {
    func testAiHubMixBareHostGetsVersionPrefixWithoutChangingOtherProviders() throws {
        for host in ["aihubmix.com", "api.aihubmix.com", "api.inferera.com"] {
            for path in ["", "/", "/v1/", "/audio/transcriptions", "/v1/audio/transcriptions"] {
                XCTAssertEqual(try CustomSpeechConfiguration.endpoint(for: "https://\(host)\(path)").absoluteString,
                               "https://\(host)/v1/audio/transcriptions")
            }
        }
        XCTAssertEqual(try CustomSpeechConfiguration.endpoint(for: "https://example.com").path, "/audio/transcriptions")
    }

    func testOldAiHubMixCredentialSurvivesPathCorrectionButNeverChangesHost() throws {
        let name = "speech-migration-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let settings = SpeechRecognitionSettings(defaults: defaults, account: name)
        defer { try? settings.removeCustomConfiguration(); defaults.removePersistentDomain(forName: name) }
        let data = try JSONSerialization.data(withJSONObject: ["endpoint": "https://api.inferera.com/audio/transcriptions", "key": "fictional-key"])
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "butler.speech", kSecAttrAccount as String: name, kSecValueData as String: data]
        XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)
        defaults.set("https://api.inferera.com", forKey: "speechRecognitionBaseURL")
        defaults.set("whisper-1", forKey: "speechRecognitionModel")
        XCTAssertEqual(try settings.customConfiguration().endpoint.absoluteString, "https://api.inferera.com/v1/audio/transcriptions")
        XCTAssertEqual(try settings.customConfiguration().apiKey, "fictional-key")
        defaults.set("https://aihubmix.com", forKey: "speechRecognitionBaseURL")
        XCTAssertThrowsError(try settings.customConfiguration())
    }

    func testProviderErrorClassificationDoesNotExposeKeySuffixOrRawMessage() throws {
        let examples: [(String, SpeechRejectionReason)] = [
            (#"{"error":{"code":"insufficient_user_quota","message":"private account"}}"#, .quota),
            (#"{"error":{"message":"Forbidden – key(SECRET) not authorized to access the requested model."}}"#, .modelPermission),
            (#"{"error":{"message":"Forbidden – key(SECRET) allowed only from approved IP ranges."}}"#, .ipRestriction),
            (#"{"error":{"message":"Account suspended."}}"#, .accountSuspended),
            (#"{"error":{"message":"Unauthorized – access token is invalid or expired."}}"#, .invalidKey)
        ]
        for (body, reason) in examples {
            XCTAssertEqual(SpeechRejectionReason.parse(Data(body.utf8)), reason)
            XCTAssertFalse(SpeechServiceError.rejected(403, reason).localizedDescription.contains("SECRET"))
        }
        XCTAssertNil(SpeechRejectionReason.parse(Data("<html>private proxy error</html>".utf8)))
        XCTAssertTrue(SpeechServiceError.http(403).localizedDescription.contains("不一定是密钥错误"))
    }

    func testEndpointSupportsBasePathsAndCompleteEndpointWithoutDuplicatingSuffix() throws {
        XCTAssertEqual(try CustomSpeechConfiguration.endpoint(for: " https://example.com/openai/v1/ ").absoluteString,
                       "https://example.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(try CustomSpeechConfiguration.endpoint(for: "https://example.com/v1/audio/transcriptions/").absoluteString,
                       "https://example.com/v1/audio/transcriptions")
        for bad in ["http://example.com", "https://user:key@example.com", "https://example.com?key=secret", "https://example.com/#secret", "not a url"] {
            XCTAssertThrowsError(try CustomSpeechConfiguration.endpoint(for: bad))
        }
    }

    func testConfigurationRejectsMissingFieldsAndHeaderInjection() {
        for (model, key) in [("", "test"), ("whisper", ""), ("whisper\r\nbad", "test"), ("whisper", "test\nInjected: value")] {
            XCTAssertThrowsError(try CustomSpeechConfiguration.validated(baseURL: "https://example.com/v1", model: model, apiKey: key))
        }
    }

    func testSettingsDefaultToAppleAndKeepCredentialsOutOfDefaults() throws {
        let name = "speech-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let settings = SpeechRecognitionSettings(defaults: defaults, account: name)
        defer { try? settings.removeCustomConfiguration(); defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(settings.provider, .apple)
        try settings.save(provider: .custom, baseURL: "https://example.com/v1", model: "whisper-test", newKey: "fictional-test-key")
        XCTAssertEqual(settings.provider, .custom)
        XCTAssertEqual(try settings.customConfiguration().apiKey, "fictional-test-key")
        XCTAssertFalse(String(describing: defaults.persistentDomain(forName: name)).contains("fictional-test-key"))
        try settings.save(provider: .apple, baseURL: "", model: "", newKey: "")
        XCTAssertEqual(settings.provider, .apple)
        XCTAssertTrue(settings.hasSavedKey)
        try settings.save(provider: .custom, baseURL: "https://example.com/v1/", model: "next-model", newKey: "")
        XCTAssertEqual(try settings.customConfiguration().model, "next-model")
        XCTAssertThrowsError(try settings.save(provider: .custom, baseURL: "https://other.example/v1", model: "model", newKey: ""))
        XCTAssertEqual(settings.baseURL, "https://example.com/v1/")
        // Tampering with defaults cannot make an existing key authorize a new host.
        defaults.set("https://other.example/v1", forKey: "speechRecognitionBaseURL")
        XCTAssertThrowsError(try settings.customConfiguration())
        try settings.removeCustomConfiguration()
        XCTAssertEqual(settings.provider, .apple)
        XCTAssertFalse(settings.hasSavedKey)
    }

    func testMultipartContainsAudioAndModelButNeverPutsKeyInURLOrBody() throws {
        let configuration = try config()
        let audio = Data([0, 1, 2, 255, 42])
        let request = try CustomSpeechClient.request(configuration: configuration, audio: audio, boundary: "test-boundary")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fictional-test-key")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertNotNil(body.range(of: audio))
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\nwhisper-test"))
        XCTAssertTrue(text.contains("filename=\"voice.m4a\""))
        XCTAssertTrue(text.hasSuffix("--test-boundary--\r\n"))
        XCTAssertFalse(text.contains("fictional-test-key"))
        XCTAssertFalse(request.url!.absoluteString.contains("fictional-test-key"))
        XCTAssertThrowsError(try CustomSpeechClient.request(configuration: configuration, audio: Data()))
    }

    func testDecodesTextAndSurfacesHTTPFailureWithoutLeakingServerBody() async throws {
        let network = network()
        defer { network.invalidateAndCancel(); SpeechStub.handler = nil }
        let client = CustomSpeechClient(session: network)
        SpeechStub.handler = { _ in (200, Data(#"{"text":"  买一盒鸡蛋  "}"#.utf8)) }
        let text = try await client.transcribe(audio: Data([1]), configuration: config())
        XCTAssertEqual(text, "买一盒鸡蛋")
        SpeechStub.handler = { _ in (401, Data("sensitive-server-body".utf8)) }
        do {
            _ = try await client.transcribe(audio: Data([1]), configuration: config())
            XCTFail("must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("API Key"))
            XCTAssertFalse(error.localizedDescription.contains("sensitive-server-body"))
        }
    }

    func testRejectsMalformedOrEmptyTranscripts() async throws {
        let network = network()
        defer { network.invalidateAndCancel(); SpeechStub.handler = nil }
        let client = CustomSpeechClient(session: network)
        for result in [#"{"text":"  "}"#, #"{"message":"no result"}"#, "<html>error</html>"] {
            SpeechStub.handler = { _ in (200, Data(result.utf8)) }
            do {
                _ = try await client.transcribe(audio: Data([1]), configuration: config())
                XCTFail("must reject invalid transcript")
            } catch { XCTAssertTrue(error is SpeechServiceError) }
        }
    }

    func testCancellationStopsPendingTranscription() async throws {
        let network = network()
        defer { network.invalidateAndCancel(); SpeechStub.handler = nil }
        let began = expectation(description: "request began")
        SpeechStub.handler = { _ in
            began.fulfill()
            try await Task.sleep(for: .seconds(10))
            return (200, Data(#"{"text":"late result"}"#.utf8))
        }
        let configuration = try config()
        let task = Task { try await CustomSpeechClient(session: network).transcribe(audio: Data([1]), configuration: configuration) }
        await fulfillment(of: [began], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled request must not deliver") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }

    func testRedirectIsRefusedInsteadOfForwardingCredentials() {
        let network = URLSession(configuration: .ephemeral)
        defer { network.invalidateAndCancel() }
        let url = URL(string: "https://example.com/v1/audio/transcriptions")!
        let task = network.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil)!
        var called = false
        SpeechRedirectPolicy().urlSession(network, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://other.example/")!)) {
                XCTAssertNil($0)
                called = true
            }
        XCTAssertTrue(called)
        task.cancel()
    }

    private func config() throws -> CustomSpeechConfiguration {
        try .validated(baseURL: "https://example.com/v1", model: "whisper-test", apiKey: "fictional-test-key")
    }
    private func network() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpeechStub.self]
        return URLSession(configuration: configuration)
    }
}

private final class SpeechStub: URLProtocol, @unchecked Sendable {
    @MainActor static var handler: ((URLRequest) async throws -> (Int, Data))?
    private let lock = NSLock()
    nonisolated(unsafe) private var operation: Task<Void, Never>?
    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    nonisolated override func startLoading() {
        let operation = Task { @MainActor in
            do {
                guard let handler = Self.handler else { throw URLError(.badServerResponse) }
                let (status, data) = try await handler(request)
                try Task.checkCancellation()
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        lock.lock(); self.operation = operation; lock.unlock()
    }
    nonisolated override func stopLoading() {
        lock.lock(); let task = operation; operation = nil; lock.unlock()
        task?.cancel()
    }
}
