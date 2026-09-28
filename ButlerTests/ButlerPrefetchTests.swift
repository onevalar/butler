import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor
final class ButlerPrefetchTests: XCTestCase {
    private func makeTools(judge: PrefetchJudge) throws -> (ButlerTools, ModelContainer) {
        let configuration = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ButlerStore.schema, configurations: [configuration])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("prefetch-tests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let tools = ButlerTools(container: container,
            notes: try LocalMemoryStore(file: directory.appendingPathComponent("notes.json")),
            reminders: ReminderStore(file: directory.appendingPathComponent("reminders.json"), schedules: false),
            jev: judge)
        let context = ModelContext(container)
        let product = CatalogProduct(canonicalName: "牛奶")
        context.insert(product)
        context.insert(InventoryLot(productID: product.id, quantity: 3, unit: "瓶", storageLocation: "冷藏"))
        try context.save()
        try tools.notes.upsert(LocalMemory(id: UUID(), title: "饮食偏好", text: "早餐喜欢喝牛奶", revision: 1))
        return (tools, container)
    }

    private func object(_ output: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

    private func result(_ results: [PrefetchedToolResult], named name: String) throws -> [String: Any] {
        try object(XCTUnwrap(results.first { $0.call.name == name }).output)
    }

    func testPrepareBatchesJudgmentsAndReturnsActualInventoryAndNotes() async throws {
        let judge = PrefetchJudge()
        let (tools, _) = try makeTools(judge: judge)
        let request = "按我的偏好，早餐能喝什么？"
        let results = try await ButlerPrefetch.prepare(request: request, enabled: true, tools: tools, log: { _ in })

        XCTAssertEqual(judge.requests.count, 1)
        XCTAssertTrue(try XCTUnwrap(judge.requests.first).request.contains(request))
        XCTAssertEqual(Set(try XCTUnwrap(judge.requests.first).questions.map(\.id)), ["eligible", "inventory", "notes"])
        XCTAssertEqual(Set(results.map { $0.call.name }), ["search_inventory", "search_notes"])
        let inventory = try result(results, named: "search_inventory")
        XCTAssertEqual(inventory["source"] as? String, "local_inventory")
        XCTAssertEqual(inventory["complete"] as? Bool, true)
        XCTAssertEqual(inventory["count"] as? Int, 1)
        XCTAssertNotNil(inventory["queried_at"] as? String)
        let milk = try XCTUnwrap((inventory["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(milk["name"] as? String, "牛奶")
        XCTAssertEqual(milk["quantity"] as? Int, 3)
        XCTAssertEqual(milk["storage"] as? String, "冷藏")
        let notes = try result(results, named: "search_notes")
        XCTAssertEqual(notes["source"] as? String, "local_notes")
        XCTAssertEqual(notes["complete"] as? Bool, true)
        XCTAssertEqual((notes["notes"] as? [[String: Any]])?.first?["text"] as? String, "早餐喜欢喝牛奶")
        XCTAssertTrue(tools.pending.isEmpty, "Prefetch cannot propose or save changes")
    }

    func testFirstModelRequestIncludesOriginalMessageAndRealToolResults() async throws {
        let judge = PrefetchJudge()
        judge.answers["notes"] = 0
        let (tools, _) = try makeTools(judge: judge)
        let request = "家里还剩几瓶牛奶？"
        let prefetched = try await ButlerPrefetch.prepare(request: request, enabled: true, tools: tools, log: { _ in })
        let model = PrefetchModel()
        model.steps = [{ messages in
            guard case .user(let text) = messages.first else { throw PrefetchTestError.unexpectedMessage }
            XCTAssertEqual(text, request)
            let outputs = messages.compactMap { message -> String? in
                if case .tool(_, let output) = message { return output }
                return nil
            }
            XCTAssertEqual(outputs.count, 1)
            let inventory = try self.object(XCTUnwrap(outputs.first))
            XCTAssertEqual((inventory["items"] as? [[String: Any]])?.first?["quantity"] as? Int, 3)
            return LocalModelReply(text: "家里还剩3瓶牛奶。", calls: [])
        }]
        var messages: [LocalAgentMessage] = [.user(request)]
        var executed = 0
        let answer = try await ToolConversationLoop.run(model: model, messages: &messages, prefetched: prefetched,
            execute: { _ in executed += 1; return "unexpected" }, log: { _ in })

        XCTAssertEqual(answer, "家里还剩3瓶牛奶。")
        XCTAssertEqual(model.requests.count, 1)
        XCTAssertEqual(executed, 0)
    }

    func testIncompletePrefetchStillAllowsOrdinaryInventoryLookup() async throws {
        let judge = PrefetchJudge()
        judge.answers["notes"] = 0
        let (tools, container) = try makeTools(judge: judge)
        let context = ModelContext(container)
        for index in 0..<40 {
            let product = CatalogProduct(canonicalName: "其他物品\(index)")
            context.insert(product)
            context.insert(InventoryLot(productID: product.id, quantity: 1, unit: "件"))
        }
        try context.save()
        let request = "家里还剩几瓶牛奶？"
        tools.beginTurn(request: request, previous: nil)
        let prefetched = try await ButlerPrefetch.prepare(request: request, enabled: true, tools: tools, log: { _ in })
        let inventory = try result(prefetched, named: "search_inventory")
        XCTAssertEqual(inventory["complete"] as? Bool, false)
        XCTAssertEqual(inventory["truncated"] as? Bool, true)
        XCTAssertEqual(inventory["count"] as? Int, 41)
        let call = LocalToolCall(id: "lookup-milk", name: "search_inventory",
                                arguments: #"{"query":"牛奶","include_finished":false}"#)
        let model = PrefetchModel()
        model.steps = [
            { _ in LocalModelReply(text: "", calls: [call]) },
            { messages in
                guard case .tool(let id, let output) = messages.last else { throw PrefetchTestError.unexpectedMessage }
                XCTAssertEqual(id, call.id)
                let found = try self.object(output)
                XCTAssertEqual(found["complete"] as? Bool, true)
                XCTAssertEqual((found["items"] as? [[String: Any]])?.first?["quantity"] as? Int, 3)
                return LocalModelReply(text: "还剩3瓶。", calls: [])
            }
        ]
        var messages: [LocalAgentMessage] = [.user(request)]
        var executed: [String] = []
        let answer = try await ToolConversationLoop.run(model: model, messages: &messages, prefetched: prefetched,
            execute: { executed.append($0.name); return await tools.execute($0) }, log: { _ in })

        XCTAssertEqual(answer, "还剩3瓶。")
        XCTAssertEqual(executed, ["search_inventory"])
        XCTAssertEqual(model.requests.count, 2)
        XCTAssertEqual(judge.requests.count, 1, "This exact, single-item lookup needs no second Jev judgment")
    }

    func testParentCancellationDuringPlanningCannotReachMainModel() async throws {
        let judge = PrefetchJudge()
        judge.suspends = true
        let (tools, _) = try makeTools(judge: judge)
        let model = PrefetchModel()
        let work = Task { @MainActor in
            let prefetched = try await ButlerPrefetch.prepare(request: "家里有什么？", enabled: true,
                tools: tools, timeout: .seconds(10), log: { _ in })
            var messages: [LocalAgentMessage] = [.user("家里有什么？")]
            _ = try await ToolConversationLoop.run(model: model, messages: &messages, prefetched: prefetched,
                execute: { _ in throw PrefetchTestError.unexpectedMessage }, log: { _ in })
        }
        for _ in 0..<100 where judge.requests.isEmpty { await Task.yield() }
        XCTAssertEqual(judge.requests.count, 1, "Cancel while the planner is actually awaiting Jev")
        work.cancel()
        do {
            try await work.value
            XCTFail("Parent cancellation must propagate, not turn into ordinary prefetch fallback")
        } catch is CancellationError {
            // Expected: the caller must not submit the main model request after Stop.
        }
        XCTAssertTrue(model.requests.isEmpty)
        XCTAssertTrue(tools.pending.isEmpty)
    }

    func testDisabledPhotosAndUnavailableJudgeNeverRequestJev() async throws {
        let judge = PrefetchJudge()
        let (tools, _) = try makeTools(judge: judge)
        let disabled = try await ButlerPrefetch.prepare(request: "家里有什么？", enabled: false, tools: tools, log: { _ in })
        let photo = try await ButlerPrefetch.prepare(request: "看看这张照片", hasPhotos: true, enabled: true,
            tools: tools, log: { _ in })
        judge.isEnabled = false
        let unavailable = try await ButlerPrefetch.prepare(request: "家里有什么？", enabled: true, tools: tools, log: { _ in })
        XCTAssertTrue(disabled.isEmpty)
        XCTAssertTrue(photo.isEmpty)
        XCTAssertTrue(unavailable.isEmpty)
        XCTAssertTrue(judge.requests.isEmpty)
    }

    func testFailedAndLowConfidencePlansAddNoFabricatedToolData() async throws {
        for answers: [String: Double]? in [nil,
            ["eligible": 0.79, "inventory": 1, "notes": 1],
            ["eligible": 1, "inventory": 0.79, "notes": 0.79]] {
            let judge = PrefetchJudge()
            if let answers { judge.answers = answers } else { judge.failure = URLError(.notConnectedToInternet) }
            let (tools, _) = try makeTools(judge: judge)
            let prefetched = try await ButlerPrefetch.prepare(request: "家里有什么？", enabled: true,
                tools: tools, log: { _ in })
            XCTAssertTrue(prefetched.isEmpty)
            let model = PrefetchModel()
            model.steps = [{ messages in
                XCTAssertEqual(messages.count, 1, "Fallback must preserve the ordinary user-only start")
                guard case .user(let text) = messages.first else { throw PrefetchTestError.unexpectedMessage }
                XCTAssertEqual(text, "家里有什么？")
                return LocalModelReply(text: "继续正常流程", calls: [])
            }]
            var messages: [LocalAgentMessage] = [.user("家里有什么？")]
            _ = try await ToolConversationLoop.run(model: model, messages: &messages, prefetched: prefetched,
                execute: { _ in throw PrefetchTestError.unexpectedMessage }, log: { _ in })
            XCTAssertEqual(model.requests.count, 1)
        }
    }

    func testPrefetchedFreeTextIsEncodedAsToolOutputNeverDeveloperContent() async throws {
        let judge = PrefetchJudge()
        let (tools, _) = try makeTools(judge: judge)
        let marker = "UNTRUSTED_NOTE_\(UUID().uuidString)"
        try tools.notes.upsert(LocalMemory(id: UUID(), title: "普通笔记", text: marker, revision: 1))
        let prefetched = try await ButlerPrefetch.prepare(request: "按我的偏好看看库存", enabled: true,
            tools: tools, log: { _ in })
        let model = PrefetchModel()
        model.steps = [{ _ in LocalModelReply(text: "可以。", calls: []) }]
        var messages: [LocalAgentMessage] = [.user("按我的偏好看看库存")]
        _ = try await ToolConversationLoop.run(model: model, messages: &messages, prefetched: prefetched,
            execute: { _ in throw PrefetchTestError.unexpectedMessage }, log: { _ in })
        let firstRequest = try XCTUnwrap(model.requests.first)
        let body = try object(String(decoding: SubscriptionModel.requestBody(firstRequest), as: UTF8.self))
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let outputs = input.filter { $0["type"] as? String == "function_call_output" }
        XCTAssertEqual(outputs.count, prefetched.count)
        XCTAssertEqual(Set(outputs.compactMap { $0["call_id"] as? String }), Set(prefetched.map { $0.call.id }))
        XCTAssertTrue(outputs.contains { ($0["output"] as? String)?.contains(marker) == true })
        XCTAssertFalse(input.contains { $0["role"] as? String == "developer" })
        let calls = input.filter { $0["type"] as? String == "function_call" }
        XCTAssertEqual(Set(calls.compactMap { $0["call_id"] as? String }), Set(prefetched.map { $0.call.id }))
    }

    func testEachPrepareReadsCurrentInventoryInsteadOfCachedQuantity() async throws {
        let judge = PrefetchJudge()
        judge.answers["notes"] = 0
        let (tools, container) = try makeTools(judge: judge)
        let first = try await ButlerPrefetch.prepare(request: "还剩多少牛奶？", enabled: true, tools: tools, log: { _ in })
        let firstInventory = try result(first, named: "search_inventory")
        XCTAssertEqual((firstInventory["items"] as? [[String: Any]])?.first?["quantity"] as? Int, 3)

        let context = ModelContext(container)
        let milk = try XCTUnwrap(context.fetch(FetchDescriptor<InventoryLot>()).first)
        milk.quantity = 1
        try context.save()

        let second = try await ButlerPrefetch.prepare(request: "还剩多少牛奶？", enabled: true, tools: tools, log: { _ in })
        let secondInventory = try result(second, named: "search_inventory")
        XCTAssertEqual((secondInventory["items"] as? [[String: Any]])?.first?["quantity"] as? Int, 1)
        XCTAssertEqual(judge.requests.count, 2)
        XCTAssertNotEqual(first.first?.call.id, second.first?.call.id)
    }
}

private enum PrefetchTestError: Error { case unexpectedMessage }

@MainActor
private final class PrefetchJudge: ConditionJudge {
    nonisolated deinit {}
    struct Request {
        let request: String
        let questions: [JevClient.Question]
    }
    var isConfigured = true
    var isEnabled = true
    var answers = ["eligible": 1.0, "inventory": 1.0, "notes": 1.0]
    var requests: [Request] = []
    var failure: Error?
    var suspends = false

    func judge(request: String, questions: [JevClient.Question]) async throws -> [String: Double] {
        requests.append(Request(request: request, questions: questions))
        if suspends { try await Task.sleep(for: .seconds(60)) }
        if let failure { throw failure }
        return answers
    }
}

@MainActor
private final class PrefetchModel: LocalAgentModel {
    nonisolated deinit {}
    var steps: [([LocalAgentMessage]) throws -> LocalModelReply] = []
    var requests: [[LocalAgentMessage]] = []

    func reply(to messages: [LocalAgentMessage]) async throws -> LocalModelReply {
        requests.append(messages)
        guard !steps.isEmpty else { throw PrefetchTestError.unexpectedMessage }
        return try steps.removeFirst()(messages)
    }
}
