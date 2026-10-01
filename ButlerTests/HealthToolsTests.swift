import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor final class HealthToolsTests: XCTestCase {
    private func setup() throws -> (ButlerChat, ButlerTools, FakeHealthDevice, URL, ModelContainer, UserDefaults) {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "health-tools-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { try? FileManager.default.removeItem(at: dir); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let config = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ButlerStore.schema, configurations: [config])
        let chat = ButlerChat(container: container,
            reminders: ReminderStore(file: dir.appendingPathComponent("reminders.json"), schedules: false),
            connection: SubscriptionConnection(keychainAccount: suite), directory: dir, defaults: defaults)
        let tools = try XCTUnwrap(chat.tools), device = FakeHealthDevice()
        tools.health = HealthStore(file: dir.appendingPathComponent("DeviceHealth/operations.json"), device: device)
        return (chat, tools, device, dir, container, defaults)
    }
    private func call(_ tools: ButlerTools, _ name: String, _ args: [String: Any] = [:]) async throws -> String {
        await tools.execute(LocalToolCall(id: UUID().uuidString, name: name,
            arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)))
    }
    func testReadProposalIsEphemeralAndNativeResultNeverReturnsToModel() async throws {
        let (chat, tools, device, dir, _, _) = try setup()
        defer { withExtendedLifetime(chat) {} } // Keep the real persistence callback alive.
        let format = ISO8601DateFormatter()
        let args: [String: Any] = ["metrics": ["steps"], "start": format.string(from: .now.addingTimeInterval(-86400)),
            "end": format.string(from: .now.addingTimeInterval(-10))]
        _ = try await call(tools, "get_health_capabilities")
        _ = try await call(tools, "propose_health_summary", args)
        _ = try await call(tools, "propose_health_summary", args)
        XCTAssertEqual(tools.pending.count, 1)
        XCTAssertEqual(device.reads, 0)
        XCTAssertTrue(device.grants.isEmpty)
        XCTAssertTrue(tools.confirmAll().isEmpty)
        let disk = try JSONDecoder().decode([PendingChange].self, from: Data(contentsOf: dir.appendingPathComponent("pending-changes.json")))
        XCTAssertTrue(disk.isEmpty)
        var local: [String] = []
        tools.onLocalHealthResult = { local.append($0) }
        let receipt = await tools.confirmIncludingSystemChanges()
        XCTAssertEqual(local, [device.secretResult])
        XCTAssertFalse(receipt.joined().contains(device.secretResult))
        XCTAssertFalse(tools.pendingContext.contains(device.secretResult))
        let output = try await call(tools, "get_health_operations")
        XCTAssertFalse(output.contains(device.secretResult))
        _ = await tools.confirmIncludingSystemChanges()
        XCTAssertEqual(device.reads, 1)
    }
    func testNativeResultExcludedFromHistoryContextArchiveAndBackup() throws {
        let (_, _, device, dir, container, defaults) = try setup()
        var turn = ChatTurn(question: "看这周的活动", answer: "请确认范围", receipts: ["查询已完成"])
        turn.localHealthResults = [device.secretResult]
        XCTAssertTrue(turn.displayReceipts.contains(device.secretResult))
        let encoded = try JSONEncoder().encode(turn)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(device.secretResult))
        XCTAssertTrue(try JSONDecoder().decode(ChatTurn.self, from: encoded).localHealthResults.isEmpty)
        let messages = ButlerChat.context(from: [turn], summary: .init())
        let body = try SubscriptionModel.requestBody(messages, instructions: "test", toolJSON: "[]")
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(device.secretResult))
        let archive = ConversationArchive(turns: [turn], recentStart: 0, summaryThrough: nil)
        let read = archive.read(fromTurn: nil, toTurn: nil, from: nil, to: nil, cursor: nil)
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: read), as: UTF8.self).contains(device.secretResult))
        try ChatSessionFiles(scope: .general, root: dir).saveTurns([turn])
        let backup = try BackupService.makeBackup(container: container, directory: dir, defaults: defaults)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(backup), as: UTF8.self).contains(device.secretResult))
    }
    func testSchemasAndInvalidWritesNeverBecomeProposals() async throws {
        let (chat, tools, device, _, _, _) = try setup()
        defer { withExtendedLifetime(chat) {} }
        let schemas = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("[\(ButlerTools.healthTools)]".utf8)) as? [[String: Any]])
        XCTAssertEqual(schemas.count, 9)
        for schema in schemas {
            XCTAssertEqual(schema["strict"] as? Bool, true)
            let p = try XCTUnwrap(schema["parameters"] as? [String: Any])
            XCTAssertEqual(p["additionalProperties"] as? Bool, false)
            XCTAssertEqual(Set(p["required"] as? [String] ?? []), Set((p["properties"] as? [String: Any] ?? [:]).keys))
        }
        let invalid = try await call(tools, "propose_health_record", ["metric": "water", "value": 2, "unit": "杯", "date": "2026-09-01T10:00:00Z"])
        XCTAssertTrue(invalid.contains("error"))
        let noZone = try await call(tools, "propose_health_record", ["metric": "water", "value": 200, "unit": "mL", "date": "2026-09-01T10:00:00"])
        XCTAssertTrue(noZone.contains("error"))
        XCTAssertTrue(tools.pending.isEmpty)
        XCTAssertEqual(device.writes, 0)
    }
}
