import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor
final class ItemsPageTests: XCTestCase {
    private let calendar = Calendar.current
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// Household things and durable things (clothes, tools) only count how many are left.
    private func lot(_ name: String, quantity: Int = 2, days: Int? = nil, category: ItemCategory? = nil, place: String? = nil) -> LotFacts {
        let product = CatalogProduct(canonicalName: name, categoryRawValue: category?.rawValue)
        let lot = InventoryLot(productID: product.id, quantity: quantity, unit: "个")
        lot.packageExpiryDate = days.map { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: now))! }
        lot.storageLocation = place
        if let category { lot.profileData = try? JSONEncoder().encode(ItemProfile(category: category)) }
        return LotFacts(lot: lot, product: product, now: now, calendar: calendar)
    }

    private var home: [LotFacts] {
        [lot("土鸡蛋", days: -4, category: .food, place: "冷藏"),
         lot("红枣酸奶", days: 2, category: .food, place: "冷藏"),
         lot("速冻水饺", days: 90, category: .food, place: "冷冻"),
         lot("七鲜饮用纯净水", quantity: 1, category: .household, place: "卫生间"),
         lot("十字螺丝刀", quantity: 1, category: .tools, place: "客厅柜"),
         lot("内六角扳手", quantity: 1, category: .tools, place: "客厅柜"),
         lot("米色外套", quantity: 1, category: .clothing, place: "衣柜")]
    }

    // MARK: Tiles

    func testCategoryTilesCountBadgeAndPreviewMostPressingFirst() throws {
        let groups = InventoryGroups.make(home, lens: .category)
        XCTAssertEqual(groups.map(\.title), ["食品", "日用品", "衣物", "工具"])
        let food = try XCTUnwrap(groups.first)
        XCTAssertEqual(food.lots.count, 3)
        XCTAssertEqual(food.urgent, 2, "expired eggs and yoghurt due in 2 days")
        XCTAssertTrue(food.pressing, "something is already past its date: red badge")
        XCTAssertEqual(food.preview, "土鸡蛋 · 红枣酸奶 · 速冻水饺")
        let household = try XCTUnwrap(groups.first { $0.title == "日用品" })
        XCTAssertEqual(household.urgent, 1, "one bottle of water left")
        let tools = try XCTUnwrap(groups.first { $0.title == "工具" })
        XCTAssertEqual(tools.urgent, 0, "tools never run low")
    }

    func testPlaceAndExpiryTilesCoverEveryThingOnce() {
        for lens in InventoryLens.allCases {
            let groups = InventoryGroups.make(home, lens: lens)
            XCTAssertEqual(groups.flatMap(\.lots).count, home.count, "\(lens)")
            XCTAssertEqual(Set(groups.flatMap(\.lots).map(\.id)).count, home.count, "\(lens)")
        }
        let places = InventoryGroups.make(home, lens: .place)
        XCTAssertEqual(places.prefix(2).map(\.title), ["冷藏", "冷冻"], "fridge first, like everywhere else")
        XCTAssertEqual(places.first?.symbol, "refrigerator")
        let expiry = InventoryGroups.make(home, lens: .expiry).map(\.title)
        XCTAssertEqual(expiry, ["已过期", "这周到期", "以后", "只记数量"])
    }

    func testAnOpenedTileIsRebuiltFromCurrentFacts() {
        let key = InventoryGroup.Key.place("冷藏")
        XCTAssertEqual(InventoryGroups.group(key, facts: home)?.lots.count, 2)
        XCTAssertNil(InventoryGroups.group(key, facts: home.filter { $0.storageLocation != "冷藏" }), "emptied since")
    }

    // MARK: Answers on the phone

    func testPlainQuestionsAreAnsweredOnThePhone() throws {
        let clothes = try XCTUnwrap(LocalInventoryQuery.answer("我想看我有什么衣服", facts: home))
        XCTAssertEqual(clothes.lots.map(\.name), ["米色外套"])
        XCTAssertEqual(clothes.text, "家里有 1 样衣物：")
        let fridge = try XCTUnwrap(LocalInventoryQuery.answer("冷藏里有什么？", facts: home))
        XCTAssertEqual(fridge.lots.map(\.name), ["土鸡蛋", "红枣酸奶"])
        let wholeFridge = try XCTUnwrap(LocalInventoryQuery.answer("冰箱里有什么", facts: home))
        XCTAssertEqual(wholeFridge.lots.count, 3)
        let driver = try XCTUnwrap(LocalInventoryQuery.answer("螺丝刀放哪了", facts: home))
        XCTAssertEqual(driver.lots.map(\.name), ["十字螺丝刀"])
        let soon = try XCTUnwrap(LocalInventoryQuery.answer("什么快过期了", facts: home))
        XCTAssertEqual(soon.lots.map(\.name), ["土鸡蛋", "红枣酸奶"])
        let none = try XCTUnwrap(LocalInventoryQuery.answer("家里有什么药", facts: home))
        XCTAssertTrue(none.lots.isEmpty)
        XCTAssertNil(LocalInventoryQuery.collection(none), "nothing to list: just the sentence")
    }

    func testAnythingNeedingJudgementGoesToTheModel() {
        XCTAssertNil(LocalInventoryQuery.answer("今天要修自行车，需要螺丝钉或螺丝刀，看一下我有没有", facts: home))
        XCTAssertNil(LocalInventoryQuery.answer("今天出门野餐要带什么", facts: home))
        XCTAssertNil(LocalInventoryQuery.answer("家里有什么", facts: home), "too vague to list on its own")
        XCTAssertNil(LocalInventoryQuery.answer("有没有胶水", facts: home), "nothing by that name: the model may know a stand-in")
        XCTAssertNil(LocalInventoryQuery.answer("买了两盒草莓", facts: home))
        XCTAssertNil(LocalInventoryQuery.answer("把酸奶放到冷冻", facts: home))
    }

    func testQualifiersAreNotDiscardedByReverseNameOrLocationMatching() {
        let milk = lot("牛奶", category: .food, place: "冰箱")
        XCTAssertNotNil(LocalInventoryQuery.answer("有没有牛奶", facts: [milk]))
        XCTAssertNil(LocalInventoryQuery.answer("有没有不含糖的牛奶", facts: [milk]))
        XCTAssertNil(LocalInventoryQuery.answer("有没有不在冰箱里的牛奶", facts: [milk]))
        XCTAssertNil(LocalInventoryQuery.answer("有没有儿童牛奶", facts: [milk]))
    }

    func testRemovingALineNeedsItToBeClearlyOnTheList() throws {
        let list = ItemCollection(title: "修自行车用得上", items: home.filter { $0.category == .tools }.map { .init(id: $0.id, name: $0.name, reason: "") }
                                  + [.init(id: UUID(), name: "自攻螺丝", reason: "")])
        XCTAssertEqual(ShownListEdit.removals("去掉自攻螺丝", from: list)?.map(\.name), ["自攻螺丝"])
        XCTAssertEqual(ShownListEdit.removals("把螺丝刀和扳手去掉", from: list), nil, "not a removal sentence the phone understands")
        XCTAssertEqual(ShownListEdit.removals("不要螺丝刀和扳手了", from: list)?.map(\.name), ["十字螺丝刀", "内六角扳手"])
        XCTAssertNil(ShownListEdit.removals("去掉螺丝", from: list), "matches two lines: ask the model")
        XCTAssertNil(ShownListEdit.removals("去掉牛奶", from: list), "not on the list")
    }

    // MARK: The conversation

    private func chat(directory: URL? = nil) throws -> (ButlerChat, ModelContainer) {
        let container = try ButlerStore.makePreviewContainer()
        let directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("items-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "items-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let chat = ButlerChat(container: container, reminders: ReminderStore(file: directory.appendingPathComponent("tasks.json"), schedules: false),
                              scope: .inventory, directory: directory, defaults: defaults,
                              notes: try LocalMemoryStore(file: directory.appendingPathComponent("notes.json")))
        return (chat, container)
    }

    private func stock(_ container: ModelContainer, _ items: [(String, ItemCategory, String)]) throws -> [UUID] {
        let context = ModelContext(container)
        var ids: [UUID] = []
        for (name, category, place) in items {
            let product = CatalogProduct(canonicalName: name, categoryRawValue: category.rawValue)
            let lot = InventoryLot(productID: product.id, quantity: 1, unit: "个")
            lot.storageLocation = place
            lot.profileData = try? JSONEncoder().encode(ItemProfile(category: category))
            context.insert(product); context.insert(lot)
            ids.append(lot.id)
        }
        try context.save()
        return ids
    }

    func testAPlainQuestionIsAnsweredWithAListAtOnceEvenSignedOut() throws {
        let (chat, container) = try chat()
        _ = try stock(container, [("米色外套", .clothing, "衣柜"), ("牛仔裤", .clothing, "衣柜"), ("螺丝刀", .tools, "客厅柜")])
        XCTAssertFalse(chat.connection.isLoggedIn)
        chat.draft = "我有什么衣服"
        XCTAssertTrue(chat.canSend)
        chat.send()
        XCTAssertFalse(chat.working, "answered on the phone, no model call")
        XCTAssertEqual(chat.turns.last?.answer, "家里有 2 样衣物：")
        XCTAssertEqual(Set(chat.turns.last?.collection?.items.map(\.name) ?? []), ["米色外套", "牛仔裤"])
        XCTAssertTrue(chat.scopeContext.contains("shown_list"), "the model sees what is showing")
    }

    func testSayingRemoveTakesTheLineOffTheShownListOnly() throws {
        let (chat, container) = try chat()
        let ids = try stock(container, [("米色外套", .clothing, "衣柜"), ("牛仔裤", .clothing, "衣柜")])
        chat.draft = "有什么衣服"
        chat.send()
        chat.draft = "去掉牛仔裤"
        chat.send()
        XCTAssertEqual(chat.turns.count, 2)
        XCTAssertEqual(chat.turns[0].collection?.items.map(\.name), ["米色外套"], "the same card, one line fewer")
        XCTAssertTrue(chat.turns[1].answer.contains("东西还在家里"))
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<InventoryLot>()), 2, "nothing deleted")
        chat.removeFromCollection(try XCTUnwrap(chat.turns[0].collection?.id), lot: ids[0])
        XCTAssertEqual(chat.turns[0].collection?.items.count, 0)
    }

    func testManualRemovalWaitsForSaveAndNeverChangesStock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("items-\(UUID())")
        let (chat, container) = try chat(directory: directory)
        let ids = try stock(container, [("外套", .clothing, "衣柜"), ("衬衫", .clothing, "衣柜")])
        chat.draft = "有什么衣服"
        chat.send()
        let before = chat.turns
        let card = try XCTUnwrap(chat.latestCollection)
        let files = ChatSessionFiles(scope: .inventory, root: directory)
        let backup = files.directory.appendingPathComponent("original.json")
        try FileManager.default.moveItem(at: files.transcript, to: backup)
        try FileManager.default.createDirectory(at: files.transcript, withIntermediateDirectories: false)
        chat.removeFromCollection(card.id, lot: ids[0])
        XCTAssertEqual(chat.turns, before)
        XCTAssertTrue(chat.error?.contains("仍保留原清单") == true)
        try FileManager.default.removeItem(at: files.transcript)
        try FileManager.default.moveItem(at: backup, to: files.transcript)
        chat.removeFromCollection(card.id, lot: ids[0])
        XCTAssertEqual(chat.latestCollection?.items.map(\.id), [ids[1]])
        XCTAssertEqual(try JSONDecoder().decode([ChatTurn].self, from: Data(contentsOf: files.transcript)), chat.turns)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).map(\.quantity), [1, 1])
        XCTAssertTrue(chat.tools?.pending.isEmpty == true)
    }

    // MARK: Tools

    private func call(_ tools: ButlerTools, _ name: String, _ fields: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: fields)
        let result = await tools.execute(.init(id: UUID().uuidString, name: name, arguments: String(decoding: data, as: UTF8.self)))
        return (try JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any] ?? [:]
    }

    func testTheModelCanEditTheShownListInPlace() async throws {
        let (chat, container) = try chat()
        let ids = try stock(container, [("螺丝刀", .tools, "客厅柜"), ("扳手", .tools, "客厅柜"), ("润滑油", .household, "阳台")])
        let tools = try XCTUnwrap(chat.tools)
        chat.draft = "有什么工具"
        chat.send()
        tools.beginTurn(request: "不用扳手了，加上润滑油", previous: nil)
        let result = try await call(tools, "update_shown_list", ["remove": [ids[1].uuidString], "add": [["lot_id": ids[2].uuidString, "reason": "给链条上油"]]])
        XCTAssertEqual(result["count"] as? Int, 2)
        XCTAssertEqual(tools.shownListEdit?.items.map(\.name), ["螺丝刀", "润滑油"])
        XCTAssertEqual(tools.shownListEdit?.id, chat.latestCollection?.id, "edits the card that is showing, not a new one")
        let stranger = try await call(tools, "update_shown_list", ["remove": [UUID().uuidString], "add": [] as [Any]])
        XCTAssertNotNil(stranger["error"])
    }

    func testInvalidSelectionAndInvalidEditNeverExposePartialCardsOrReferences() async throws {
        let (chat, container) = try chat()
        let ids = try stock(container, [("扳手", .tools, "柜子"), ("润滑油", .household, "阳台")])
        let tools = try XCTUnwrap(chat.tools)
        tools.beginTurn(request: "修车要带什么", previous: nil)
        let invalid = try await call(tools, "show_inventory", ["title": "工具", "items": [
            ["lot_id": ids[0].uuidString, "reason": "拆卸"], ["lot_id": UUID().uuidString, "reason": "不存在"]]])
        XCTAssertNotNil(invalid["error"])
        XCTAssertNil(tools.displayedCollection)
        XCTAssertTrue(tools.relatedScopes.isEmpty)
        _ = try await call(tools, "show_inventory", ["title": "工具", "items": [["lot_id": ids[0].uuidString, "reason": "拆卸"]]])
        let before = tools.displayedCollection
        let references = tools.relatedScopes
        let rejected = try await call(tools, "update_shown_list", ["remove": [ids[0].uuidString], "add": [
            ["lot_id": ids[1].uuidString, "reason": "润滑"], ["lot_id": UUID().uuidString, "reason": "不存在"]]])
        XCTAssertNotNil(rejected["error"])
        XCTAssertEqual(tools.displayedCollection, before)
        XCTAssertNil(tools.shownListEdit)
        XCTAssertEqual(tools.relatedScopes, references)
        XCTAssertTrue(tools.pending.isEmpty)
    }

    func testRepeatedShowAndEditAlwaysTargetCurrentCardAndKeepItsIdentity() async throws {
        let (chat, container) = try chat()
        let ids = try stock(container, [("扳手", .tools, "柜子"), ("螺丝刀", .tools, "柜子"), ("润滑油", .household, "阳台")])
        chat.draft = "有什么工具"
        chat.send()
        let old = try XCTUnwrap(chat.latestCollection)
        let tools = try XCTUnwrap(chat.tools)
        tools.beginTurn(request: "先改旧清单再重新整理", previous: nil)
        _ = try await call(tools, "update_shown_list", ["remove": [ids[0].uuidString], "add": [] as [Any]])
        let oldEdit = try XCTUnwrap(tools.shownListEdit)
        XCTAssertEqual(oldEdit.id, old.id)
        XCTAssertEqual(oldEdit.items.map(\.id), [ids[1]])
        _ = try await call(tools, "show_inventory", ["title": "出门带这些", "items": [
            ["lot_id": ids[0].uuidString, "reason": "拆卸"], ["lot_id": ids[2].uuidString, "reason": "润滑"]]])
        let current = try XCTUnwrap(tools.displayedCollection)
        XCTAssertNotEqual(current.id, old.id)
        let result = try await call(tools, "update_shown_list", ["remove": [ids[0].uuidString], "add": [] as [Any]])
        XCTAssertNil(result["error"], "must edit the new card, not the old edit missing this item")
        XCTAssertEqual(tools.displayedCollection?.items.map(\.id), [ids[2]])
        XCTAssertEqual(tools.displayedCollection?.id, current.id)
        _ = try await call(tools, "show_inventory", ["title": "重新整理", "items": [["lot_id": ids[1].uuidString, "reason": "备用"]]])
        XCTAssertEqual(tools.displayedCollection?.id, current.id)
        XCTAssertEqual(tools.displayedCollection?.items.map(\.id), [ids[1]])
        XCTAssertEqual(tools.shownListEdit, oldEdit)
        XCTAssertTrue(tools.pending.isEmpty)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).map(\.quantity), [1, 1, 1])
    }

    func testRegroupProposesOneConfirmableChangePerThing() async throws {
        let (chat, container) = try chat()
        let ids = try stock(container, [("红枣酸奶", .food, "冷藏"), ("七鲜饮用纯净水", .household, "卫生间")])
        let tools = try XCTUnwrap(chat.tools)
        tools.beginTurn(request: "把酸奶和饮用水放到卫生间架子", previous: nil)
        _ = try await call(tools, "propose_regroup", ["lot_ids": ids.map(\.uuidString), "location": "卫生间架子", "category": NSNull()])
        XCTAssertEqual(tools.pending.map(\.title), ["红枣酸奶 放到 卫生间架子", "七鲜饮用纯净水 放到 卫生间架子"])
        XCTAssertEqual(tools.pending.map(\.detail), ["原来在 冷藏", "原来在 卫生间"])
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).filter { $0.storageLocation == "卫生间架子" }.count, 0,
                       "nothing moves before confirming")
        _ = tools.confirmAll()
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).filter { $0.storageLocation == "卫生间架子" }.count, 2)

        tools.beginTurn(request: "饮用水归到食品", previous: nil)
        _ = try await call(tools, "propose_regroup", ["lot_ids": [ids[1].uuidString], "location": NSNull(), "category": "food"])
        XCTAssertEqual(tools.pending.first?.title, "七鲜饮用纯净水 归到 食品")
        _ = tools.confirmAll()
        XCTAssertEqual(try tools.lotFacts(ids[1]).category, .food)
        let nothing = try await call(tools, "propose_regroup", ["lot_ids": [ids[1].uuidString], "location": NSNull(), "category": "food"])
        XCTAssertNotNil(nothing["error"], "already there")
    }
}
