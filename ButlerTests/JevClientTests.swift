import Foundation
import XCTest
@testable import Butler

@MainActor
final class JevClientTests: XCTestCase {
    func testPrefetchPreferenceIsIndependentAndPersists() throws {
        let suite = "jev-prefetch-setting-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = JevClient(defaults: defaults, keychainAccount: suite)
        XCTAssertTrue(client.prefetchEnabled)
        client.prefetchEnabled = false
        client.isEnabled = false
        client.isEnabled = true
        XCTAssertFalse(client.prefetchEnabled, "the main switch must not overwrite the independent preference")
        let reloaded = JevClient(defaults: defaults, keychainAccount: suite)
        XCTAssertFalse(reloaded.prefetchEnabled)
        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertEqual(reloaded.callsThisSession, 0)
    }

    func testNonzeroCountSurvivesTogglesAndIncludesFailedAttempts() async throws {
        let suite = "jev-count-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JevStubProtocol.self]
        let network = URLSession(configuration: config)
        let client = JevClient(network: network, defaults: defaults, keychainAccount: suite)
        defer {
            client.removeKey()
            defaults.removePersistentDomain(forName: suite)
            network.invalidateAndCancel()
            JevStubProtocol.handler = nil
        }
        try client.saveKey("fictional-count-test")
        let questions = [JevClient.Question(id: "q", question: "是牛奶吗", candidate: "牛奶")]
        var requests = 0
        JevStubProtocol.handler = { _ in
            requests += 1
            if requests == 2 { throw URLError(.notConnectedToInternet) }
            return Data(#"{"answers":{"q":{"noul":0.73}}}"#.utf8)
        }
        _ = try await client.judge(request: "牛奶", questions: questions)
        do {
            _ = try await client.judge(request: "牛奶", questions: questions)
            XCTFail("the second attempt should fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
        XCTAssertEqual(client.callsThisSession, 2, "failed attempts are counted, not just successful responses")
        client.isEnabled = false
        XCTAssertEqual(client.callsThisSession, 2, "switching off must not clear a nonzero count")
        do {
            _ = try await client.judge(request: "牛奶", questions: questions)
            XCTFail("disabled requests must be rejected")
        } catch JevClient.JevError.disabled { }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(client.callsThisSession, 2)
        client.isEnabled = true
        XCTAssertEqual(client.callsThisSession, 2, "switching on must not clear the count either")
        _ = try await client.judge(request: "牛奶", questions: questions)
        XCTAssertEqual(client.callsThisSession, 3)
        XCTAssertEqual(requests, 3)
        let fresh = JevClient(network: network, defaults: defaults, keychainAccount: suite)
        XCTAssertTrue(fresh.isConfigured)
        XCTAssertEqual(fresh.callsThisSession, 0, "the counter belongs to one client instance, not persistent history")
        XCTAssertEqual(client.callsThisSession, 3)
    }

    func testDisabledRequestsKeepKeyAndPreferenceAcrossRestart() async throws {
        let suite = "jev-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JevStubProtocol.self]
        let network = URLSession(configuration: config)
        let client = JevClient(network: network, defaults: defaults, keychainAccount: suite)
        defer {
            client.removeKey()
            defaults.removePersistentDomain(forName: suite)
            network.invalidateAndCancel()
            JevStubProtocol.handler = nil
        }
        var requests = 0
        JevStubProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fictional-test-key")
            return Data(#"{"answers":{"q":{"noul":0.73}}}"#.utf8)
        }
        try client.saveKey("fictional-test-key")
        XCTAssertTrue(client.isAvailable, "existing key without a preference stays enabled")
        client.isEnabled = false
        let questions = [JevClient.Question(id: "q", question: "是牛奶吗", candidate: "牛奶")]
        do {
            _ = try await client.judge(request: "牛奶", questions: questions)
            XCTFail("disabled requests must fail before networking")
        } catch JevClient.JevError.disabled { }
        do {
            _ = try await client.judge(request: "牛奶", question: "是牛奶吗", candidates: [.init(id: "q", text: "牛奶")])
            XCTFail("the candidate entry point must also be blocked")
        } catch JevClient.JevError.disabled { }
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(client.callsThisSession, 0)
        let reloaded = JevClient(network: network, defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), keychainAccount: suite)
        XCTAssertTrue(reloaded.isConfigured, "switching off must not delete the key")
        XCTAssertFalse(reloaded.isEnabled)
        reloaded.isEnabled = true
        let answers = try await reloaded.judge(request: "牛奶", questions: questions)
        XCTAssertEqual(answers["q"], 0.73)
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(JevClient(network: network, defaults: defaults, keychainAccount: suite).isAvailable)

        // Switching off while a request is already in transport permits that result only.
        JevStubProtocol.handler = { _ in
            requests += 1
            reloaded.isEnabled = false
            return Data(#"{"answers":{"q":{"noul":0.21}}}"#.utf8)
        }
        let inFlight = try await reloaded.judge(request: "牛奶", questions: questions)
        XCTAssertEqual(inFlight["q"], 0.21)
        do {
            _ = try await reloaded.judge(request: "牛奶", questions: questions)
            XCTFail("the next request must be blocked")
        } catch JevClient.JevError.disabled { }
        XCTAssertEqual(requests, 2)
        reloaded.removeKey()
        XCTAssertFalse(JevClient(network: network, defaults: defaults, keychainAccount: suite).isConfigured)
    }
}

private final class JevStubProtocol: URLProtocol, @unchecked Sendable {
    @MainActor static var handler: ((URLRequest) throws -> Data)?
    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    nonisolated override func startLoading() {
        Task { @MainActor in
            do {
                guard let handler = Self.handler else { throw URLError(.badServerResponse) }
                let data = try handler(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    nonisolated override func stopLoading() { }
}
