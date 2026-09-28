import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor
final class PrefetchDataTests: XCTestCase {
    private var fixtureDirectories: [URL] = []

    override func tearDown() async throws {
        for directory in fixtureDirectories { try? FileManager.default.removeItem(at: directory) }
        fixtureDirectories = []
        try await super.tearDown()
    }

    private func makeTools(jev: (any ConditionJudge)? = nil) throws -> (ButlerTools, ModelContainer, NoJudge) {
        let configuration = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ButlerStore.schema, configurations: [configuration])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("prefetch-fixture-\(UUID())")
        fixtureDirectories.append(directory)
        let judge = NoJudge()
        let tools = ButlerTools(container: container, notes: try LocalMemoryStore(file: directory.appendingPathComponent("notes.json")),
                                reminders: ReminderStore(file: directory.appendingPathComponent("reminders.json"), schedules: false),
                                jev: jev ?? judge)
        return (tools, container, judge)
    }

    @discardableResult
    private func seed(_ context: ModelContext, name: String = "牛奶", quantity: Int = 3,
                      storage: String? = "冷藏", daysLeft: Int? = nil,
                      state: InventoryLotState = .active) -> InventoryLot {
        let product = CatalogProduct(canonicalName: name)
        let lot = InventoryLot(productID: product.id, quantity: quantity, unit: "瓶")
        lot.storageLocation = storage
        lot.state = state
        if let daysLeft { lot.packageExpiryDate = Calendar.current.date(byAdding: .day, value: daysLeft, to: .now) }
        context.insert(product)
        context.insert(lot)
        return lot
    }

    private func json(_ output: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

    private func search(_ tools: ButlerTools, query: String = "", finished: Bool = false) async throws -> [String: Any] {
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["query": query, "include_finished": finished]), as: UTF8.self)
        return try json(await tools.execute(LocalToolCall(id: "test", name: "search_inventory", arguments: arguments)))
    }

    func testReadsActualQuantitiesLocationsAndDatesWithoutJudgmentOrWrites() async throws {
        let (tools, container, judge) = try makeTools()
        let context = ModelContext(container)
        let first = seed(context, quantity: 3, daysLeft: 2)
        let second = seed(context, quantity: 6, storage: "冷冻", daysLeft: 7)
        seed(context, name: "已喝完的奶", quantity: 0, state: .depleted)
        try context.save()
        tools.proposeReminder(.init(text: "测试提醒", fireDate: .now.addingTimeInterval(3600)))
        let pendingID = try XCTUnwrap(tools.pending.first?.id)

        let results = try await tools.prefetch(inventory: true, notes: false)
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(result.call.id.hasPrefix("prefetch_"))
        XCTAssertEqual(result.call.name, "search_inventory")
        let arguments = try json(result.call.arguments)
        XCTAssertEqual(arguments["query"] as? String, "")
        XCTAssertEqual(arguments["include_finished"] as? Bool, false)
        let value = try json(result.output)
        let items = try XCTUnwrap(value["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["lot_id"] as? String }, [first.id.uuidString, second.id.uuidString])
        XCTAssertEqual(items.map { $0["quantity"] as? Int }, [3, 6])
        XCTAssertEqual(items.map { $0["storage"] as? String }, ["冷藏", "冷冻"])
        XCTAssertEqual(items.map { $0["days_left"] as? Int }, [2, 7])
        XCTAssertEqual(value["source"] as? String, "local_inventory")
        XCTAssertNotNil(value["queried_at"] as? String)
        XCTAssertEqual(value["count"] as? Int, 2)
        XCTAssertEqual(value["returned_count"] as? Int, 2)
        XCTAssertEqual(value["complete"] as? Bool, true)
        XCTAssertEqual(value["truncated"] as? Bool, false)
        let scope = try XCTUnwrap(value["scope"] as? [String: Any])
        XCTAssertEqual(scope["include_finished"] as? Bool, false)
        XCTAssertEqual(scope["conversation_history_included"] as? Bool, false)
        XCTAssertNil(value["finished"])
        XCTAssertEqual(judge.calls, 0)
        XCTAssertEqual(tools.pending.map(\.id), [pendingID])
        XCTAssertEqual(try context.fetch(FetchDescriptor<InventoryLot>()).count, 3)
        XCTAssertTrue(try context.fetch(FetchDescriptor<InventoryEvent>()).isEmpty)
        XCTAssertEqual(first.quantity, 3)
        XCTAssertEqual(second.quantity, 6)
    }

    func testSpecificSearchLinksReturnedLotsButOverviewDoesNot() async throws {
        let (tools, container, _) = try makeTools()
        let context = ModelContext(container)
        let milk = seed(context, name: "牛奶")
        let finished = seed(context, name: "旧牛奶", quantity: 0, state: .depleted)
        let eggs = seed(context, name: "鸡蛋")
        try context.save()
        _ = try await search(tools)
        XCTAssertTrue(tools.relatedScopes.isEmpty)
        _ = try await search(tools, query: "牛奶", finished: true)
        XCTAssertEqual(tools.relatedScopes, [.lot(milk.id), .lot(finished.id)])
        XCTAssertFalse(tools.relatedScopes.contains(.lot(eggs.id)))
        tools.beginTurn(request: "牛奶还剩多少", previous: nil)
        _ = try await tools.prefetch(inventory: true, notes: false)
        XCTAssertEqual(tools.relatedScopes, [.lot(milk.id)])
    }

    func testReadsOnlySelectedStoreAndKeepsCompleteNoteText() async throws {
        let (tools, _, judge) = try makeTools()
        let note = LocalMemory(id: UUID(), title: "早餐偏好", text: "早餐喜欢热牛奶，不喜欢甜食。", quantity: nil, revision: 2)
        try tools.notes.upsert(note)
        let results = try await tools.prefetch(inventory: false, notes: true)
        XCTAssertEqual(results.map(\.call.name), ["search_notes"])
        XCTAssertEqual(try json(results[0].call.arguments)["query"] as? String, "")
        let value = try json(results[0].output)
        let records = try XCTUnwrap(value["notes"] as? [[String: Any]])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["id"] as? String, note.id.uuidString)
        XCTAssertEqual(records[0]["text"] as? String, note.text)
        XCTAssertEqual(records[0]["revision"] as? Int, 2)
        XCTAssertEqual(value["complete"] as? Bool, true)
        XCTAssertEqual(value["source"] as? String, "local_notes")
        XCTAssertEqual((value["scope"] as? [String: Any])?["conversation_history_included"] as? Bool, false)
        XCTAssertEqual(tools.notes.records, [note])
        XCTAssertEqual(judge.calls, 0)
        let skipped = try await tools.prefetch(inventory: false, notes: false)
        XCTAssertTrue(skipped.isEmpty)
    }

    func testInventoryPrefetchCapsAt40AndOrdinarySearchReports80Limit() async throws {
        let (tools, container, _) = try makeTools()
        let context = ModelContext(container)
        for index in 0..<81 { seed(context, name: "物品\(index)", storage: nil) }
        try context.save()
        let prefetched = try await tools.prefetch(inventory: true, notes: false)
        let value = try json(prefetched[0].output)
        XCTAssertEqual(value["count"] as? Int, 81)
        XCTAssertEqual(value["returned_count"] as? Int, 40)
        XCTAssertEqual((value["items"] as? [[String: Any]])?.count, 40)
        XCTAssertEqual(value["complete"] as? Bool, false)
        XCTAssertEqual(value["truncated"] as? Bool, true)
        let ordinary = try await search(tools)
        XCTAssertEqual(ordinary["count"] as? Int, 81)
        XCTAssertEqual(ordinary["returned_count"] as? Int, 80)
        XCTAssertEqual(ordinary["complete"] as? Bool, false)
        XCTAssertEqual(ordinary["truncated"] as? Bool, true)
    }

    func testInventoryByteLimitOmitsWholeLargeRecordsAndContinues() async throws {
        let (tools, container, _) = try makeTools()
        let context = ModelContext(container)
        let oversized = seed(context, name: String(repeating: "大", count: 5_000), daysLeft: 1)
        let medium = seed(context, name: String(repeating: "中", count: 2_500), daysLeft: 2)
        let anotherMedium = seed(context, name: String(repeating: "次", count: 2_500), daysLeft: 3)
        let small = seed(context, name: "小瓶牛奶", daysLeft: 4)
        try context.save()
        let results = try await tools.prefetch(inventory: true, notes: false)
        let value = try json(results[0].output)
        let items = try XCTUnwrap(value["items"] as? [[String: Any]])
        let ids = items.compactMap { $0["lot_id"] as? String }
        XCTAssertEqual(ids, [medium.id.uuidString, small.id.uuidString])
        XCTAssertFalse(ids.contains(oversized.id.uuidString))
        XCTAssertFalse(ids.contains(anotherMedium.id.uuidString))
        XCTAssertEqual(items[0]["name"] as? String, String(repeating: "中", count: 2_500))
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]).count, 12_000)
        XCTAssertEqual(value["count"] as? Int, 4)
        XCTAssertEqual(value["returned_count"] as? Int, 2)
        XCTAssertEqual(value["complete"] as? Bool, false)
        XCTAssertEqual(value["truncated"] as? Bool, true)
    }

    func testNotesRespect20RecordLimit() async throws {
        let (tools, _, _) = try makeTools()
        for index in 0..<21 {
            try tools.notes.upsert(.init(id: UUID(), title: "习惯\(index)", text: "喜欢热食", quantity: nil, revision: 1))
        }
        let results = try await tools.prefetch(inventory: false, notes: true)
        let value = try json(results[0].output)
        XCTAssertEqual(value["count"] as? Int, 21)
        XCTAssertEqual(value["returned_count"] as? Int, 20)
        XCTAssertEqual((value["notes"] as? [[String: Any]])?.count, 20)
        XCTAssertEqual(value["complete"] as? Bool, false)
        XCTAssertEqual(value["truncated"] as? Bool, true)
    }

    func testNotesByteLimitPreservesWholeRecordsAndContinuesPastOmissions() async throws {
        let (tools, _, _) = try makeTools()
        let notes = [
            LocalMemory(id: UUID(), title: "超大", text: String(repeating: "大", count: 3_000), quantity: nil, revision: 1),
            LocalMemory(id: UUID(), title: "第一条", text: String(repeating: "中", count: 1_500), quantity: nil, revision: 1),
            LocalMemory(id: UUID(), title: "第二条", text: String(repeating: "次", count: 1_500), quantity: nil, revision: 1),
            LocalMemory(id: UUID(), title: "早餐", text: "喜欢热牛奶", quantity: nil, revision: 1),
        ]
        for note in notes { try tools.notes.upsert(note) }
        let results = try await tools.prefetch(inventory: false, notes: true)
        let value = try json(results[0].output)
        let records = try XCTUnwrap(value["notes"] as? [[String: Any]])
        XCTAssertEqual(records.compactMap { $0["id"] as? String }, [notes[1].id.uuidString, notes[3].id.uuidString])
        XCTAssertEqual(records.compactMap { $0["text"] as? String }, [notes[1].text, notes[3].text])
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]).count, 8_000)
        XCTAssertEqual(value["count"] as? Int, 4)
        XCTAssertEqual(value["returned_count"] as? Int, 2)
        XCTAssertEqual(value["complete"] as? Bool, false)
        XCTAssertEqual(value["truncated"] as? Bool, true)
    }

    func testEmptyResultsAreCompleteAndDistinctFromFailures() async throws {
        let (tools, _, _) = try makeTools()
        let results = try await tools.prefetch(inventory: true, notes: true)
        XCTAssertEqual(results.map(\.call.name), ["search_inventory", "search_notes"])
        XCTAssertEqual(Set(results.map(\.call.id)).count, 2)
        for result in results {
            let value = try json(result.output)
            XCTAssertEqual(value["count"] as? Int, 0)
            XCTAssertEqual(value["returned_count"] as? Int, 0)
            XCTAssertEqual(value["complete"] as? Bool, true)
            XCTAssertEqual(value["truncated"] as? Bool, false)
            XCTAssertNil(value["error"])
        }
    }

    func testNewPrefetchReadsChangesWithoutCaching() async throws {
        let (tools, container, _) = try makeTools()
        let context = ModelContext(container)
        let lot = seed(context, quantity: 3)
        try context.save()
        let before = try await tools.prefetch(inventory: true, notes: false)
        lot.quantity = 1
        lot.storageLocation = "冷冻"
        try context.save()
        let after = try await tools.prefetch(inventory: true, notes: false)
        let beforeItem = try XCTUnwrap((try json(before[0].output)["items"] as? [[String: Any]])?.first)
        let afterItem = try XCTUnwrap((try json(after[0].output)["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(beforeItem["quantity"] as? Int, 3)
        XCTAssertEqual(afterItem["quantity"] as? Int, 1)
        XCTAssertEqual(afterItem["storage"] as? String, "冷冻")
        XCTAssertNotEqual(before[0].call.id, after[0].call.id)
    }

    func testOrdinarySearchReportsMatchedCountAndFinishedRangeSeparately() async throws {
        let (tools, container, _) = try makeTools()
        let context = ModelContext(container)
        seed(context, name: "牛奶")
        seed(context, name: "苹果汁")
        for _ in 0..<35 { seed(context, name: "牛奶", quantity: 0, state: .depleted) }
        let old = seed(context, name: "牛奶", quantity: 0, state: .depleted)
        old.updatedAt = Calendar.current.date(byAdding: .day, value: -40, to: .now)!
        try context.save()
        let value = try await search(tools, query: "牛奶", finished: true)
        XCTAssertEqual(value["count"] as? Int, 1)
        XCTAssertEqual(value["returned_count"] as? Int, 1)
        XCTAssertEqual(value["count_unit"] as? String, "inventory_lots")
        XCTAssertEqual(value["finished_count"] as? Int, 35)
        XCTAssertEqual(value["finished_returned_count"] as? Int, 30)
        XCTAssertEqual(value["finished_truncated"] as? Bool, true)
        XCTAssertEqual(value["active_complete"] as? Bool, true)
        XCTAssertEqual(value["complete"] as? Bool, false)
        XCTAssertEqual(value["truncated"] as? Bool, true)
        let scope = try XCTUnwrap(value["scope"] as? [String: Any])
        XCTAssertEqual(scope["include_finished"] as? Bool, true)
        XCTAssertEqual(scope["finished_window_days"] as? Int, 30)
        XCTAssertEqual(scope["older_finished_included"] as? Bool, false)
    }

    func testCancelledPrefetchThrowsInsteadOfReturningEmptyData() async throws {
        let (tools, _, _) = try makeTools()
        let task = Task { @MainActor in try await tools.prefetch(inventory: true, notes: true) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {
            // Expected: no fabricated empty result is sent to the main model.
        }
    }

    func testJevRejectingAllCandidatesDoesNotClaimCompleteEmptyInventory() async throws {
        let judge = SearchJudge()
        let (tools, container, _) = try makeTools(jev: judge)
        let context = ModelContext(container)
        seed(context, name: "牛奶")
        seed(context, name: "豆浆")
        try context.save()
        tools.beginTurn(request: "家里有什么早餐饮品", previous: nil)

        let value = try await search(tools, query: "早餐饮品")
        XCTAssertEqual(judge.calls, 1)
        XCTAssertEqual(value["count"] as? Int, 0, "count remains the retained result count, not all active inventory")
        XCTAssertEqual(value["returned_count"] as? Int, 0)
        XCTAssertEqual((value["items"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(value["semantically_filtered"] as? Bool, true)
        XCTAssertEqual(value["semantic_candidate_count"] as? Int, 2)
        XCTAssertEqual(value["semantic_excluded_count"] as? Int, 2)
        XCTAssertEqual(value["complete"] as? Bool, false)
        XCTAssertEqual(value["active_complete"] as? Bool, false)
        XCTAssertEqual(value["truncated"] as? Bool, false, "semantic exclusion is distinct from output limits")
        XCTAssertEqual(value["active_truncated"] as? Bool, false)
        XCTAssertEqual((value["scope"] as? [String: Any])?["match_method"] as? String, "jev_candidate_pool")
        XCTAssertTrue((value["hint"] as? String)?.contains("不能据此断言没有") == true)
    }

    func testJevRetainingSomeCandidatesReportsExcludedRecordsEvenWithFinishedSearch() async throws {
        let judge = SearchJudge()
        let (tools, container, _) = try makeTools(jev: judge)
        let context = ModelContext(container)
        let milk = seed(context, name: "牛奶")
        seed(context, name: "豆浆")
        seed(context, name: "苹果汁")
        try context.save()
        judge.probabilities[milk.id.uuidString] = 0.9
        tools.beginTurn(request: "家里有什么早餐饮品", previous: nil)

        let value = try await search(tools, query: "早餐饮品", finished: true)
        XCTAssertEqual(value["count"] as? Int, 1)
        XCTAssertEqual(value["returned_count"] as? Int, 1)
        XCTAssertEqual((value["items"] as? [[String: Any]])?.first?["lot_id"] as? String, milk.id.uuidString)
        XCTAssertEqual(value["semantically_filtered"] as? Bool, true)
        XCTAssertEqual(value["semantic_candidate_count"] as? Int, 3)
        XCTAssertEqual(value["semantic_excluded_count"] as? Int, 2)
        XCTAssertEqual(value["complete"] as? Bool, false, "the finished result must not overwrite semantic incompleteness")
        XCTAssertEqual(value["active_complete"] as? Bool, false)
        XCTAssertEqual(value["finished_complete"] as? Bool, true)
        XCTAssertEqual(value["truncated"] as? Bool, false)
        XCTAssertEqual(value["active_truncated"] as? Bool, false)
        XCTAssertTrue((value["hint"] as? String)?.contains("可查询全部或更换关键词") == true)
    }
}

@MainActor
private final class NoJudge: ConditionJudge {
    // Available on purpose: prefetch must bypass judgment even with Jev switched on.
    var isConfigured: Bool { true }
    private(set) var calls = 0
    nonisolated deinit {}

    func judge(request: String, questions: [JevClient.Question]) async throws -> [String: Double] {
        calls += 1
        XCTFail("Data prefetch must not call Jev")
        return [:]
    }
}

@MainActor
private final class SearchJudge: ConditionJudge {
    var isConfigured: Bool { true }
    var probabilities: [String: Double] = [:]
    private(set) var calls = 0
    nonisolated deinit {}

    func judge(request: String, questions: [JevClient.Question]) async throws -> [String: Double] {
        calls += 1
        return Dictionary(uniqueKeysWithValues: questions.map { ($0.id, probabilities[$0.id] ?? 0.1) })
    }
}
