import Foundation
import XCTest
@testable import Butler

@MainActor
final class SubscriptionModelTests: XCTestCase {
    private func event(_ value: [String: Any], into stream: inout SubscriptionStream) throws {
        try stream.consume("event: ignored")
        try stream.consume("data: " + String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self))
        try stream.consume("")
    }

    func testCompletedToolCallRetainsOpaqueReasoningForNextRequest() throws {
        var stream = SubscriptionStream()
        try event(["type": "response.output_item.done", "item": ["type": "reasoning", "id": "r", "encrypted_content": "opaque-test"]], into: &stream)
        try event(["type": "response.function_call_arguments.delta", "delta": "partial"], into: &stream)
        try event(["type": "response.output_item.done", "item": ["type": "function_call", "id": "item-not-call", "call_id": "correct-call", "name": "search_memory", "arguments": "{\"query\":\"盒马\"}"]], into: &stream)
        try event(["type": "response.completed", "response": ["id": "response", "model": "gpt-6-sol", "output": []]], into: &stream)
        let reply = try stream.finish()
        XCTAssertEqual(reply.calls.first?.id, "correct-call")
        XCTAssertEqual(reply.calls.first?.arguments, "{\"query\":\"盒马\"}")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: SubscriptionModel.requestBody([
            .user("找麻薯"), .assistant(reply), .tool(id: "correct-call", result: "[]")
        ])) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-6-sol")
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(body["store"] as? Bool, false)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input[1]["encrypted_content"] as? String, "opaque-test")
        XCTAssertEqual(input[3]["call_id"] as? String, "correct-call")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["search_memory", "propose_memory", "set_remaining"])
    }

    func testTruncatedAndFailedStreamsNeverReturnToolCalls() throws {
        var stream = SubscriptionStream()
        try event(["type": "response.output_item.done", "item": ["type": "function_call", "call_id": "c", "name": "set_remaining", "arguments": "{}"]], into: &stream)
        XCTAssertThrowsError(try stream.finish())
        XCTAssertThrowsError(try event(["type": "response.failed", "response": ["error": ["code": "usage_limit"]]], into: &stream))
        var fallback = SubscriptionStream()
        XCTAssertThrowsError(try event(["type": "response.completed", "response": ["id": "r", "model": "other-model"]], into: &fallback))
    }

    func testMultilineSSEAndFinalOutputDoNotDuplicateText() throws {
        var stream = SubscriptionStream()
        try stream.consume(": keepalive")
        try stream.consume("data: {\"type\":\"response.output_text.delta\",")
        try stream.consume("data: \"delta\":\"你好\"}\r")
        try stream.consume("\r")
        try event(["type": "response.completed", "response": ["id": "r", "output": [
            ["type": "message", "role": "assistant", "phase": "final_answer", "content": [["type": "output_text", "text": "你好"]]]
        ]]], into: &stream)
        XCTAssertEqual(try stream.finish().text, "你好")
    }

    func testStreamingPreviewExcludesToolArgumentsAndReasoning() throws {
        var stream = SubscriptionStream()
        try event(["type": "response.reasoning_text.delta", "delta": "private"], into: &stream)
        try event(["type": "response.function_call_arguments.delta", "delta": "partial tool"], into: &stream)
        XCTAssertEqual(stream.visibleText, "")
        try event(["type": "response.output_text.delta", "delta": "正在"], into: &stream)
        XCTAssertEqual(stream.visibleText, "正在")
        try event(["type": "response.output_text.delta", "delta": "查找"], into: &stream)
        XCTAssertEqual(stream.visibleText, "正在查找")
        XCTAssertThrowsError(try stream.finish(), "A preview is never a completed response or executable tool call")
    }

    private func jwt(_ object: [String: Any]) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: object).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    func testCredentialsUseAccountClaimAndKeepOmittedRefreshFields() throws {
        let access = try jwt(["exp": 2_000_000_000])
        let identity = try jwt(["sub": "not-account", "https://api.openai.com/auth": ["chatgpt_account_id": "account-test"]])
        let initial = try SubscriptionConnection.decodeCredentials(JSONSerialization.data(withJSONObject: ["access_token": access, "refresh_token": "fake-refresh", "id_token": identity]))
        XCTAssertEqual(initial.accountID, "account-test")
        XCTAssertEqual(initial.expiresAt.timeIntervalSince1970, 2_000_000_000)
        let updated = try SubscriptionConnection.decodeCredentials(Data(#"{"refresh_token":"rotated-test"}"#.utf8), previous: initial)
        XCTAssertEqual(updated.accessToken, access)
        XCTAssertEqual(updated.refreshToken, "rotated-test")
        XCTAssertEqual(updated.accountID, "account-test")
        XCTAssertThrowsError(try SubscriptionConnection.decodeCredentials(Data(#"{"access_token":"fake","refresh_token":"fake"}"#.utf8)))
        XCTAssertEqual(String(decoding: SubscriptionConnection.form(["code": "a+&= 空"]), as: UTF8.self), "code=a%2B%26%3D%20%E7%A9%BA")
    }

    func testDeviceLoginKeychainRefreshAndDirectModelTransport() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SubscriptionStubProtocol.self]
        let network = URLSession(configuration: config)
        let account = "unit-test-" + UUID().uuidString
        let connection = SubscriptionConnection(network: network, keychainAccount: account)
        defer { try? connection.signOut(); network.invalidateAndCancel(); SubscriptionStubProtocol.handler = nil }
        let identity = try jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "fixture-account"]])
        let oldAccess = try jwt(["exp": 1_000])
        let newAccess = try jwt(["exp": 2_000_000_000])
        var polls = 0
        var refreshed = false
        var probed = false
        SubscriptionStubProtocol.handler = { request in
            let path = request.url!.path
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            if path.hasSuffix("usercode") {
                return (200, Data(#"{"device_auth_id":"fixture-device","user_code":"TEST-CODE","interval":"1"}"#.utf8))
            }
            if path.hasSuffix("deviceauth/token") {
                polls += 1
                if polls == 1 { return (403, Data()) }
                return (200, Data(#"{"authorization_code":"fake-code","code_verifier":"v+&="}"#.utf8))
            }
            if path == "/oauth/token" {
                if request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded" {
                    XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("code_verifier=v%2B%26%3D"))
                    return (200, try JSONSerialization.data(withJSONObject: ["access_token": oldAccess, "refresh_token": "fake-refresh", "id_token": identity]))
                }
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
                XCTAssertEqual(json["refresh_token"], "fake-refresh")
                refreshed = true
                return (200, try JSONSerialization.data(withJSONObject: ["access_token": newAccess, "refresh_token": "rotated-test"]))
            }
            XCTAssertEqual(request.url?.host, "chatgpt.com")
            // A healthy first request must not wait for an extra connectivity probe.
            if request.httpMethod == "HEAD" {
                probed = true
                return (200, Data())
            }
            XCTAssertEqual(path, "/backend-api/codex/responses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(newAccess)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-ID"), "fixture-account")
            return (200, Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"测试回复\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\"}}\n\n".utf8))
        }
        await connection.beginLogin()
        XCTAssertEqual(connection.deviceCode?.code, "TEST-CODE")
        await connection.awaitApproval()
        XCTAssertNil(connection.error)
        XCTAssertTrue(connection.isLoggedIn)
        XCTAssertEqual(polls, 2)
        var streamed: [String] = []
        let model = SubscriptionModel(connection: connection, network: network, onText: { streamed.append($0) })
        let reply = try await model.reply(to: [.user("虚构测试")])
        XCTAssertEqual(reply.text, "测试回复")
        XCTAssertEqual(streamed.first, "")
        XCTAssertTrue(streamed.contains("测试回复"))
        XCTAssertTrue(refreshed)
        XCTAssertFalse(probed)
        let reloaded = SubscriptionConnection(network: network, keychainAccount: account)
        let persisted = try await reloaded.authorizedCredentials()
        XCTAssertEqual(persisted.refreshToken, "rotated-test")
        XCTAssertEqual(persisted.accessToken, newAccess)
    }
}

private final class SubscriptionStubProtocol: URLProtocol, @unchecked Sendable {
    @MainActor static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    nonisolated override func startLoading() {
        Task { @MainActor in
            do {
                guard let handler = Self.handler else { throw URLError(.badServerResponse) }
                let (status, data) = try handler(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                // Split inside arbitrary UTF-8 boundaries to exercise byte framing.
                let middle = data.count / 2
                client?.urlProtocol(self, didLoad: data.prefix(middle))
                client?.urlProtocol(self, didLoad: data.suffix(data.count - middle))
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    nonisolated override func stopLoading() { }

    func testPhotosAreSentAsImagesWithTheText() throws {
        let body = try JSONSerialization.jsonObject(with: SubscriptionModel.requestBody([.userPhotos("看看这是什么", [Data([1, 2, 3])])])) as? [String: Any]
        let content = try XCTUnwrap(((body?["input"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "看看这是什么")
        XCTAssertEqual(content.last?["type"] as? String, "input_image")
        XCTAssertEqual(content.last?["image_url"] as? String, "data:image/jpeg;base64,AQID")
    }

    func testRequestWithoutToolsOmitsToolFields() throws {
        let body = try JSONSerialization.jsonObject(with: SubscriptionModel.requestBody([.user("整理摘要")], instructions: "x", toolJSON: "[]")) as? [String: Any]
        XCTAssertNil(body?["tools"])
        XCTAssertNil(body?["tool_choice"])
        let withContext = try JSONSerialization.jsonObject(with: SubscriptionModel.requestBody([.context("更早对话的摘要：…"), .user("你好")])) as? [String: Any]
        let first = (withContext?["input"] as? [[String: Any]])?.first
        XCTAssertEqual(first?["role"] as? String, "developer")
    }
}
