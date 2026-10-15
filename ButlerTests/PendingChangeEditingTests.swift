import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor
final class PendingChangeEditingTests: XCTestCase {
    private func fixture(judge: PendingEditingJudge? = nil) throws -> ButlerTools {
        let configuration = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ButlerStore.schema, configurations: [configuration])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PendingEdit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ButlerTools(container: container,
            notes: try LocalMemoryStore(file: directory.appendingPathComponent("notes.json")),
            reminders: ReminderStore(file: directory.appendingPathComponent("tasks.json"), schedules: false),
            jev: judge ?? PendingEditingJudge(), household: HouseholdStore(directory: directory.appendingPathComponent("household")))
    }

    private func call(_ tools: ButlerTools, _ fields: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let output = await tools.execute(.init(id: UUID().uuidString, name: "revise_pending_change",
                                               arguments: String(decoding: data, as: UTF8.self)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

    private func fields(_ change: PendingChange, task: [String: Any]? = nil, item: [String: Any]? = nil) throws -> [String: Any] {
        ["proposal_id": change.id.uuidString, "expected_fingerprint": try change.editFingerprint,
         "task_patch": task as Any? ?? NSNull(), "item_patch": item as Any? ?? NSNull()]
    }

    private func item(name: String = "水") -> InventoryActions.NewItem {
        InventoryActions.NewItem(name: name, quantity: 4, unit: "瓶", storage: "厨房", packageExpiry: nil,
                                 plannedUseBy: nil, quantityOnly: true,
                                 profile: ItemProfile(category: .household, attributes: ["规格": "550mL"], photo: Data([1, 2, 3])))
    }

    func testVagueCorrectionPreservesProposalTaskFamilyAndOriginWithoutSaving() async throws {
        let tools = try fixture()
        var task = TimedReminder(text: "给宝宝买水", fireDate: .distantFuture, status: .paused, revision: 8,
                                 activity: [.init(kind: "paused", detail: "用户暂停")])
        task.timePeriod = .morning
        task.sharing = TaskSharing(scope: .people, people: [UUID()], createdBy: UUID(), assignee: UUID(), notify: [UUID()])
        let origin = UUID()
        let original = PendingChange(kind: .taskPlan(task, expectedRevision: 8), title: task.text, detail: task.whenLabel,
                                     requestTurnID: origin)
        let other = PendingChange(kind: .add(item()), title: "水", detail: nil)
        tools.restorePending([other, original])
        tools.beginTurn(request: "改成后天下午", previous: nil, turnID: UUID())
        var changes = 0
        tools.pendingDidChange = { _ in changes += 1 }
        let result = try await call(tools, fields(original, task: [
            "text": NSNull(), "family": NSNull(),
            "schedule": ["time": "2099-01-02", "period": "afternoon", "time_zone": "Asia/Shanghai"]
        ]))
        XCTAssertNil(result["error"], String(describing: result))
        XCTAssertEqual(result["saved"] as? Bool, false)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(tools.pending.map(\.id), [other.id, original.id])
        XCTAssertEqual(try tools.pending[0].editFingerprint, try other.editFingerprint)
        XCTAssertEqual(tools.pending[1].requestTurnID, origin)
        guard case .taskPlan(let edited, let expected) = tools.pending[1].kind else { return XCTFail() }
        XCTAssertEqual(edited.id, task.id)
        XCTAssertEqual(edited.text, task.text)
        XCTAssertEqual(edited.timePeriod, .afternoon)
        XCTAssertEqual(edited.sharing, task.sharing)
        XCTAssertEqual(edited.status, .paused)
        XCTAssertEqual(edited.activity, task.activity)
        XCTAssertEqual(expected, 8)
        XCTAssertTrue(tools.reminders.reminders.isEmpty)
        XCTAssertNotEqual(try tools.pending[1].editFingerprint, try original.editFingerprint)
    }

    func testComplexScheduleAllowsTextCorrectionButRejectsPartialTimeReplacementAtomically() async throws {
        let tools = try fixture()
        let phase = ReminderPhase(startDate: .distantFuture, repeats: .daily)
        let task = TimedReminder(text: "旧文字", fireDate: .distantFuture, phases: [phase])
        let original = PendingChange(kind: .reminder(task), title: task.text, detail: nil)
        tools.restorePending([original])
        let changed = try await call(tools, fields(original, task: ["text": "新文字"]))
        XCTAssertNil(changed["error"])
        guard case .reminder(let edited) = tools.pending[0].kind else { return XCTFail() }
        XCTAssertEqual(edited.phases, [phase])
        let before = try tools.pending[0].editFingerprint
        let rejected = try await call(tools, fields(tools.pending[0], task: [
            "text": "不应部分保留", "schedule": ["time": "2099-01-01", "period": "day"]
        ]))
        XCTAssertNotNil(rejected["error"])
        XCTAssertEqual(try tools.pending[0].editFingerprint, before)
    }

    func testCardChangeMakesOldFingerprintStaleAndPersistedSetOrderingDoesNot() async throws {
        let tools = try fixture()
        var task = TimedReminder(text: "买水", fireDate: .distantFuture)
        task.timePeriod = .day
        let ids = (0..<12).map { _ in UUID() }
        task.sharing = TaskSharing(scope: .people, people: Set(ids), createdBy: UUID(), notify: Set(ids.reversed()))
        let original = PendingChange(kind: .reminder(task), title: task.text, detail: nil)
        let reloaded = try JSONDecoder().decode(PendingChange.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(try original.editFingerprint, try reloaded.editFingerprint)
        tools.restorePending([original])
        let oldFields = try fields(original, task: ["text": "买茶"])
        try tools.reviseReminderTime(of: original.id, date: .distantFuture, period: .afternoon)
        let afterCardEdit = try tools.pending[0].editFingerprint
        let result = try await call(tools, oldFields)
        XCTAssertNotNil(result["error"])
        XCTAssertEqual(try tools.pending[0].editFingerprint, afterCardEdit)
    }

    func testInventoryCorrectionPreservesProfileAndDatesAndRelinksOnlyWhenNameChanges() async throws {
        let tools = try fixture()
        let context = ModelContext(tools.container)
        let target = CatalogProduct(canonicalName: "茶")
        context.insert(target)
        try context.save()
        var value = item()
        value.packageExpiry = .distantFuture
        value.plannedUseBy = .distantFuture.addingTimeInterval(-86400)
        value.existingProductID = UUID()
        let original = PendingChange(kind: .add(value), title: "水", detail: "原卡片")
        tools.restorePending([original])
        let result = try await call(tools, fields(original, item: ["quantity": 5, "storage": ["value": "玄关"]]))
        XCTAssertNil(result["error"])
        guard case .add(let first) = tools.pending[0].kind else { return XCTFail() }
        XCTAssertEqual(first.quantity, 5)
        XCTAssertEqual(first.storage, "玄关")
        XCTAssertEqual(first.existingProductID, value.existingProductID)
        XCTAssertEqual(first.profile, value.profile)
        XCTAssertEqual(first.packageExpiry, value.packageExpiry)
        XCTAssertEqual(first.plannedUseBy, value.plannedUseBy)
        let renamed = try await call(tools, fields(tools.pending[0], item: ["name": "茶", "storage": ["value": NSNull()]]))
        XCTAssertNil(renamed["error"])
        guard case .add(let last) = tools.pending[0].kind else { return XCTFail() }
        XCTAssertEqual(last.existingProductID, target.id)
        XCTAssertEqual(last.quantity, 5)
        XCTAssertEqual(last.profile, value.profile)
        XCTAssertNil(last.storage)
        XCTAssertEqual(tools.pending[0].id, original.id)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryLot>()), 0)
    }

    func testInvalidMixedUnknownAndNoOpPatchesKeepEverythingUnchanged() async throws {
        let tools = try fixture()
        let original = PendingChange(kind: .add(item()), title: "水", detail: nil)
        tools.restorePending([original])
        let before = try original.editFingerprint
        var malformed: [[String: Any]] = [
            try fields(original, item: ["name": "茶", "quantity": 0]),
            try fields(original, item: ["quantity": 4]),
            try fields(original, item: ["quanity": 5]),
            try fields(original, item: ["storage": ["value": "玄关", "extra": true]]),
            try fields(original, task: ["text": "不对"], item: ["quantity": 5]),
            try fields(original, task: ["text": "不对"]),
            try fields(original)
        ]
        var extra = try fields(original, item: ["quantity": 5]); extra["confirm"] = true
        malformed.append(extra)
        for input in malformed {
            let result = try await call(tools, input)
            XCTAssertNotNil(result["error"], String(describing: input))
            XCTAssertEqual(try tools.pending[0].editFingerprint, before)
        }
    }

    func testInventoryRevisionRunsJudgeAndPreservesConcernUntilExplicitReviewPasses() async throws {
        let judge = PendingEditingJudge()
        judge.isConfigured = true
        judge.probability = 0.05
        let tools = try fixture(judge: judge)
        let context = ModelContext(tools.container)
        let product = CatalogProduct(canonicalName: "水")
        context.insert(product)
        context.insert(InventoryLot(productID: product.id, quantity: 6, unit: "瓶"))
        try context.save()
        let original = PendingChange(kind: .add(item()), title: "水", detail: nil, check: .concern("原有疑问"))
        tools.restorePending([original])
        tools.beginTurn(request: "改为五瓶", previous: "新增水")
        let input = try fields(original, item: ["quantity": 5])
        let review = try await call(tools, input)
        XCTAssertEqual(review["status"] as? String, "needs_review")
        XCTAssertEqual(try tools.pending[0].editFingerprint, try original.editFingerprint)
        XCTAssertEqual(judge.requests, 1)
        let insisted = try await call(tools, input)
        XCTAssertNil(insisted["error"])
        guard case .concern = tools.pending[0].check else { return XCTFail("Concern must remain visible") }
        judge.isEnabled = false
        let count = judge.requests
        let disabled = try await call(tools, fields(tools.pending[0], item: ["storage": ["value": "储物柜"]]))
        XCTAssertNil(disabled["error"])
        XCTAssertEqual(judge.requests, count)
        guard case .concern = tools.pending[0].check else { return XCTFail("Disabling judge must not erase concern") }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryLot>()), 1)
    }

    func testProposalRemovedDuringJudgeIsNotResurrected() async throws {
        let judge = PendingEditingJudge()
        judge.isConfigured = true
        let tools = try fixture(judge: judge)
        var value = item(); value.packageExpiry = .distantFuture
        let original = PendingChange(kind: .add(value), title: "水", detail: nil)
        tools.restorePending([original])
        tools.beginTurn(request: "改五瓶", previous: nil)
        judge.beforeReturn = { tools.removePending(original.id) }
        let result = try await call(tools, fields(original, item: ["quantity": 5]))
        judge.beforeReturn = nil
        XCTAssertNotNil(result["error"])
        XCTAssertTrue(tools.pending.isEmpty)
    }

    func testExistingQuantityCorrectionKeepsLotAndCanChangeBetweenRemainingAndUsedUp() async throws {
        let tools = try fixture()
        let context = ModelContext(tools.container)
        let product = CatalogProduct(canonicalName: "牛奶")
        let lot = InventoryLot(productID: product.id, quantity: 6, unit: "瓶")
        context.insert(product); context.insert(lot)
        try context.save()
        let facts = try tools.lotFacts(lot.id)
        let original = PendingChange(kind: .setQuantity(facts, 2), title: "牛奶剩2瓶", detail: nil)
        tools.restorePending([original])
        let edited = try await call(tools, fields(original, item: ["quantity": 5]))
        XCTAssertNil(edited["error"])
        guard case .setQuantity(let preserved, let quantity) = tools.pending[0].kind else { return XCTFail() }
        XCTAssertEqual(preserved.id, lot.id)
        XCTAssertEqual(preserved.revision, facts.revision)
        XCTAssertEqual(quantity, 5)
        XCTAssertEqual(try tools.lotFacts(lot.id).quantity, 6)
        let usedUp = try await call(tools, fields(tools.pending[0], item: ["quantity": 0]))
        XCTAssertNil(usedUp["error"])
        guard case .close(let closed, .depleted) = tools.pending[0].kind else { return XCTFail() }
        XCTAssertEqual(closed.id, lot.id)
        let restored = try await call(tools, fields(tools.pending[0], item: ["quantity": 1]))
        XCTAssertNil(restored["error"])
        XCTAssertEqual(tools.pending[0].id, original.id)
        XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✓"), true)
        XCTAssertEqual(try tools.lotFacts(lot.id).quantity, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryLot>()), 1)
    }

    func testExistingQuantityPatchRejectsExtraFieldsAndStaleInventoryWithoutOverwriting() async throws {
        let judge = PendingEditingJudge()
        judge.isConfigured = true
        let tools = try fixture(judge: judge)
        let context = ModelContext(tools.container)
        let product = CatalogProduct(canonicalName: "牛奶")
        let lot = InventoryLot(productID: product.id, quantity: 6, unit: "瓶")
        context.insert(product); context.insert(lot)
        try context.save()
        let facts = try tools.lotFacts(lot.id)
        let original = PendingChange(kind: .setQuantity(facts, 2), title: "牛奶剩2瓶", detail: nil)
        tools.restorePending([original])
        let rejected = try await call(tools, fields(original, item: ["quantity": 5, "name": "另一种牛奶"]))
        XCTAssertNotNil(rejected["error"])
        XCTAssertEqual(try tools.pending[0].editFingerprint, try original.editFingerprint)
        tools.beginTurn(request: "应该剩五瓶", previous: nil)
        judge.beforeReturn = { try? InventoryActions(modelContainer: tools.container).adjustQuantity(facts, to: 4) }
        let stale = try await call(tools, fields(original, item: ["quantity": 5]))
        judge.beforeReturn = nil
        XCTAssertNotNil(stale["error"])
        XCTAssertEqual(try tools.pending[0].editFingerprint, try original.editFingerprint)
        XCTAssertEqual(try tools.lotFacts(lot.id).quantity, 4)
        let count = judge.requests
        let alreadyStale = try await call(tools, fields(original, item: ["quantity": 3]))
        XCTAssertNotNil(alreadyStale["error"])
        XCTAssertEqual(judge.requests, count, "An already stale proposal should be rejected before remote judgment")
    }

    func testSchemasAreStrictAndSnapshotExposesOnlySupportedEditsWithoutPhotos() throws {
        let schemas = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(("[" + ButlerTools.pendingTools + "]").utf8)) as? [[String: Any]])
        func inspect(_ value: Any) {
            if let object = value as? [String: Any] {
                if object["type"] as? String == "object" {
                    let properties = object["properties"] as? [String: Any] ?? [:]
                    XCTAssertEqual(object["additionalProperties"] as? Bool, false)
                    XCTAssertEqual(Set(object["required"] as? [String] ?? []), Set(properties.keys))
                }
                object.values.forEach(inspect)
            } else if let array = value as? [Any] { array.forEach(inspect) }
        }
        for schema in schemas { XCTAssertEqual(schema["strict"] as? Bool, true); inspect(schema) }
        let tools = try fixture()
        let original = PendingChange(kind: .add(item()), title: "水", detail: nil)
        tools.restorePending([original])
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tools.pendingContext.utf8)) as? [String: Any])
        let change = try XCTUnwrap((output["changes"] as? [[String: Any]])?.first)
        XCTAssertEqual(change["fingerprint"] as? String, try original.editFingerprint)
        XCTAssertEqual(change["editable_fields"] as? [String], ["name", "quantity", "unit", "storage"])
        XCTAssertFalse(tools.pendingContext.contains(Data([1, 2, 3]).base64EncodedString()))
        XCTAssertFalse(tools.pendingContext.contains("profile"))
    }
}

@MainActor
private final class PendingEditingJudge: ConditionJudge {
    var isConfigured = false
    var isEnabled = true
    var probability = 0.9
    var requests = 0
    var beforeReturn: (() -> Void)?
    nonisolated deinit {}
    func judge(request: String, questions: [JevClient.Question]) async throws -> [String: Double] {
        requests += 1
        beforeReturn?()
        return Dictionary(uniqueKeysWithValues: questions.map { ($0.id, probability) })
    }
}
