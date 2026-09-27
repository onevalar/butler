import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor
final class ButlerToolsTests: XCTestCase {
    private func makeTools(jev: (any ConditionJudge)? = nil) throws -> (ButlerTools, ModelContainer) {
        let configuration = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ButlerStore.schema, configurations: [configuration])
        let notesFile = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID()).json")
        let remindersFile = FileManager.default.temporaryDirectory.appendingPathComponent("reminders-\(UUID()).json")
        let tools = ButlerTools(container: container, notes: try LocalMemoryStore(file: notesFile),
                                reminders: ReminderStore(file: remindersFile, schedules: false), jev: jev ?? NoJudge())
        return (tools, container)
    }

    /// Two milks: an older one in the fridge (3 left) and a newer one in the freezer (6 left).
    private func seedTwoMilks(_ container: ModelContainer) throws -> (fridge: InventoryLot, freezer: InventoryLot) {
        let context = ModelContext(container)
        let product = CatalogProduct(canonicalName: "牛奶")
        let fridge = InventoryLot(productID: product.id, quantity: 3, unit: "瓶")
        fridge.storageLocation = "冷藏"
        let freezer = InventoryLot(productID: product.id, quantity: 6, unit: "瓶")
        freezer.storageLocation = "冷冻"
        context.insert(product); context.insert(fridge); context.insert(freezer)
        try context.save()
        return (fridge, freezer)
    }

    private func call(_ tools: ButlerTools, _ name: String, _ arguments: String) async -> [String: Any] {
        let output = await tools.execute(LocalToolCall(id: UUID().uuidString, name: name, arguments: arguments))
        return (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] ?? [:]
    }

    func testAddSearchAdjustAndCloseOnlyAfterConfirmation() async throws {
        let (tools, container) = try makeTools()
        let proposal = await call(tools, "propose_add_items", #"""
        {"items":[{"name":"牛奶","quantity":2,"unit":"瓶","storage":"冷藏","package_expiry":"2026-10-03","planned_use_by":null},
                  {"name":"草莓","quantity":1,"unit":"盒","storage":null,"package_expiry":null,"planned_use_by":null}]}
        """#)
        XCTAssertEqual(proposal["saved"] as? Bool, false)
        XCTAssertEqual(tools.pending.count, 2)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).isEmpty, "nothing saved before confirm")

        let receipts = tools.confirmAll()
        XCTAssertEqual(receipts.filter { $0.hasPrefix("✓") }.count, 2, receipts.joined())
        XCTAssertTrue(tools.pending.isEmpty)

        let found = await call(tools, "search_inventory", #"{"query":"牛奶 鸡蛋","include_finished":false}"#)
        let items = try XCTUnwrap(found["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?["storage"] as? String, "冷藏")
        XCTAssertEqual(items.first?["governing_date"] as? String, "2026-10-03")
        let milkID = try XCTUnwrap(items.first?["lot_id"] as? String)

        _ = await call(tools, "propose_set_quantity", #"{"lot_id":"\#(milkID)","quantity":1}"#)
        _ = await call(tools, "propose_move", #"{"lot_id":"\#(milkID)","location":"冷冻"}"#)
        XCTAssertEqual(tools.confirmAll().filter { $0.hasPrefix("✓") }.count, 2)
        let milk = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).first { $0.id.uuidString == milkID })
        XCTAssertEqual(milk.quantity, 1)
        XCTAssertEqual(milk.storageLocation, "冷冻")

        _ = await call(tools, "propose_close", #"{"lot_id":"\#(milkID)","reason":"used_up"}"#)
        XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✓"), true)
        let all = await call(tools, "search_inventory", #"{"query":"","include_finished":true}"#)
        XCTAssertEqual(all["count"] as? Int, 1)
        XCTAssertEqual((all["finished"] as? [[String: Any]])?.count, 1)
    }

    func testBadArgumentsAreReportedNotSaved() async throws {
        let (tools, _) = try makeTools()
        let unknownLot = await call(tools, "propose_set_quantity", #"{"lot_id":"\#(UUID().uuidString)","quantity":1}"#)
        XCTAssertNotNil(unknownLot["error"])
        let badDate = await call(tools, "propose_add_items",
            #"{"items":[{"name":"面包","quantity":1,"unit":"袋","storage":null,"package_expiry":"十月三号","planned_use_by":null}]}"#)
        XCTAssertNotNil(badDate["error"])
        XCTAssertTrue(tools.pending.isEmpty)
    }

    func testNotesAreRememberedAfterConfirmation() async throws {
        let (tools, _) = try makeTools()
        _ = await call(tools, "propose_note", #"{"id":null,"title":"买菜习惯","text":"周末去盒马买菜"}"#)
        XCTAssertTrue(tools.notes.records.isEmpty)
        _ = tools.confirmAll()
        let found = await tools.execute(LocalToolCall(id: "n", name: "search_notes", arguments: #"{"query":"盒马"}"#))
        XCTAssertTrue(found.contains("周末去盒马买菜"))
    }

    func testJevToolOnlyOfferedWithKey() throws {
        let (tools, _) = try makeTools()
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(tools.toolJSON.utf8)) as? [Any])
        XCTAssertFalse(tools.toolJSON.contains("judge_with_jev"))
    }

    func testWaterIsQuantityOnlyAndCanBeSwitched() async throws {
        let (tools, container) = try makeTools()
        _ = await call(tools, "propose_add_items", #"""
        {"items":[{"name":"七鲜饮用纯净水","quantity":6,"unit":"瓶","storage":"卫生间","package_expiry":null,"planned_use_by":null,"track":"quantity"},
                  {"name":"红枣酸奶","quantity":2,"unit":"瓶","storage":null,"package_expiry":"2026-09-30","planned_use_by":null,"track":"expiry"}]}
        """#)
        XCTAssertEqual(tools.confirmAll().filter { $0.hasPrefix("✓") }.count, 2)
        let found = await call(tools, "search_inventory", #"{"query":"水","include_finished":false}"#)
        let water = try XCTUnwrap((found["items"] as? [[String: Any]])?.first { ($0["name"] as? String)?.contains("水") == true })
        XCTAssertEqual(water["track"] as? String, "quantity")
        XCTAssertEqual(water["time_left"] as? String, "剩 6 瓶")

        let yoghurt = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<CatalogProduct>()).first { $0.canonicalName == "红枣酸奶" })
        let lot = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).first { $0.productID == yoghurt.id })
        _ = await call(tools, "propose_set_tracking", #"{"lot_id":"\#(lot.id.uuidString)","track":"quantity"}"#)
        XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✓"), true)
        let facts = LotFacts(lot: lot, product: try ModelContext(container).fetch(FetchDescriptor<CatalogProduct>()).first { $0.id == yoghurt.id })
        XCTAssertTrue(facts.quantityOnly)
        XCTAssertNil(facts.governingDate)
    }

    func testTimedRemindersAreSetListedAndCancelledAfterConfirmation() async throws {
        let (tools, _) = try makeTools()
        let later = Date.now.addingTimeInterval(3600)
        let time = ButlerTools.nowLabel.prefix(10) + " " + later.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        let proposal = await call(tools, "propose_reminder", #"{"text":"热一下剩饭","time":"\#(time)","repeat":"none"}"#)
        if Calendar.current.isDateInToday(later) {
            XCTAssertEqual(proposal["status"] as? String, "waiting_for_user_confirmation")
            XCTAssertTrue(tools.reminders.upcoming.isEmpty, "nothing is set before confirmation")
            _ = tools.confirmAll()
            XCTAssertEqual(tools.reminders.upcoming.first?.text, "热一下剩饭")
        }
        let past = await call(tools, "propose_reminder", #"{"text":"晚了","time":"2020-01-01 11:00","repeat":"none"}"#)
        XCTAssertNotNil(past["error"])

        _ = await call(tools, "propose_reminder", #"{"text":"吃药","time":"2020-01-01 21:00","repeat":"daily"}"#)
        _ = tools.confirmAll()
        let listed = await call(tools, "list_reminders", "{}")
        let daily = try XCTUnwrap((listed["reminders"] as? [[String: Any]])?.first { $0["text"] as? String == "吃药" })
        XCTAssertEqual(daily["when"] as? String, "每天 21:00")
        _ = await call(tools, "propose_cancel_reminder", #"{"id":"\#(daily["id"] as? String ?? "")"}"#)
        _ = tools.confirmAll()
        XCTAssertFalse(tools.reminders.upcoming.contains { $0.text == "吃药" })
    }

    func testChatContextIsSizedByContentNotTurnCount() throws {
        // Many short turns all fit.
        let short = (0..<60).map { ChatTurn(question: "问题\($0)", answer: "好的") }
        XCTAssertEqual(ButlerChat.recentWindow(short).count, 60)
        XCTAssertTrue(ButlerChat.turnsToSummarize(short, summary: .init()).isEmpty)

        // Long turns: only what fits the budget stays verbatim; the rest goes to the summary.
        var long = (0..<30).map { ChatTurn(question: "问题\($0)", answer: String(repeating: "长", count: 5000)) }
        long[29].photos = ["a.jpg"]
        long[29].receipts = ["✓ 新增 牛奶 ×1 瓶"]
        let window = ButlerChat.recentWindow(long)
        XCTAssertLessThan(window.count, 30)
        XCTAssertGreaterThanOrEqual(window.count, 1)
        let older = ButlerChat.turnsToSummarize(long, summary: .init())
        XCTAssertEqual(older.count + window.count, 30)

        let summary = ConversationSummary(text: "用户叫小安，想要每天提醒吃药", throughTurnID: older.last?.id)
        XCTAssertTrue(ButlerChat.turnsToSummarize(long, summary: summary).isEmpty)
        let context = ButlerChat.context(from: long, summary: summary)
        guard case .context(let first)? = context.first else { return XCTFail("summary comes first") }
        XCTAssertTrue(first.contains("小安"))
        XCTAssertFalse(context.contains { if case .userPhotos = $0 { return true }; return false })
        XCTAssertTrue(context.contains { if case .user(let text) = $0 { return text == "（当时附了照片）问题29" }; return false })
        for case .assistant(let reply) in context { XCTAssertLessThanOrEqual(reply.text.count, ButlerChat.answerLimit) }
    }

    func testModelCanBrowseTheWholeConversationAsNeeded() async throws {
        let (tools, _) = try makeTools()
        XCTAssertFalse(tools.toolJSON.contains("read_conversation"))
        let day = 86_400.0
        var turns = (0..<40).map { index in
            ChatTurn(question: "第\(index)句", answer: String(repeating: "答", count: 1000),
                     date: Date(timeIntervalSince1970: 1_790_000_000 + Double(index / 10) * day))
        }
        turns[3].question = "11点提醒我热剩饭"
        let archive = ConversationArchive(turns: turns, recentStart: 30, summaryThrough: 20)
        tools.conversation = { archive }
        XCTAssertTrue(tools.toolJSON.contains("read_conversation"))

        let overview = await call(tools, "conversation_overview", "{}")
        XCTAssertEqual(overview["total_turns"] as? Int, 40)
        XCTAssertEqual((overview["days"] as? [[String: Any]])?.count, 4)
        XCTAssertEqual(overview["already_in_context_from_turn"] as? Int, 31)

        let found = await call(tools, "search_conversation", #"{"query":"剩饭","from_date":null,"to_date":null,"limit":10}"#)
        XCTAssertEqual((found["matches"] as? [[String: Any]])?.first?["turn"] as? Int, 4)

        // Reading everything pages through all 40 original turns, nothing truncated.
        var cursor: Int? = nil
        var read: [[String: Any]] = []
        repeat {
            let arguments = #"{"from_turn":null,"to_turn":null,"from_date":null,"to_date":null,"cursor":\#(cursor.map(String.init) ?? "null")}"#
            let page = await call(tools, "read_conversation", arguments)
            read += page["turns"] as? [[String: Any]] ?? []
            cursor = page["next_cursor"] as? Int
        } while cursor != nil
        XCTAssertEqual(read.count, 40)
        XCTAssertEqual((read[3]["butler"] as? String)?.count, 1000)

        let oneDay = await call(tools, "read_conversation",
            #"{"from_turn":null,"to_turn":null,"from_date":"\#(turns[15].date.isoDay)","to_date":"\#(turns[15].date.isoDay)","cursor":null}"#)
        XCTAssertEqual((oneDay["turns"] as? [[String: Any]])?.count, 10)
    }

    // MARK: - Jev as the layer between the model and the data

    func testWithoutJevNothingIsCheckedAndEverythingStillWorks() async throws {
        let (tools, container) = try makeTools()
        let milks = try seedTwoMilks(container)
        tools.beginTurn(request: "冷藏的牛奶还剩2瓶", previous: nil)
        let output = await call(tools, "propose_set_quantity", #"{"lot_id":"\#(milks.fridge.id.uuidString)","quantity":2}"#)
        XCTAssertEqual(output["status"] as? String, "waiting_for_user_confirmation")
        XCTAssertNil(tools.pending.first?.check)
    }

    func testJevRanksSearchResultsAndFindsWhatKeywordsMissed() async throws {
        let judge = FakeJudge()
        let (tools, container) = try makeTools(jev: judge)
        let milks = try seedTwoMilks(container)
        judge.answer = { id, _ in id == milks.freezer.id.uuidString ? 0.9 : 0.2 }
        tools.beginTurn(request: "冻起来的那箱奶还有多少", previous: nil)
        let ranked = await call(tools, "search_inventory", #"{"query":"牛奶","include_finished":false}"#)
        XCTAssertEqual(ranked["judged_by"] as? String, "jev")
        let items = try XCTUnwrap(ranked["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2, "Jev reorders but never drops what the words matched")
        XCTAssertEqual(items.first?["lot_id"] as? String, milks.freezer.id.uuidString)

        let missed = await call(tools, "search_inventory", #"{"query":"早餐奶","include_finished":false}"#)
        XCTAssertNotNil(missed["found_by"])
        XCTAssertEqual((missed["items"] as? [[String: Any]])?.first?["lot_id"] as? String, milks.freezer.id.uuidString)
        XCTAssertEqual((missed["items"] as? [[String: Any]])?.count, 1)
    }

    func testJevPushesBackOnWrongLotThenOwnerSeesConcernIfModelInsists() async throws {
        let judge = FakeJudge()
        let (tools, container) = try makeTools(jev: judge)
        let milks = try seedTwoMilks(container)
        judge.answer = { id, _ in id == "t." + milks.freezer.id.uuidString ? 0.9 : 0.1 }
        tools.beginTurn(request: "冷冻那箱奶喝完了", previous: nil)
        let arguments = #"{"lot_id":"\#(milks.fridge.id.uuidString)","reason":"used_up"}"#
        let first = await call(tools, "propose_close", arguments)
        XCTAssertEqual(first["status"] as? String, "needs_review")
        XCTAssertTrue((first["jev_concern"] as? String)?.contains(milks.freezer.id.uuidString) == true)
        XCTAssertTrue(tools.pending.isEmpty)

        let insisted = await call(tools, "propose_close", arguments)
        XCTAssertEqual(insisted["status"] as? String, "waiting_for_user_confirmation")
        guard case .concern? = tools.pending.first?.check else { return XCTFail("owner must see Jev's concern") }

        tools.beginTurn(request: "冷冻那箱奶喝完了", previous: nil)
        let right = await call(tools, "propose_close", #"{"lot_id":"\#(milks.freezer.id.uuidString)","reason":"used_up"}"#)
        XCTAssertEqual(right["status"] as? String, "waiting_for_user_confirmation")
        XCTAssertEqual(tools.pending.first?.check, .passed)
    }

    func testJevCatchesEatenVersusRemaining() async throws {
        let judge = FakeJudge()
        let (tools, container) = try makeTools(jev: judge)
        let milks = try seedTwoMilks(container)
        // "喝了2瓶" from 6: "used 2, 4 left" is right; "2 left" is not.
        judge.answer = { id, question in
            if id.hasPrefix("m.") { return question.candidate.contains("还剩 4") ? 0.9 : 0.1 }
            return id.hasSuffix(milks.freezer.id.uuidString) ? 0.9 : 0.1
        }
        tools.beginTurn(request: "冷冻的牛奶喝了2瓶", previous: nil)
        let output = await call(tools, "propose_set_quantity", #"{"lot_id":"\#(milks.freezer.id.uuidString)","quantity":2}"#)
        XCTAssertEqual(output["status"] as? String, "needs_review")
        XCTAssertTrue((output["jev_concern"] as? String)?.contains("应剩 4") == true)
        let fixed = await call(tools, "propose_set_quantity", #"{"lot_id":"\#(milks.freezer.id.uuidString)","quantity":4}"#)
        XCTAssertEqual(fixed["status"] as? String, "waiting_for_user_confirmation")
    }

    func testJevQuestionsNewPurchaseAndInventedPackageDate() async throws {
        let judge = FakeJudge()
        let (tools, container) = try makeTools(jev: judge)
        _ = try seedTwoMilks(container)
        judge.answer = { id, _ in id.hasPrefix("n.") ? 0.1 : 0.9 }
        tools.beginTurn(request: "不是山姆的，是盒马买的牛奶", previous: "山姆买了牛奶")
        let correction = await call(tools, "propose_add_items",
            #"{"items":[{"name":"牛奶","quantity":1,"unit":"瓶","storage":null,"package_expiry":null,"planned_use_by":null}]}"#)
        XCTAssertEqual(correction["status"] as? String, "needs_review")
        XCTAssertEqual(judge.requests.last, "上一句：山姆买了牛奶\n这一句：不是山姆的，是盒马买的牛奶")

        judge.answer = { id, _ in id.hasPrefix("d.") ? 0.05 : 0.9 }
        tools.beginTurn(request: "买了一袋面包", previous: nil)
        let invented = await call(tools, "propose_add_items",
            #"{"items":[{"name":"面包","quantity":1,"unit":"袋","storage":null,"package_expiry":"2026-10-01","planned_use_by":null}]}"#)
        XCTAssertEqual(invented["status"] as? String, "needs_review")
        XCTAssertTrue(tools.pending.isEmpty)
    }

    func testJevFailureNeverBlocks() async throws {
        let judge = FakeJudge()
        judge.fails = true
        let (tools, container) = try makeTools(jev: judge)
        let milks = try seedTwoMilks(container)
        tools.beginTurn(request: "牛奶还剩一瓶", previous: nil)
        let search = await call(tools, "search_inventory", #"{"query":"牛奶","include_finished":false}"#)
        XCTAssertEqual((search["items"] as? [[String: Any]])?.count, 2)
        XCTAssertNotNil(search["jev"])
        let output = await call(tools, "propose_set_quantity", #"{"lot_id":"\#(milks.fridge.id.uuidString)","quantity":1}"#)
        XCTAssertEqual(output["status"] as? String, "waiting_for_user_confirmation")
        XCTAssertNil(tools.pending.first?.check)
    }
}

@MainActor
private final class NoJudge: ConditionJudge {
    var isConfigured: Bool { false }
    nonisolated deinit {}
    func judge(request: String, questions: [JevClient.Question]) async throws -> [String: Double] { [:] }
}

@MainActor
private final class FakeJudge: ConditionJudge {
    var isConfigured: Bool { true }
    var fails = false
    var answer: (String, JevClient.Question) -> Double = { _, _ in 0.9 }
    private(set) var requests: [String] = []
    nonisolated deinit {}

    func judge(request: String, questions: [JevClient.Question]) async throws -> [String: Double] {
        requests.append(request)
        if fails { throw JevClient.JevError.timeout }
        return Dictionary(questions.map { ($0.id, answer($0.id, $0)) }, uniquingKeysWith: { first, _ in first })
    }
}
