import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor
final class ContextToolsTests: XCTestCase {
    private func makeTools(initialReminders: [TimedReminder] = []) throws -> ButlerTools {
        let configuration = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ButlerStore.schema, configurations: [configuration])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ContextToolsTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(initialReminders).write(to: directory.appendingPathComponent("tasks.json"))
        let suite = "ContextToolsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let tools = ButlerTools(container: container, notes: try LocalMemoryStore(file: directory.appendingPathComponent("notes.json")),
                                reminders: ReminderStore(file: directory.appendingPathComponent("tasks.json"), schedules: false),
                                jev: ContextToolsNoJudge())
        tools.settingsDefaults = defaults
        return tools
    }

    private func call(_ tools: ButlerTools, _ name: String, _ fields: [String: Any] = [:]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: fields)
        let output = await tools.execute(LocalToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: data, as: UTF8.self)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

    private func plan(id: UUID? = nil, revision: Int? = nil, start: String = "2099-01-01 18:00") -> [String: Any] {
        ["id": id?.uuidString as Any? ?? NSNull(), "expected_revision": revision as Any? ?? NSNull(),
         "text": "寄件", "time_zone": "Asia/Shanghai", "end_time": NSNull(), "auto_complete_at": NSNull(),
         "phases": [["start": start, "end": NSNull(), "repeat": "none", "interval_minutes": 10, "max_occurrences": 6]]]
    }

    private func action(_ reminder: TimedReminder, _ action: String) -> [String: Any] {
        ["id": reminder.id.uuidString, "expected_revision": reminder.revision, "action": action]
    }

    func testAllNewToolSchemasAreStrictIncludingNestedObjects() throws {
        let schemas = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(("[" + ButlerTools.contextTools + "]").utf8)) as? [[String: Any]])
        XCTAssertEqual(Set(schemas.compactMap { $0["name"] as? String }),
                       Set(["get_current_context", "get_settings", "propose_settings", "get_tasks", "propose_task_plan", "propose_task_action"]))
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
        for schema in schemas {
            XCTAssertEqual(schema["strict"] as? Bool, true)
            inspect(schema)
        }
    }

    func testContextReadUsesCurrentProviderEachTime() async throws {
        let tools = try makeTools()
        var quantity = 2
        tools.currentContext = { "{\"quantity\":\(quantity)}" }
        let first = try await call(tools, "get_current_context")
        XCTAssertEqual(first["quantity"] as? Int, 2)
        quantity = 3
        let next = try await call(tools, "get_current_context")
        XCTAssertEqual(next["quantity"] as? Int, 3)
        XCTAssertTrue(tools.pending.isEmpty)
    }

    func testSettingsRemainUnchangedUntilConfirmedAndTrackRelatedScope() async throws {
        let tools = try makeTools()
        tools.settingsDefaults.set("test-secret", forKey: "jevAPIKey")
        let snapshot = try await call(tools, "get_settings")
        XCTAssertFalse(String(describing: snapshot).contains("test-secret"))
        let proposal = try await call(tools, "propose_settings", ["changes": [["key": "appearanceMode", "value": "dark"]]])
        XCTAssertEqual(proposal["saved"] as? Bool, false)
        XCTAssertNil(tools.settingsDefaults.object(forKey: "appearanceMode"))
        XCTAssertEqual(tools.pending.count, 1)
        XCTAssertTrue(tools.relatedScopes.contains(.settings))
        XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✓"), true)
        XCTAssertEqual(tools.settingsDefaults.string(forKey: "appearanceMode"), "dark")
    }

    func testChangedSettingInvalidatesConfirmationWithoutOverwritingNativeChange() async throws {
        let tools = try makeTools()
        _ = try await call(tools, "propose_settings", ["changes": [["key": "appearanceMode", "value": "dark"]]])
        tools.settingsDefaults.set("light", forKey: "appearanceMode")
        XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✗"), true)
        XCTAssertEqual(tools.settingsDefaults.string(forKey: "appearanceMode"), "light")
        XCTAssertTrue(tools.pending.isEmpty)
    }

    func testInvalidSettingsBatchCannotCreatePartialProposal() async throws {
        let tools = try makeTools()
        let invalid = try await call(tools, "propose_settings", ["changes": [
            ["key": "appearanceMode", "value": "dark"], ["key": "jevAPIKey", "value": "secret"]
        ]])
        XCTAssertNotNil(invalid["error"])
        XCTAssertTrue(tools.pending.isEmpty)
        XCTAssertNil(tools.settingsDefaults.object(forKey: "appearanceMode"))
    }

    func testCreateAndUpdatePhasedTaskOnlyAfterConfirmation() async throws {
        let tools = try makeTools()
        let proposal = try await call(tools, "propose_task_plan", plan())
        XCTAssertEqual(proposal["saved"] as? Bool, false)
        XCTAssertTrue(tools.reminders.reminders.isEmpty)
        let preview = try XCTUnwrap(proposal["task"] as? [String: Any])
        XCTAssertEqual((preview["next_notifications"] as? [String])?.count, 6)
        XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✓"), true)
        let original = try XCTUnwrap(tools.reminders.reminders.first)
        XCTAssertTrue(tools.relatedScopes.contains(.task(original.id)))
        let result = try await call(tools, "propose_task_plan", plan(id: original.id, revision: original.revision, start: "2099-01-02 18:00"))
        XCTAssertNil(result["error"])
        XCTAssertEqual(tools.reminders.reminder(id: original.id)?.fireDate, original.fireDate)
        XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✓"), true)
        let updated = try XCTUnwrap(tools.reminders.reminder(id: original.id))
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.revision, original.revision + 1)
        XCTAssertGreaterThan(updated.fireDate, original.fireDate)
        XCTAssertEqual(updated.activity.map(\.kind), ["created", "updated"])
    }

    func testPausedTaskCanBeEditedWithoutResuming() async throws {
        let tools = try makeTools()
        _ = try await call(tools, "propose_task_plan", plan())
        _ = tools.confirmAll()
        let original = try XCTUnwrap(tools.reminders.reminders.first)
        try tools.reminders.pause(original.id)
        let paused = try XCTUnwrap(tools.reminders.reminder(id: original.id))
        let result = try await call(tools, "propose_task_plan", plan(id: paused.id, revision: paused.revision, start: "2099-01-02 18:00"))
        XCTAssertNil(result["error"])
        XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✓"), true)
        XCTAssertEqual(tools.reminders.reminder(id: paused.id)?.status, .paused)
        XCTAssertGreaterThan(try XCTUnwrap(tools.reminders.reminder(id: paused.id)?.fireDate), paused.fireDate)
        XCTAssertTrue(tools.reminders.upcoming.isEmpty)
    }

    func testStalePlanAndActionAreRejectedAtConfirmation() async throws {
        let tools = try makeTools()
        _ = try await call(tools, "propose_task_plan", plan())
        _ = tools.confirmAll()
        let original = try XCTUnwrap(tools.reminders.reminders.first)
        _ = try await call(tools, "propose_task_plan", plan(id: original.id, revision: original.revision, start: "2099-01-02 18:00"))
        _ = try await call(tools, "propose_task_action", action(original, "cancel"))
        try tools.reminders.pause(original.id)
        let receipts = tools.confirmAll()
        XCTAssertEqual(receipts.count, 2)
        XCTAssertTrue(receipts.allSatisfy { $0.hasPrefix("✗") })
        XCTAssertEqual(tools.reminders.reminder(id: original.id)?.status, .paused)
        XCTAssertEqual(tools.reminders.reminder(id: original.id)?.fireDate, original.fireDate)
    }

    func testActionsPauseResumeAndCancelPreserveHistory() async throws {
        let tools = try makeTools()
        _ = try await call(tools, "propose_task_plan", plan())
        _ = tools.confirmAll()
        let id = try XCTUnwrap(tools.reminders.reminders.first?.id)
        for (verb, expected) in [("pause", TimedReminder.Status.paused), ("resume", .active), ("cancel", .cancelled)] {
            let before = try XCTUnwrap(tools.reminders.reminder(id: id))
            let proposed = try await call(tools, "propose_task_action", action(before, verb))
            XCTAssertEqual(proposed["saved"] as? Bool, false)
            XCTAssertEqual(tools.reminders.reminder(id: id)?.status, before.status)
            XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✓"), true)
            XCTAssertEqual(tools.reminders.reminder(id: id)?.status, expected)
        }
        XCTAssertEqual(tools.reminders.reminder(id: id)?.activity.map(\.kind), ["created", "paused", "resumed", "cancelled"])
        let listed = try await call(tools, "get_tasks", ["id": id.uuidString])
        XCTAssertEqual((listed["tasks"] as? [[String: Any]])?.first?["status"] as? String, "cancelled")
        XCTAssertTrue(tools.reminders.upcoming.isEmpty)
    }

    func testCompletedTaskCannotProduceMisleadingResumeProposal() async throws {
        let tools = try makeTools()
        _ = try await call(tools, "propose_task_plan", plan())
        _ = tools.confirmAll()
        var reminder = try XCTUnwrap(tools.reminders.reminders.first)
        _ = try await call(tools, "propose_task_action", action(reminder, "complete"))
        XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✓"), true)
        reminder = try XCTUnwrap(tools.reminders.reminder(id: reminder.id))
        XCTAssertEqual(reminder.status, .completed)
        let result = try await call(tools, "propose_task_action", action(reminder, "resume"))
        XCTAssertNotNil(result["error"])
        XCTAssertTrue(tools.pending.isEmpty)
    }

    func testDiscardedPlanAndInvalidUnboundedIntervalsNeverWriteTasks() async throws {
        let tools = try makeTools()
        _ = try await call(tools, "propose_task_plan", plan())
        tools.clearPending()
        XCTAssertTrue(tools.reminders.reminders.isEmpty)
        XCTAssertTrue(tools.confirmAll().isEmpty)
        var fields = plan()
        fields["phases"] = [["start": "2099-01-01 18:00", "end": NSNull(), "repeat": "none", "interval_minutes": 10, "max_occurrences": NSNull()]]
        let result = try await call(tools, "propose_task_plan", fields)
        XCTAssertNotNil(result["error"])
        XCTAssertTrue(tools.pending.isEmpty)
        XCTAssertTrue(tools.reminders.reminders.isEmpty)
    }

    func testConfirmationDescribesEveryPhaseAndBoundBeyondTheFirstSixDates() async throws {
        let tools = try makeTools()
        var fields = plan()
        fields["end_time"] = "2099-01-04 20:00"
        fields["auto_complete_at"] = "2099-01-05 20:00"
        fields["phases"] = [
            ["start": "2099-01-01 18:00", "end": NSNull(), "repeat": "none", "interval_minutes": 10, "max_occurrences": 10],
            ["start": "2099-01-02 18:00", "end": "2099-01-04 18:00", "repeat": "daily", "interval_minutes": NSNull(), "max_occurrences": 8]
        ]
        let result = try await call(tools, "propose_task_plan", fields)
        XCTAssertNil(result["error"])
        let detail = try XCTUnwrap(tools.pending.first?.detail)
        for expected in ["阶段 1", "每 10 分钟", "最多 10 次", "阶段 2", "每天同一时间", "最多 8 次",
                         "2099-01-04 18:00", "下一阶段不会自动结束上一阶段", "全局停止时间：2099-01-04 20:00",
                         "2099-01-05 20:00 按约定自动标记完成", "最多 6 次预览"] {
            XCTAssertTrue(detail.contains(expected), expected)
        }
        let description = try XCTUnwrap(result["task"] as? [String: Any])
        XCTAssertTrue((description["rule_summary"] as? String)?.contains("阶段 2") == true)
        XCTAssertEqual((description["next_notifications"] as? [String])?.count, 6)
    }

    func testIndependentPhasesUseTheirEarliestStartRegardlessOfInputOrder() async throws {
        let tools = try makeTools()
        var fields = plan()
        fields["phases"] = [
            ["start": "2099-01-02 18:00", "end": NSNull(), "repeat": "none", "interval_minutes": NSNull(), "max_occurrences": NSNull()],
            ["start": "2099-01-01 18:00", "end": NSNull(), "repeat": "none", "interval_minutes": NSNull(), "max_occurrences": NSNull()]
        ]
        let result = try await call(tools, "propose_task_plan", fields)
        XCTAssertNil(result["error"])
        XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✓"), true)
        let reminder = try XCTUnwrap(tools.reminders.reminders.first)
        XCTAssertEqual(reminder.fireDate, reminder.phases?.last?.startDate)
        XCTAssertEqual(ReminderSchedule.preview(reminder).count, 2)
    }

    func testTaskReadRefreshesAutomaticCompletionBeforeReturningState() async throws {
        let now = Date.now
        let reminder = TimedReminder(text: "过期自动完成", fireDate: now.addingTimeInterval(-3600),
                                     autoCompleteAt: now.addingTimeInterval(-60))
        let tools = try makeTools(initialReminders: [reminder])
        XCTAssertEqual(tools.reminders.reminder(id: reminder.id)?.status, .active)
        let result = try await call(tools, "get_tasks", ["id": reminder.id.uuidString])
        let task = try XCTUnwrap((result["tasks"] as? [[String: Any]])?.first)
        XCTAssertEqual(task["status"] as? String, "completed")
        XCTAssertEqual(task["revision"] as? Int, reminder.revision + 1)
        XCTAssertEqual(tools.reminders.reminder(id: reminder.id)?.activity.last?.kind, "autoCompleted")
        XCTAssertEqual((task["next_notifications"] as? [String])?.count, 0)
    }
}

@MainActor
private final class ContextToolsNoJudge: ConditionJudge {
    var isConfigured: Bool { false }
    nonisolated deinit {}
    func judge(request: String, questions: [JevClient.Question]) async throws -> [String: Double] { [:] }
}
