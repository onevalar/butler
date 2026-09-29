import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor
final class UnifiedCapabilitiesTests: XCTestCase {
    private func fixture() throws -> (ModelContainer, ButlerTools, URL, UserDefaults) {
        let container = try ButlerStore.makePreviewContainer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("unified-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "unified-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let tools = ButlerTools(container: container, notes: try LocalMemoryStore(file: directory.appendingPathComponent("notes.json")),
            reminders: ReminderStore(file: directory.appendingPathComponent("tasks.json"), schedules: false), jev: UnifiedNoJudge())
        tools.settingsDefaults = defaults
        tools.weather = WeatherStore(defaults: defaults)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory); UserDefaults.standard.removePersistentDomain(forName: suite) }
        return (container, tools, directory, defaults)
    }
    private func call(_ tools: ButlerTools, _ name: String, _ fields: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: fields)
        let result = await tools.execute(.init(id: UUID().uuidString, name: name, arguments: String(decoding: data, as: UTF8.self)))
        return (try JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any] ?? [:]
    }
    private func add(_ tools: ButlerTools, name: String = "外套", profile: [String: Any]? = nil) async throws {
        let result = try await call(tools, "propose_add_items", ["items": [["name": name, "quantity": 1, "unit": "件", "storage": "衣柜",
            "package_expiry": NSNull(), "planned_use_by": NSNull(), "track": "quantity", "profile": profile as Any? ?? NSNull()]]])
        XCTAssertNil(result["error"], String(describing: result))
    }
    private var clothing: [String: Any] {
        ["category": "clothing", "attributes": [["name": "颜色", "value": "米色"], ["name": "材质", "value": "棉"]],
         "tags": ["通勤", "春秋"], "availability": "ready", "photo_index": NSNull(), "remove_photo": false]
    }
    func testPendingSurvivesTurnsAndPartialConfirmationDoesNotCommitTheRest() async throws {
        let (container, tools, _, _) = try fixture()
        try await add(tools, name: "外套")
        try await add(tools, name: "鞋子")
        let original = tools.pending.map(\.id)
        tools.beginTurn(request: "确认第一项", previous: "买了两件东西")
        XCTAssertEqual(tools.pending.map(\.id), original)
        let decision = try XCTUnwrap(PendingDecision.parse("确认第一项。", pending: tools.pending))
        XCTAssertEqual(tools.confirmAll(ids: decision.ids).count, 1)
        XCTAssertEqual(tools.pending.map(\.id), [original[1]])
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<InventoryLot>()), 1)
        XCTAssertNil(PendingDecision.parse("确认，但是第二项改成蓝色", pending: tools.pending))
        XCTAssertNil(PendingDecision.parse("他说确认", pending: tools.pending))
        XCTAssertNil(PendingDecision.parse("确认第3项", pending: tools.pending))
        XCTAssertNil(PendingDecision.parse("不要确认", pending: tools.pending))
    }
    func testPendingCanBeEditedWithoutDroppingOtherChanges() async throws {
        let (_, tools, _, _) = try fixture()
        try await add(tools, name: "外套"); try await add(tools, name: "鞋子")
        let second = tools.pending[1].id
        _ = try await call(tools, "discard_pending_changes", ["ids": [tools.pending[0].id.uuidString]])
        try await add(tools, name: "蓝色外套")
        XCTAssertEqual(tools.pending.count, 2)
        XCTAssertEqual(tools.pending.first?.id, second)
    }
    func testPendingSurvivesRelaunchAndCanBeConfirmedOffline() async throws {
        let (container, tools, directory, defaults) = try fixture()
        let scope = ChatScope.inventory
        let chat = ButlerChat(container: container, reminders: tools.reminders, scope: scope,
            connection: SubscriptionConnection(keychainAccount: UUID().uuidString), directory: directory, defaults: defaults, notes: tools.notes)
        try await add(try XCTUnwrap(chat.tools), name: "外套", profile: clothing)
        let id = try XCTUnwrap(chat.tools?.pending.first?.id)
        let restored = ButlerChat(container: container, reminders: tools.reminders, scope: scope,
            connection: chat.connection, directory: directory, defaults: defaults, notes: tools.notes)
        XCTAssertEqual(restored.tools?.pending.first?.id, id)
        let general = ButlerChat(container: container, reminders: tools.reminders, directory: directory, defaults: defaults, notes: tools.notes)
        XCTAssertTrue(general.tools?.pending.isEmpty == true)
        restored.draft = "确认"
        XCTAssertTrue(restored.canSend)
        restored.send()
        XCTAssertTrue(restored.tools?.pending.isEmpty == true)
        XCTAssertEqual(restored.turns.last?.receipts.first?.hasPrefix("✓"), true)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<InventoryLot>()), 1)
    }
    func testStaleInventoryProposalCannotOverwriteAButtonEdit() async throws {
        let (container, tools, _, _) = try fixture()
        try await add(tools, name: "外套"); _ = tools.confirmAll()
        let lot = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).first)
        let before = try tools.lotFacts(lot.id)
        _ = try await call(tools, "propose_set_quantity", ["lot_id": lot.id.uuidString, "quantity": 4])
        try InventoryActions(modelContainer: container).adjustQuantity(before, to: 2)
        XCTAssertTrue(tools.confirmAll().first?.hasPrefix("✗") == true)
        XCTAssertEqual(try tools.lotFacts(lot.id).quantity, 2)
    }
    func testClothingProfileIsSearchableDurableAndBackedUpWithPhoto() async throws {
        let (container, tools, directory, defaults) = try fixture()
        tools.inputPhotos = [Data([1, 2, 3])]
        var profile = clothing; profile["photo_index"] = 0
        try await add(tools, profile: profile)
        XCTAssertTrue(tools.confirmAll().first?.hasPrefix("✓") == true)
        let response = try await call(tools, "search_inventory", ["query": "通勤", "include_finished": false])
        let items = try XCTUnwrap(response["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?["has_photo"] as? Bool, true)
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(items.first?["lot_id"] as? String)))
        let facts = try tools.lotFacts(id)
        XCTAssertEqual(facts.category, .clothing); XCTAssertFalse(facts.needsDate); XCTAssertFalse(facts.isRunningLow)
        let backup = try BackupService.makeBackup(container: container, directory: directory, defaults: defaults)
        try BackupService.restore(BackupService.decode(BackupService.encode(backup)), container: container, directory: directory, defaults: defaults)
        XCTAssertEqual(try tools.lotFacts(id).profile, facts.profile)
        XCTAssertEqual(try tools.lotFacts(id).profile?.photo, Data([1, 2, 3]))
    }
    func testItemProfileAndNativeEditUseTheSameRevisionGuard() async throws {
        let (container, tools, _, _) = try fixture()
        try await add(tools, profile: clothing); _ = tools.confirmAll()
        let lot = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).first)
        let before = try tools.lotFacts(lot.id)
        var next = clothing; next["availability"] = "laundry"
        _ = try await call(tools, "propose_item_profile", ["lot_id": lot.id.uuidString, "expected_revision": before.revision, "profile": next])
        var native = try XCTUnwrap(before.profile); native.availability = "lent"
        try InventoryActions(modelContainer: container).setProfile(native, for: before)
        XCTAssertTrue(tools.confirmAll().first?.hasPrefix("✗") == true)
        XCTAssertEqual(try tools.lotFacts(lot.id).profile?.availability, "lent")
    }
    func testUndoAndReopenKeepOriginalHistory() async throws {
        let (container, tools, _, _) = try fixture()
        try await add(tools); _ = tools.confirmAll()
        let lot = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).first)
        try InventoryActions(modelContainer: container).close(tools.lotFacts(lot.id), as: .gifted)
        let history = try await call(tools, "get_inventory_history", ["lot_id": lot.id.uuidString])
        let events = try XCTUnwrap(history["events"] as? [[String: Any]])
        let event = try XCTUnwrap(events.first { $0["undoable"] as? Bool == true })
        _ = try await call(tools, "propose_undo_inventory", ["lot_id": lot.id.uuidString, "expected_revision": history["revision"]!, "operation_id": event["operation_id"]!])
        XCTAssertTrue(tools.confirmAll().first?.hasPrefix("✓") == true)
        XCTAssertEqual(try tools.lotFacts(lot.id).state, .active)
        let reminder = TimedReminder(text: "取件", fireDate: .now.addingTimeInterval(3600))
        try tools.reminders.add(reminder); try tools.reminders.complete(reminder.id)
        let ended = try XCTUnwrap(tools.reminders.reminder(id: reminder.id))
        _ = try await call(tools, "propose_task_action", ["id": ended.id.uuidString, "action": "reopen", "expected_revision": ended.revision])
        XCTAssertTrue(tools.confirmAll().first?.hasPrefix("✓") == true)
        XCTAssertEqual(tools.reminders.reminder(id: ended.id)?.status, .active)
        XCTAssertGreaterThan(tools.reminders.reminder(id: ended.id)?.activity.count ?? 0, ended.activity.count)
    }
    func testVisualResultsOnlyReferenceExistingActiveItems() async throws {
        let (container, tools, _, _) = try fixture()
        try await add(tools); _ = tools.confirmAll()
        let lot = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).first)
        _ = try await call(tools, "show_inventory", ["title": "通勤建议", "items": [["lot_id": lot.id.uuidString, "reason": "已有外套"]]])
        XCTAssertEqual(tools.displayedCollection?.items.first?.id, lot.id)
        let invalid = try await call(tools, "show_inventory", ["title": "捏造", "items": [["lot_id": UUID().uuidString, "reason": "不存在"]]])
        XCTAssertNotNil(invalid["error"])
        XCTAssertEqual(tools.displayedCollection?.title, "通勤建议")
    }
    func testNewToolSchemasAreStrictAndExposeNoCommitTool() throws {
        let (_, tools, _, _) = try fixture()
        let schemas = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tools.toolJSON.utf8)) as? [[String: Any]])
        XCTAssertFalse(schemas.contains { ($0["name"] as? String ?? "").hasPrefix("confirm") })
        func inspect(_ value: Any) {
            if let object = value as? [String: Any] {
                if object["type"] as? String == "object" {
                    XCTAssertEqual(object["additionalProperties"] as? Bool, false)
                    XCTAssertEqual(Set(object["required"] as? [String] ?? []), Set((object["properties"] as? [String: Any] ?? [:]).keys))
                }
                object.values.forEach(inspect)
            } else if let array = value as? [Any] { array.forEach(inspect) }
        }
        schemas.forEach(inspect)
    }
}

@MainActor private final class UnifiedNoJudge: ConditionJudge {
    let isConfigured = false
    nonisolated deinit {}
    func judge(request: String, questions: [JevClient.Question]) async throws -> [String: Double] { [:] }
}
