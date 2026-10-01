import Foundation
import SwiftData
import XCTest
@testable import Butler

/// Requires the iOS test host; core journal tests also run on Linux.
@MainActor final class AppleReminderToolsTests: XCTestCase {
    private func tools() throws -> (ButlerTools, FakeAppleReminderDevice) {
        let directory = URL.temporaryDirectory.appendingPathComponent("reminder-tools-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ButlerStore.schema, configurations: [configuration])
        let tools = ButlerTools(container: container,
            notes: try LocalMemoryStore(file: directory.appendingPathComponent("notes.json")),
            reminders: ReminderStore(file: directory.appendingPathComponent("local.json"), schedules: false),
            jev: ReminderNoJudge())
        let device = FakeAppleReminderDevice()
        tools.appleReminders = AppleReminderStore(file: directory.appendingPathComponent("system.json"), device: device)
        return (tools, device)
    }

    private func call(_ tools: ButlerTools, _ name: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        let json = try JSONSerialization.data(withJSONObject: args)
        let result = await tools.execute(LocalToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: json, as: UTF8.self)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
    }

    private func create() -> [String: Any] {
        ["list_id": "work", "title": "交材料", "notes": "带原件", "priority": 4,
         "due": ["year": 2027, "month": 7, "day": 13, "hour": 9, "minute": 27, "timeZone": "Asia/Shanghai"],
         "recurrence": NSNull(), "notify_at_due": true]
    }

    func testConfirmedAccessDoesNotReadOrCreateAndDenialIsExplicit() async throws {
        let (tools, device) = try tools(); device.authorized = false
        let denied = try await call(tools, "get_apple_reminder_lists")
        XCTAssertNotNil(denied["error"])
        _ = try await call(tools, "propose_apple_reminder_access")
        XCTAssertEqual(device.authorizationCalls, 0)
        XCTAssertTrue(tools.confirmAll().isEmpty)
        let receipts = await tools.confirmIncludingSystemChanges()
        XCTAssertEqual(receipts.count, 1)
        XCTAssertTrue(receipts[0].hasPrefix("✗"))
        XCTAssertEqual(device.authorizationCalls, 1)
        XCTAssertTrue(device.writes.isEmpty)
    }

    func testProposalRestoreDeduplicationAndNoLocalMirroring() async throws {
        let (tools, device) = try tools()
        _ = try await call(tools, "propose_apple_reminder", create())
        _ = try await call(tools, "propose_apple_reminder", create())
        XCTAssertEqual(tools.pending.count, 1)
        XCTAssertTrue(device.writes.isEmpty)
        XCTAssertTrue(tools.pending[0].detail?.contains("工作") == true)
        let data = try JSONEncoder().encode(tools.pending)
        tools.restorePending(try JSONDecoder().decode([PendingChange].self, from: data))
        XCTAssertTrue(tools.confirmAll().isEmpty)
        let receipts = await tools.confirmIncludingSystemChanges()
        XCTAssertTrue(receipts.first?.hasPrefix("✓") == true, "\(receipts)")
        let replay = await tools.confirmIncludingSystemChanges()
        XCTAssertTrue(replay.isEmpty)
        XCTAssertEqual(device.writes.count, 1)
        XCTAssertEqual(device.live.values.first?.fields.due?.minute, 27)
        XCTAssertEqual(device.live.values.first?.list.id, "work")
        XCTAssertTrue(tools.reminders.upcoming.isEmpty)
    }

    func testDateOnlyNotificationAndMixedEditArgumentsRejected() async throws {
        let (tools, device) = try tools()
        var dateOnly = create()
        dateOnly["due"] = ["year": 2027, "month": 7, "day": 13, "hour": NSNull(), "minute": NSNull(), "timeZone": NSNull()]
        let rejected = try await call(tools, "propose_apple_reminder", dateOnly)
        XCTAssertNotNil(rejected["error"])
        XCTAssertTrue(tools.pending.isEmpty)
        dateOnly["notify_at_due"] = false
        _ = try await call(tools, "propose_apple_reminder", dateOnly)
        _ = await tools.confirmIncludingSystemChanges()
        let saved = try XCTUnwrap(device.live.values.first)
        XCTAssertNil(saved.fields.due?.hour)
        let invalid = try await call(tools, "propose_apple_reminder_edit", ["id": saved.id, "expected_revision": saved.revision,
            "field": "delete", "text": "不应忽略", "number": NSNull(), "flag": NSNull()])
        XCTAssertNotNil(invalid["error"])
        XCTAssertTrue(tools.pending.isEmpty)
        XCTAssertEqual(device.writes.count, 1)
    }

    func testSearchPaginationAndExternalEditInvalidatesPendingChange() async throws {
        let (tools, device) = try tools()
        for title in ["甲材料", "乙材料", "无关"] {
            var args = create(); args["title"] = title
            _ = try await call(tools, "propose_apple_reminder", args)
            _ = await tools.confirmIncludingSystemChanges()
        }
        let page = try await call(tools, "get_apple_reminders", ["query": "材料", "limit": 1])
        XCTAssertEqual(page["total"] as? Int, 2)
        XCTAssertEqual(page["next_offset"] as? Int, 1)
        let next = try await call(tools, "get_apple_reminders", ["query": "材料", "offset": 1, "limit": 1])
        let firstID = (page["reminders"] as? [[String: Any]])?.first?["id"] as? String
        let nextID = (next["reminders"] as? [[String: Any]])?.first?["id"] as? String
        XCTAssertNotNil(firstID); XCTAssertNotNil(nextID); XCTAssertNotEqual(firstID, nextID)
        let saved = try XCTUnwrap(device.live[firstID!])
        _ = try await call(tools, "propose_apple_reminder_edit", ["id": saved.id, "expected_revision": saved.revision,
            "field": "title", "text": "旧提案", "number": NSNull(), "flag": NSNull()])
        try device.edit(before: saved, patch: .title("手机里改的标题"))
        let receipts = await tools.confirmIncludingSystemChanges()
        XCTAssertTrue(receipts.first?.hasPrefix("✗") == true)
        XCTAssertEqual(device.live[saved.id]?.fields.title, "手机里改的标题")
        XCTAssertEqual(device.writes.count, 4)
    }
}

@MainActor private final class ReminderNoJudge: ConditionJudge {
    var isConfigured: Bool { false }
    nonisolated deinit {}
    func judge(request: String, questions: [JevClient.Question]) async throws -> [String: Double] { [:] }
}
