#if DEBUG
import Foundation
import Security
import SwiftData
import SwiftUI
import XCTest
@testable import Butler

@MainActor
final class JevEvaluationTests: XCTestCase {
    func testWholeBatchResetsInputsStoresAndModeWithoutChangingPreference() async throws {
        let fixture = try EvaluationFixture()
        defer { fixture.clean() }
        fixture.defaults.set(false, forKey: "jevEnabled")
        let runner = fixture.runner()
        runner.start()
        try await finish(runner)
        XCTAssertEqual(runner.results.count, 32)
        XCTAssertTrue(runner.results.allSatisfy { $0.verdict == "pass" }, runner.results.map { "\($0.scenario.id):\($0.verdict) \($0.assertions)" }.joined(separator: "\n"))
        XCTAssertEqual(fixture.initialInputs, JevEvaluation.plan.map { $0.scenario.input })
        for scenario in JevEvaluationCase.all {
            let samples = runner.results.filter { $0.scenario.id == scenario.id }
            XCTAssertEqual(samples.count, 4)
            XCTAssertTrue(samples.allSatisfy { $0.before == samples.first?.before })
            XCTAssertEqual(samples.filter(\.jevEnabled).count, 2)
        }
        XCTAssertTrue(runner.results.filter { !$0.jevEnabled }.allSatisfy { $0.jevRequests == 0 && $0.jevAttempts.isEmpty })
        XCTAssertEqual(runner.results.reduce(0) { $0 + $1.modelRequests }, fixture.modelRequests)
        XCTAssertEqual(runner.results.reduce(0) { $0 + $1.jevRequests }, fixture.jevRequests)
        XCTAssertFalse(fixture.defaults.bool(forKey: "jevEnabled"))
        XCTAssertTrue(JevClient(defaults: fixture.defaults, keychainAccount: fixture.account).isConfigured)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [])
        let report = String(decoding: try runner.export(), as: UTF8.self)
        XCTAssertFalse(report.contains("fixture-access"))
        XCTAssertFalse(report.contains("fixture-refresh"))
        XCTAssertFalse(report.contains("fixture-key"))
        XCTAssertTrue(report.contains("beforeConfirmation"))
    }

    func testWrongActualWriteFailsAndJevFallbackIsNotAnOnPass() async throws {
        let fixture = try EvaluationFixture()
        defer { fixture.clean() }
        let runner = fixture.runner()
        fixture.mode = .wrong
        let bad = await runner.sample(.init(scenario: JevEvaluationCase.all[0], repetition: 1, enabled: false), id: 1, budget: .init())
        XCTAssertEqual(bad.verdict, "fail")
        XCTAssertEqual(bad.assertions["proposal_matches_fixed_expectation"], false)
        XCTAssertEqual(bad.assertions["stored_state_matches_fixed_expectation"], false)
        XCTAssertEqual(bad.after.first { $0.id == JevEvaluationCase.cold }?.quantity, 2)
        fixture.mode = .jevFailure
        let fallback = await runner.sample(.init(scenario: JevEvaluationCase.all[0], repetition: 1, enabled: true), id: 2, budget: .init())
        XCTAssertEqual(fallback.verdict, "jev_fallback")
        XCTAssertTrue(fallback.jevAttempts.contains { !$0.succeeded })
        XCTAssertEqual(fallback.assertions["stored_state_matches_fixed_expectation"], true)
        XCTAssertEqual(fallback.before.first { $0.id == JevEvaluationCase.cold }?.quantity, 3)
    }

    func testTransportBudgetsRetryTimeoutCancellationAndCredentialPreservation() async throws {
        let fixture = try EvaluationFixture()
        defer { fixture.clean() }
        let entry = JevEvaluation.Entry(scenario: JevEvaluationCase.all[0], repetition: 1, enabled: false)
        let runner = fixture.runner()
        let exhausted = JevEvaluationBudget()
        exhausted.model = JevEvaluationBudget.modelTotal
        let blocked = await runner.sample(entry, id: 1, budget: exhausted)
        XCTAssertEqual(blocked.modelRequests, 0)
        XCTAssertEqual(fixture.modelRequests, 0)
        XCTAssertNotNil(blocked.error)
        fixture.mode = .retry
        let retried = await runner.sample(entry, id: 2, budget: .init())
        XCTAssertEqual(retried.modelRequests, 4, "the failed first POST plus three successful POSTs")
        XCTAssertEqual(retried.verdict, "pass")
        fixture.mode = .hang
        let timedOut = await fixture.runner(caseSeconds: 0.03).sample(entry, id: 3, budget: .init())
        XCTAssertTrue(timedOut.error?.contains("timeout") == true)
        XCTAssertEqual(timedOut.before, timedOut.after)
        let cancellation = Task { await runner.sample(entry, id: 4, budget: .init()) }
        try await Task.sleep(for: .milliseconds(30))
        cancellation.cancel()
        let cancelled = await cancellation.value
        XCTAssertEqual(cancelled.verdict, "cancelled")
        XCTAssertEqual(cancelled.before, cancelled.after)
        fixture.mode = .unauthorized
        let unauthorized = await runner.sample(entry, id: 5, budget: .init())
        XCTAssertNotNil(unauthorized.error)
        XCTAssertTrue(SubscriptionConnection(network: fixture.network, keychainAccount: fixture.account).isLoggedIn)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [])
    }

    func testBudgetStopsJevEvenWhenToolsWouldFallback() async throws {
        let fixture = try EvaluationFixture()
        defer { fixture.clean() }
        let budget = JevEvaluationBudget()
        budget.jev = JevEvaluationBudget.jevTotal
        let result = await fixture.runner().sample(.init(scenario: JevEvaluationCase.all[0], repetition: 1, enabled: true), id: 1, budget: budget)
        XCTAssertEqual(fixture.jevRequests, 0)
        XCTAssertTrue(result.error?.contains("budget") == true)
        XCTAssertEqual(result.before, result.after)
        XCTAssertTrue(result.receipts.isEmpty)
    }

    func testBudgetBoundariesStopBeforeAnExtraRequest() throws {
        for jev in [false, true] {
            let perCase = JevEvaluationBudget()
            let allowed = jev ? JevEvaluationBudget.jevPerCase : JevEvaluationBudget.modelPerCase
            for _ in 0..<allowed { try perCase.consume(jev: jev) }
            XCTAssertThrowsError(try perCase.consume(jev: jev))
            XCTAssertEqual(jev ? perCase.jev : perCase.model, allowed)
            let batch = JevEvaluationBudget()
            batch.model = JevEvaluationBudget.modelTotal - 1
            batch.jev = JevEvaluationBudget.jevTotal - 1
            try batch.consume(jev: jev)
            XCTAssertThrowsError(try batch.consume(jev: jev))
            XCTAssertEqual(jev ? batch.caseJev : batch.caseModel, 1)
        }
        XCTAssertThrowsError(try JevEvaluationBudget(seconds: -1).consume(jev: false))
    }

    func testFixedCheckerRejectsWrongTargetDateAndAdditionalWrites() throws {
        let container = try ButlerStore.makePreviewContainer()
        try JevEvaluationCase.seed(container)
        let before = try JevEvaluationLot.read(container)
        var wrong = before
        wrong[1].quantity = 1 // Wrong same-name batch.
        XCTAssertFalse(JevEvaluationCase.all[0].stateMatches(before: before, after: wrong))
        wrong = before; wrong[0].expiry = "2030-10-08"
        XCTAssertFalse(JevEvaluationCase.all[5].stateMatches(before: before, after: wrong))
        wrong[0].expiry = "2030-10-09"; wrong[1].quantity = 2
        XCTAssertFalse(JevEvaluationCase.all[5].stateMatches(before: before, after: wrong))
    }

    func testNativeRunningCompletedAndCancelledScreens() async throws {
        let fixture = try EvaluationFixture()
        defer { fixture.clean() }
        let originalIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = false
        defer { UIApplication.shared.isIdleTimerDisabled = originalIdle }
        fixture.delay = 0.01
        let runner = fixture.runner()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { JevEvaluationView(evaluation: runner) })
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(200))
        capture(window, "evaluation-ready")
        runner.start()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(runner.running)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        capture(window, "evaluation-running")
        try await finish(runner)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(runner.results.count, 32)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
        capture(window, "evaluation-completed")
        fixture.mode = .hang
        UIApplication.shared.isIdleTimerDisabled = true
        runner.start()
        try await Task.sleep(for: .milliseconds(100))
        runner.cancel()
        try await finish(runner)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(runner.results.first?.verdict, "cancelled")
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "restore a previously enabled idle timer override too")
        XCTAssertNoThrow(try runner.export())
        capture(window, "evaluation-cancelled")
    }

    func testNativeShareRetainsReadableJSONUntilDismissed() async throws {
        let fixture = try EvaluationFixture()
        defer { fixture.clean() }
        let runner = fixture.runner()
        runner.start()
        try await finish(runner)
        let expected = try runner.export()
        var export: EvaluationExport? = try EvaluationExport(data: expected)
        let url = try XCTUnwrap(export?.url)
        weak var retained = export
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let appeared = expectation(description: "The native share sheet appeared")
        let dismissed = expectation(description: "SwiftUI received the sheet dismissal")
        window.rootViewController = UIHostingController(rootView: EvaluationShareHarness(
            export: export!, onAppear: { appeared.fulfill() }, onDismiss: { dismissed.fulfill() }))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        export = nil // The share UI, not the presenting page, now owns the file.
        await fulfillment(of: [appeared], timeout: 5)
        try await finishSharePresentation(in: window)
        XCTAssertNotNil(retained)
        XCTAssertEqual(try Data(contentsOf: url), expected)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        capture(window, "evaluation-share")
        // Keep the hosting view alive until UIKit finishes dismissal and SwiftUI clears
        // its item binding. Destroying it immediately can strand the presentation state.
        try await dismissShare(in: window)
        await fulfillment(of: [dismissed], timeout: 5)
        window.isHidden = true
        window.rootViewController = nil
        let released = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in retained == nil }, object: nil)
        await fulfillment(of: [released], timeout: 5)
        XCTAssertNil(retained)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func finishSharePresentation(in window: UIWindow) async throws {
        let presenter = try XCTUnwrap(window.rootViewController)
        let presented = try XCTUnwrap(presenter.presentedViewController)
        if let transition = presented.transitionCoordinator {
            await withCheckedContinuation { continuation in
                let registered = transition.animate(alongsideTransition: nil) { _ in continuation.resume() }
                if !registered { continuation.resume() }
            }
        }
        XCTAssertFalse(presented.isBeingPresented)
    }

    private func dismissShare(in window: UIWindow) async throws {
        let presenter = try XCTUnwrap(window.rootViewController)
        XCTAssertNotNil(presenter.presentedViewController)
        await withCheckedContinuation { continuation in
            presenter.dismiss(animated: false) { continuation.resume() }
        }
        XCTAssertNil(presenter.presentedViewController)
    }

    private func capture(_ window: UIWindow, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func finish(_ runner: JevEvaluation) async throws {
        let deadline = Date.now.addingTimeInterval(25)
        while runner.running && Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(runner.running)
        if runner.running { runner.cancel() }
    }
}

private struct EvaluationShareHarness: View {
    @State var export: EvaluationExport?
    let onAppear: () -> Void
    let onDismiss: () -> Void
    var body: some View {
        Text("测试 JSON 分享")
            .sheet(item: $export, onDismiss: onDismiss) { export in
                EvaluationShareSheet(export: export).onAppear(perform: onAppear)
            }
    }
}

/// All requests, including auth/probes, terminate in this protocol. No real service is reachable.
@MainActor
private final class EvaluationFixture {
    enum Mode { case correct, wrong, jevFailure, retry, hang, unauthorized }
    let account = "evaluation-test-" + UUID().uuidString
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("evaluation-fixture-" + UUID().uuidString)
    let defaults: UserDefaults
    let network: URLSession
    var mode = Mode.correct
    var delay = 0.0
    var modelRequests = 0, jevRequests = 0
    var initialInputs: [String] = []
    private var retried = false
    init() throws {
        defaults = UserDefaults(suiteName: account)!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EvaluationProtocol.self]
        network = URLSession(configuration: config)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let credentials = SubscriptionCredentials(accessToken: "fixture-access", refreshToken: "fixture-refresh", accountID: "fixture-account", expiresAt: .now.addingTimeInterval(3600))
        let status = SecItemAdd([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "butler.subscription", kSecAttrAccount as String: account,
            kSecValueData as String: try JSONEncoder().encode(credentials)] as CFDictionary, nil)
        guard status == errSecSuccess else { throw SubscriptionError.keychain }
        try JevClient(defaults: defaults, keychainAccount: account).saveKey("fixture-key")
        EvaluationProtocol.handler = { [unowned self] in try await response($0) }
    }
    func clean() {
        try? SubscriptionConnection(network: network, keychainAccount: account).signOut()
        JevClient(defaults: defaults, keychainAccount: account).removeKey()
        defaults.removePersistentDomain(forName: account)
        network.invalidateAndCancel(); EvaluationProtocol.handler = nil
        try? FileManager.default.removeItem(at: root)
    }
    func runner(caseSeconds: TimeInterval = 90) -> JevEvaluation {
        JevEvaluation(connection: SubscriptionConnection(network: network, keychainAccount: account), network: network,
                      jevAccount: account, defaults: defaults, root: root, caseSeconds: caseSeconds)
    }
    private func response(_ request: URLRequest) async throws -> (Int, Data) {
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        if request.httpMethod == "HEAD" { return (200, Data()) }
        let body = try Self.body(request)
        if request.url?.host == "api.typesafe.ai" {
            jevRequests += 1
            if mode == .jevFailure { return (503, Data()) }
            let questions = body["questions"] as! [String: Any]
            return (200, try JSONSerialization.data(withJSONObject: ["answers": questions.mapValues { _ in ["noul": 0.99] }]))
        }
        guard request.url?.path == "/backend-api/codex/responses" else { throw URLError(.unsupportedURL) }
        modelRequests += 1
        if mode == .hang { try await Task.sleep(for: .seconds(60)) }
        if mode == .unauthorized { return (401, Data()) }
        if mode == .retry && !retried { retried = true; throw URLError(.networkConnectionLost) }
        let input = body["input"] as! [[String: Any]]
        let user = input.first { $0["role"] as? String == "user" }!
        let text = (user["content"] as! [[String: Any]])[0]["text"] as! String
        let steps = input.filter { $0["type"] as? String == "function_call_output" }.count
        if steps == 0 { initialInputs.append(text); XCTAssertEqual(input.count, 1) }
        var output: [[String: Any]]
        if steps >= 2 {
            output = [["type": "message", "content": [["type": "output_text", "text": "请核对后确认。"]]]]
        } else {
            var name = "search_inventory"
            var args: [String: Any] = ["query": "牛奶", "include_finished": false]
            if steps == 1 {
                let cold = "00000000-0000-0000-0000-000000000011"
                let frozen = "00000000-0000-0000-0000-000000000012"
                name = "propose_set_quantity"
                let amount = text.contains("喝掉") ? 2 : text.contains("5瓶") ? 5 : text.contains("冷冻的牛奶") ? 2 : 1
                args = ["lot_id": text.contains("冷冻的牛奶") ? frozen : cold, "quantity": mode == .wrong ? 2 : amount]
                if text.contains("新买") && !text.contains("不是新买") {
                    name = "propose_add_items"
                    args = ["items": [["name": "牛奶", "quantity": text.contains("2瓶") ? 2 : 1, "unit": "瓶", "storage": "冷藏", "package_expiry": NSNull(), "planned_use_by": NSNull(), "track": "expiry"]]]
                } else if text.contains("2030年") {
                    name = "propose_set_date"; args = ["lot_id": cold, "kind": "package_expiry", "date": "2030-10-09"]
                } else if text.contains("常温") {
                    name = "propose_move"; args = ["lot_id": cold, "location": "常温"]
                }
            }
            output = [["type": "function_call", "call_id": "call-\(steps)", "name": name,
                       "arguments": String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)]]
        }
        let event: [String: Any] = ["type": "response.completed", "response": ["id": "fixture", "model": "gpt-6-sol", "output": output]]
        return (200, Data("data: \(String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self))\n\n".utf8))
    }
    private static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

private final class EvaluationProtocol: URLProtocol, @unchecked Sendable {
    @MainActor static var handler: ((URLRequest) async throws -> (Int, Data))?
    private nonisolated let lock = NSLock()
    nonisolated(unsafe) private var work: Task<Void, Never>?
    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    nonisolated override func startLoading() {
        let task = Task { @MainActor in
            do {
                guard let handler = Self.handler else { throw URLError(.badServerResponse) }
                let (status, data) = try await handler(request)
                try Task.checkCancellation()
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        lock.withLock { work = task }
    }
    nonisolated override func stopLoading() { lock.withLock { work?.cancel() } }
}
#endif
