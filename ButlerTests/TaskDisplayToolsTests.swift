import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor final class TaskDisplayToolsTests: XCTestCase {
    private final class Device: TaskDisplayDevice {
        var enabled = true
        var activities: [SystemTaskDisplay] = []
        var starts = 0
        func read() -> [SystemTaskDisplay] { activities }
        func start(_ record: TaskDisplayRecord) throws -> String {
            starts += 1
            activities.append(.init(id: "display", sessionID: record.id, taskID: record.taskID, active: true))
            return "display"
        }
        func end(_ id: String) async { activities.removeAll { $0.id == id } }
    }
    private final class NoJudge: ConditionJudge {
        var isConfigured: Bool { false }
        nonisolated deinit {}
        func judge(request: String, questions: [JevClient.Question]) async throws -> [String: Double] { [:] }
    }

    func testProposalRestoreConfirmationAndClosePreserveTask() async throws {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let reminders = ReminderStore(file: dir.appendingPathComponent("tasks.json"), schedules: false)
        let tools = ButlerTools(container: try ModelContainer(for: ButlerStore.schema, configurations: [config]),
            notes: try LocalMemoryStore(file: dir.appendingPathComponent("notes.json")), reminders: reminders, jev: NoJudge())
        let device = Device()
        tools.taskDisplays = TaskDisplayStore(file: dir.appendingPathComponent("displays.json"), device: device)
        let task = TimedReminder(text: "私密任务名称", fireDate: .now.addingTimeInterval(3600), repeats: .none)
        try reminders.add(task)
        let original = try Data(contentsOf: dir.appendingPathComponent("tasks.json"))
        let args: [String: Any] = ["task_id": task.id.uuidString, "expected_revision": task.revision,
            "until": ISO8601DateFormatter().string(from: .now.addingTimeInterval(1800))]
        let output = await tools.execute(LocalToolCall(id: "start", name: "propose_start_task_display",
            arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)))
        XCTAssertTrue(output.contains("confirmation_required"), output)
        XCTAssertEqual(device.starts, 0)
        XCTAssertTrue(tools.confirmAll().isEmpty)
        let saved = try JSONEncoder().encode(tools.pending)
        tools.restorePending(try JSONDecoder().decode([PendingChange].self, from: saved))
        let receipts = await tools.confirmResults()
        XCTAssertEqual(receipts.first?.state, .reported)
        _ = await tools.confirmIncludingSystemChanges()
        XCTAssertEqual(device.starts, 1)
        let record = try XCTUnwrap(tools.taskDisplays.read().first)
        let end: [String: Any] = ["task_id": task.id.uuidString, "session_id": record.id.uuidString]
        _ = await tools.execute(LocalToolCall(id: "end", name: "propose_end_task_display",
            arguments: String(decoding: try JSONSerialization.data(withJSONObject: end), as: UTF8.self)))
        XCTAssertEqual(device.activities.count, 1)
        _ = await tools.confirmIncludingSystemChanges()
        XCTAssertTrue(device.activities.isEmpty)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("tasks.json")), original)
    }
}
