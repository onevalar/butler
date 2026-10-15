import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor
final class JevTurnJudgmentCacheTests: XCTestCase {
    private func question(_ id: String = "one", candidate: String = "冷藏牛奶剩 6 瓶", text: String = "是用户说的物品吗") -> JevClient.Question {
        .init(id: id, question: text, candidate: candidate)
    }

    private func waitForRequests(_ count: Int, judge: ReusableJevJudge) async {
        for _ in 0..<500 where judge.calls.count < count { await Task.yield() }
        XCTAssertEqual(judge.calls.count, count)
    }

    func testIdenticalJudgmentsReuseAcrossIDsAndOnlyNewQuestionsAreSent() async throws {
        let cache = JevTurnJudgmentCache(), judge = ReusableJevJudge()
        cache.beginTurn()
        let first = try await cache.judge(request: "牛奶还剩两瓶", questions: [question()], using: judge)
        XCTAssertEqual(first["one"], 0.9)
        let second = try await cache.judge(request: "牛奶还剩两瓶", questions: [question("renamed")], using: judge)
        XCTAssertEqual(second["renamed"], 0.9)
        XCTAssertNil(second["one"])
        XCTAssertEqual(judge.calls.count, 1)
        let mixed = try await cache.judge(request: "牛奶还剩两瓶", questions: [question("target"), question("meaning", text: "是剩余两瓶吗")], using: judge)
        XCTAssertEqual(Set(mixed.keys), ["target", "meaning"])
        XCTAssertEqual(judge.calls.count, 2)
        XCTAssertEqual(judge.calls[1].questions.map(\.id), ["meaning"])
    }

    func testCandidateQuestionContextAndTurnChangesRequireFreshJudgment() async throws {
        let cache = JevTurnJudgmentCache(), judge = ReusableJevJudge()
        cache.beginTurn()
        _ = try await cache.judge(request: "牛奶", questions: [question()], using: judge)
        _ = try await cache.judge(request: "牛奶", questions: [question(candidate: "冷藏牛奶剩 5 瓶")], using: judge)
        _ = try await cache.judge(request: "牛奶", questions: [question(text: "是用掉的数量吗")], using: judge)
        _ = try await cache.judge(request: "上一句：牛奶；这一句：冷藏的", questions: [question()], using: judge)
        XCTAssertEqual(judge.calls.count, 4)
        cache.beginTurn()
        _ = try await cache.judge(request: "牛奶", questions: [question()], using: judge)
        XCTAssertEqual(judge.calls.count, 5)
        cache.endTurn()
        _ = try await cache.judge(request: "牛奶", questions: [question()], using: judge)
        _ = try await cache.judge(request: "牛奶", questions: [question()], using: judge)
        XCTAssertEqual(judge.calls.count, 7, "Outside an active user turn, every call goes to the judge")
    }

    func testDisableReenableAndConfigurationChangesInvalidateEvenWithoutIntermediateCall() async throws {
        let cache = JevTurnJudgmentCache(), judge = ReusableJevJudge()
        cache.beginTurn()
        _ = try await cache.judge(request: "牛奶", questions: [question()], using: judge)
        judge.isEnabled = false
        do {
            _ = try await cache.judge(request: "牛奶", questions: [question()], using: judge)
            XCTFail("Disabled judge must not return cached answers")
        } catch JevClient.JevError.disabled { }
        XCTAssertEqual(judge.calls.count, 1)
        judge.isEnabled = true
        _ = try await cache.judge(request: "牛奶", questions: [question()], using: judge)
        judge.isEnabled = false
        judge.isEnabled = true
        _ = try await cache.judge(request: "牛奶", questions: [question()], using: judge)
        judge.reuseToken = UUID()
        _ = try await cache.judge(request: "牛奶", questions: [question()], using: judge)
        XCTAssertEqual(judge.calls.count, 4)
        judge.reuseToken = nil
        _ = try await cache.judge(request: "牛奶", questions: [question()], using: judge)
        _ = try await cache.judge(request: "牛奶", questions: [question()], using: judge)
        XCTAssertEqual(judge.calls.count, 6, "A judge without configuration-generation support cannot opt in accidentally")
    }

    func testFailuresTimeoutsAndIncompleteAnswersAreNeverReused() async throws {
        let cache = JevTurnJudgmentCache(), judge = ReusableJevJudge()
        cache.beginTurn()
        for error in [JevClient.JevError.timeout, .http(503)] {
            judge.nextError = error
            do { _ = try await cache.judge(request: "牛奶", questions: [question()], using: judge); XCTFail() }
            catch { }
        }
        judge.override = [:]
        do { _ = try await cache.judge(request: "牛奶", questions: [question()], using: judge); XCTFail() }
        catch { }
        judge.override = ["one": Double.nan]
        do { _ = try await cache.judge(request: "牛奶", questions: [question()], using: judge); XCTFail() }
        catch { }
        judge.override = nil
        let result = try await cache.judge(request: "牛奶", questions: [question()], using: judge)
        XCTAssertEqual(result["one"], 0.9)
        XCTAssertEqual(judge.calls.count, 5)
        _ = try await cache.judge(request: "牛奶", questions: [question()], using: judge)
        XCTAssertEqual(judge.calls.count, 5)
    }

    func testOverlappingConcurrentCallsMergeOnlyIdenticalInFlightQuestions() async throws {
        let cache = JevTurnJudgmentCache(), judge = ReusableJevJudge()
        judge.holdsRequests = true
        cache.beginTurn()
        let one = Task { try await cache.judge(request: "牛奶", questions: [question("a"), question("b", candidate: "冷冻牛奶")], using: judge) }
        await waitForRequests(1, judge: judge)
        let two = Task { try await cache.judge(request: "牛奶", questions: [question("same-b", candidate: "冷冻牛奶"), question("c", text: "是剩余数量吗")], using: judge) }
        await waitForRequests(2, judge: judge)
        XCTAssertEqual(judge.calls[1].questions.map(\.id), ["c"])
        XCTAssertEqual(judge.calls.reduce(0) { $0 + $1.questions.count }, 3)
        judge.finish(1)
        judge.finish(0)
        let first = try await one.value, second = try await two.value
        XCTAssertEqual(Set(first.keys), ["a", "b"])
        XCTAssertEqual(Set(second.keys), ["same-b", "c"])
        _ = try await cache.judge(request: "牛奶", questions: [question("new-b", candidate: "冷冻牛奶")], using: judge)
        XCTAssertEqual(judge.calls.count, 2)
    }

    func testCancellingOneWaiterReturnsPromptlyWithoutCancellingAnother() async throws {
        let cache = JevTurnJudgmentCache(), judge = ReusableJevJudge()
        cache.beginTurn(); judge.holdsRequests = true
        let cancelled = Task { try await cache.judge(request: "牛奶", questions: [question()], using: judge) }
        await waitForRequests(1, judge: judge)
        let survivor = Task { try await cache.judge(request: "牛奶", questions: [question("other")], using: judge) }
        for _ in 0..<10 { await Task.yield() }
        cancelled.cancel()
        let stopped = expectation(description: "Cancelled caller stops before shared response")
        Task {
            do { _ = try await cancelled.value; XCTFail() }
            catch is CancellationError { }
            catch { XCTFail("Unexpected cancellation error: \(error)") }
            stopped.fulfill()
        }
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertEqual(judge.calls.count, 1)
        judge.finish(0)
        let value = try await survivor.value
        XCTAssertEqual(value["other"], 0.9)
    }

    func testLateOldTurnAnswerCannotPopulateNewTurnCache() async throws {
        let cache = JevTurnJudgmentCache(), judge = ReusableJevJudge()
        cache.beginTurn(); judge.holdsRequests = true
        let old = Task { try await cache.judge(request: "牛奶", questions: [question()], using: judge) }
        await waitForRequests(1, judge: judge)
        cache.beginTurn()
        judge.holdsRequests = false; judge.probability = 0.3
        let current = try await cache.judge(request: "牛奶", questions: [question()], using: judge)
        XCTAssertEqual(current["one"], 0.3)
        judge.finish(0, probability: 0.9)
        do { _ = try await old.value; XCTFail("Old answer must be rejected") }
        catch is CancellationError { }
        let repeated = try await cache.judge(request: "牛奶", questions: [question()], using: judge)
        XCTAssertEqual(repeated["one"], 0.3)
        XCTAssertEqual(judge.calls.count, 2)
    }

    func testToolsReuseRepeatedTargetReviewWhileGateStillRequiresExplicitInsistence() async throws {
        let judge = ReusableJevJudge()
        judge.probability = 0.1
        let tools = try fixture(judge: judge)
        let context = ModelContext(tools.container)
        let product = CatalogProduct(canonicalName: "牛奶")
        let lot = InventoryLot(productID: product.id, quantity: 6, unit: "瓶")
        context.insert(product); context.insert(lot); try context.save()
        tools.beginTurn(request: "牛奶用完了", previous: nil)
        let arguments = #"{"lot_id":"\#(lot.id.uuidString)","reason":"used_up"}"#
        let first = await tools.execute(.init(id: "one", name: "propose_close", arguments: arguments))
        XCTAssertTrue(first.contains("needs_review"))
        XCTAssertTrue(tools.pending.isEmpty)
        let second = await tools.execute(.init(id: "two", name: "propose_close", arguments: arguments))
        XCTAssertTrue(second.contains("waiting_for_user_confirmation"))
        XCTAssertEqual(judge.calls.count, 1, "The same concern can be reused without another network request")
        XCTAssertEqual(tools.pending.count, 1)
        guard case .concern = tools.pending[0].check else { return XCTFail("Insistence must preserve the concern") }
        XCTAssertEqual(try tools.lotFacts(lot.id).quantity, 6)
    }

    func testSearchReuseStopsWhenInventoryCandidateOrTurnChangesAndNotesNeverCallJev() async throws {
        let judge = ReusableJevJudge(), tools = try fixture(judge: judge)
        let context = ModelContext(tools.container)
        let product = CatalogProduct(canonicalName: "牛奶")
        let one = InventoryLot(productID: product.id, quantity: 6, unit: "瓶")
        let two = InventoryLot(productID: product.id, quantity: 3, unit: "瓶")
        one.storageLocation = "冷藏"; two.storageLocation = "冷冻"
        context.insert(product); context.insert(one); context.insert(two); try context.save()
        tools.beginTurn(request: "牛奶还有多少", previous: nil)
        _ = try await tools.searchInventory("牛奶", includeFinished: false)
        _ = try await tools.searchInventory("牛奶", includeFinished: false)
        XCTAssertEqual(judge.calls.count, 1)
        try InventoryActions(modelContainer: tools.container).adjustQuantity(try tools.lotFacts(one.id), to: 4)
        _ = try await tools.searchInventory("牛奶", includeFinished: false)
        XCTAssertEqual(judge.calls.count, 2)
        XCTAssertEqual(judge.calls[1].questions.count, 1, "Only the changed candidate must be judged again")
        _ = await tools.execute(.init(id: "notes", name: "search_notes", arguments: #"{"query":"口味"}"#))
        XCTAssertEqual(judge.calls.count, 2)
        tools.endTurn(); tools.beginTurn(request: "牛奶还有多少", previous: nil)
        _ = try await tools.searchInventory("牛奶", includeFinished: false)
        XCTAssertEqual(judge.calls.count, 3)
        XCTAssertEqual(judge.calls[2].questions.count, 2)
    }

    private func fixture(judge: ReusableJevJudge) throws -> ButlerTools {
        let directory = URL.temporaryDirectory.appendingPathComponent("JevTurnCache-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let config = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ButlerTools(container: try ModelContainer(for: ButlerStore.schema, configurations: [config]),
            notes: try LocalMemoryStore(file: directory.appendingPathComponent("notes.json")),
            reminders: ReminderStore(file: directory.appendingPathComponent("reminders.json"), schedules: false), jev: judge,
            household: HouseholdStore(directory: directory.appendingPathComponent("household")), publishesChanges: false)
    }
}

@MainActor
private final class ReusableJevJudge: ConditionJudge {
    struct Call {
        let request: String
        let questions: [JevClient.Question]
    }
    var isConfigured = true { didSet { if oldValue != isConfigured { reuseToken = UUID() } } }
    var isEnabled = true { didSet { if oldValue != isEnabled { reuseToken = UUID() } } }
    var reuseToken: UUID? = UUID()
    var probability = 0.9
    var calls: [Call] = []
    var nextError: JevClient.JevError?
    var override: [String: Double]?
    var holdsRequests = false
    private var held: [Int: CheckedContinuation<[String: Double], any Error>] = [:]
    nonisolated deinit {}

    func judge(request: String, questions: [JevClient.Question]) async throws -> [String: Double] {
        let index = calls.count
        calls.append(Call(request: request, questions: questions))
        if let error = nextError { nextError = nil; throw error }
        if let override { return override }
        if holdsRequests {
            return try await withCheckedThrowingContinuation { held[index] = $0 }
        }
        return Dictionary(uniqueKeysWithValues: questions.map { ($0.id, probability) })
    }

    func finish(_ index: Int, probability: Double? = nil) {
        let answers = Dictionary(uniqueKeysWithValues: calls[index].questions.map { ($0.id, probability ?? self.probability) })
        held.removeValue(forKey: index)?.resume(returning: answers)
    }
}
