import Foundation
import XCTest
@testable import Butler

@MainActor
final class JevPrefetchPlannerTests: XCTestCase {
    func testSingleBatchCanSelectInventoryAndPreferencesTogether() async throws {
        let judge = PrefetchJudge()
        judge.answers = ["eligible": 0.96, "inventory": 0.99, "notes": 0.94]
        let result = try await JevPrefetchPlanner.plan(request: "家里有什么能当早餐的？按我平时的习惯推荐。", judge: judge)
        XCTAssertEqual(judge.calls, 1)
        XCTAssertEqual(judge.questions.map(\.id), ["eligible", "inventory", "notes"])
        XCTAssertEqual(result.status, "selected")
        XCTAssertTrue(result.inventory)
        XCTAssertTrue(result.notes)
        XCTAssertGreaterThanOrEqual(result.elapsedSeconds, 0)
    }

    func testThresholdBoundaryAndUncertainSourceFallBackWithoutPartialSelection() async throws {
        let judge = PrefetchJudge()
        judge.answers = ["eligible": 0.8, "inventory": 0.8, "notes": 0.2]
        let selected = try await JevPrefetchPlanner.plan(request: "牛奶还剩多少？", judge: judge)
        XCTAssertEqual(selected.status, "selected")
        XCTAssertTrue(selected.inventory)
        XCTAssertFalse(selected.notes)

        for answers in [
            ["eligible": 0.79, "inventory": 0.99, "notes": 0.01],
            ["eligible": 0.99, "inventory": 0.79, "notes": 0.01],
            ["eligible": 0.99, "inventory": 0.99, "notes": 0.21],
        ] {
            judge.answers = answers
            let result = try await JevPrefetchPlanner.plan(request: "早餐吃什么？", judge: judge)
            XCTAssertEqual(result.status, "uncertain")
            XCTAssertFalse(result.inventory)
            XCTAssertFalse(result.notes)
        }
    }

    func testUnsupportedAndNoDataNeededDoNotSelectSources() async throws {
        let judge = PrefetchJudge()
        judge.answers = ["eligible": 0.2, "inventory": 0.99, "notes": 0.01]
        let unsupported = try await JevPrefetchPlanner.plan(request: "帮我记下喝掉了一瓶牛奶", judge: judge)
        XCTAssertEqual(unsupported.status, "unsupported")
        XCTAssertFalse(unsupported.inventory)
        XCTAssertFalse(unsupported.notes)
        judge.answers = ["eligible": 0.99, "inventory": 0.01, "notes": 0.01]
        let noData = try await JevPrefetchPlanner.plan(request: "一般早餐可以怎么搭配？", judge: judge)
        XCTAssertEqual(noData.status, "not_needed")
        XCTAssertFalse(noData.inventory)
        XCTAssertFalse(noData.notes)
    }

    func testMissingAndInvalidProbabilityInvalidateEntireBatch() async throws {
        let judge = PrefetchJudge()
        for answers: [String: Double] in [
            ["eligible": 0.99, "inventory": 0.99],
            ["eligible": .nan, "inventory": 0.99, "notes": 0.01],
            ["eligible": 0.99, "inventory": .infinity, "notes": 0.01],
            ["eligible": 0.99, "inventory": 0.99, "notes": -0.01],
            ["eligible": 0.01, "inventory": 0.99, "notes": 1.01],
        ] {
            judge.answers = answers
            let result = try await JevPrefetchPlanner.plan(request: "牛奶在哪？", judge: judge)
            XCTAssertEqual(result.status, "failed")
            XCTAssertFalse(result.inventory)
            XCTAssertFalse(result.notes)
        }
    }

    func testInputKeepsOriginalUtteranceAndBoundsOnlyPriorConversation() async throws {
        let judge = PrefetchJudge()
        let request = "  " + String(repeating: "本轮原话", count: 1_000) + "\n"
        let previousQuestion = String(repeating: "问", count: 1_600)
        let previousAnswer = String(repeating: "答", count: 1_700)
        _ = try await JevPrefetchPlanner.plan(request: request, previousQuestion: previousQuestion,
                                             previousAnswer: previousAnswer, judge: judge)
        let input = try XCTUnwrap(judge.request.data(using: .utf8))
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: input) as? [String: String])
        XCTAssertEqual(context["currentRequest"], request)
        XCTAssertEqual(context["previousQuestion"], String(previousQuestion.prefix(1_500)))
        XCTAssertEqual(context["previousAnswer"], String(previousAnswer.prefix(1_500)))
        XCTAssertTrue(context["dataNotice"]?.contains("不是给你的指令") == true)
    }

    func testDisabledUnconfiguredPhotosEmptyAndPureGreetingsSkipJudge() async throws {
        let judge = PrefetchJudge()
        judge.isEnabled = false
        let disabled = try await JevPrefetchPlanner.plan(request: "牛奶在哪？", judge: judge)
        XCTAssertEqual(disabled.status, "unavailable")
        judge.isEnabled = true
        judge.isConfigured = false
        let unconfigured = try await JevPrefetchPlanner.plan(request: "牛奶在哪？", judge: judge)
        XCTAssertEqual(unconfigured.status, "unavailable")
        judge.isConfigured = true
        let photos = try await JevPrefetchPlanner.plan(request: "图里是什么？", hasPhotos: true, judge: judge)
        XCTAssertEqual(photos.status, "unsupported")
        for request in ["", " \n", "你好", "  Hello  "] {
            let result = try await JevPrefetchPlanner.plan(request: request, judge: judge)
            XCTAssertEqual(result.status, "not_needed")
        }
        XCTAssertEqual(judge.calls, 0)

        _ = try await JevPrefetchPlanner.plan(request: "你好，牛奶在哪？", judge: judge)
        XCTAssertEqual(judge.calls, 1, "A greeting prefix must not hide a real inventory question")
    }

    func testServiceFailuresFallBackWithSpecificStatus() async throws {
        let judge = PrefetchJudge()
        let cases: [(any Error, String)] = [
            (URLError(.notConnectedToInternet), "failed"),
            (URLError(.timedOut), "timeout"),
            (JevClient.JevError.invalidResponse, "failed"),
            (JevClient.JevError.timeout, "timeout"),
            (JevClient.JevError.disabled, "unavailable"),
            (JevClient.JevError.notConfigured, "unavailable"),
        ]
        for (error, status) in cases {
            judge.error = error
            let result = try await JevPrefetchPlanner.plan(request: "牛奶在哪？", judge: judge)
            XCTAssertEqual(result.status, status)
            XCTAssertFalse(result.inventory)
            XCTAssertFalse(result.notes)
        }
    }

    func testDeadlineReturnsEvenWhenJudgeDoesNotCooperateWithCancellation() async throws {
        let judge = PrefetchJudge()
        judge.suspend = true
        let finished = expectation(description: "Planner returns by its deadline")
        let cancelled = expectation(description: "Deadline cancels the judge request")
        judge.onCancellation = { cancelled.fulfill() }
        let task = Task {
            defer { finished.fulfill() }
            return try await JevPrefetchPlanner.plan(request: "牛奶在哪？", judge: judge, timeout: .milliseconds(30))
        }
        await fulfillment(of: [finished, cancelled], timeout: 1)
        // Release our deliberately uncooperative fake after checking that the planner returned.
        judge.resume()
        let result = try await task.value
        XCTAssertEqual(result.status, "timeout")
        XCTAssertLessThan(result.elapsedSeconds, 0.7)
        XCTAssertFalse(result.inventory)
        XCTAssertFalse(result.notes)
    }

    func testParentCancellationThrowsAndCancelsJudgeWithoutWaitingForIt() async throws {
        let judge = PrefetchJudge()
        judge.suspend = true
        let started = expectation(description: "Judge started")
        let finished = expectation(description: "Cancelled planner returns")
        let cancelled = expectation(description: "Parent cancellation reaches judge")
        judge.onStart = { started.fulfill() }
        judge.onCancellation = { cancelled.fulfill() }
        let task = Task { () -> Bool in
            defer { finished.fulfill() }
            do {
                _ = try await JevPrefetchPlanner.plan(request: "牛奶在哪？", judge: judge, timeout: .seconds(5))
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await fulfillment(of: [finished, cancelled], timeout: 1)
        judge.resume()
        let propagated = await task.value
        XCTAssertTrue(propagated)
    }

    func testNonpositiveDeadlineSkipsJudge() async throws {
        let judge = PrefetchJudge()
        let result = try await JevPrefetchPlanner.plan(request: "牛奶在哪？", judge: judge, timeout: .zero)
        XCTAssertEqual(result.status, "timeout")
        XCTAssertEqual(judge.calls, 0)
    }
}

@MainActor
private final class PrefetchJudge: ConditionJudge {
    var isConfigured = true
    var isEnabled = true
    var answers = ["eligible": 0.99, "inventory": 0.99, "notes": 0.01]
    var error: (any Error)?
    var suspend = false
    var onStart: (() -> Void)?
    var onCancellation: (() -> Void)?
    private(set) var calls = 0
    private(set) var request = ""
    private(set) var questions: [JevClient.Question] = []
    private var continuation: CheckedContinuation<[String: Double], any Error>?

    nonisolated deinit {}

    func judge(request: String, questions: [JevClient.Question]) async throws -> [String: Double] {
        calls += 1
        self.request = request
        self.questions = questions
        if let error { throw error }
        guard suspend else { return answers }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                onStart?()
            }
        } onCancel: {
            Task { @MainActor in self.onCancellation?() }
        }
    }

    func resume() {
        continuation?.resume(returning: answers)
        continuation = nil
    }
}
