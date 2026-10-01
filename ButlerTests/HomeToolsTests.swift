import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor final class HomeToolsTests: XCTestCase {
    private func setup() throws -> (ButlerChat, ButlerTools, FakeHomeDevice, URL) {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "home-tools-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { try? FileManager.default.removeItem(at: dir); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let config = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ButlerStore.schema, configurations: [config])
        let chat = ButlerChat(container: container,
            reminders: ReminderStore(file: dir.appendingPathComponent("reminders.json"), schedules: false),
            connection: SubscriptionConnection(keychainAccount: suite), directory: dir, defaults: defaults)
        let tools = try XCTUnwrap(chat.tools), device = FakeHomeDevice()
        tools.home = HomeStore(file: dir.appendingPathComponent("home.json"), device: device)
        return (chat, tools, device, dir)
    }
    private func call(_ tools: ButlerTools, _ name: String, _ args: [String: Any] = [:]) async throws -> String {
        await tools.execute(LocalToolCall(id: UUID().uuidString, name: name,
            arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)))
    }
    func testToolsOnlyProposeAndDeduplicateThenConfirmOnce() async throws {
        let (chat, tools, device, _) = try setup(); defer { withExtendedLifetime(chat) {} }
        _ = try await call(tools, "get_home_capabilities")
        let refused = try await call(tools, "get_homes")
        XCTAssertTrue(refused.contains("error")); XCTAssertEqual(device.connects, 0)
        _ = try await call(tools, "propose_home_access", ["allowed": true])
        _ = try await call(tools, "propose_home_access", ["allowed": true])
        XCTAssertEqual(tools.pending.count, 1); XCTAssertEqual(device.connects, 0)
        _ = await tools.confirmIncludingSystemChanges()
        let args: [String: Any] = ["home_id": device.live.id.uuidString, "control_id": device.live.controls[0].id.uuidString, "target": 1]
        _ = try await call(tools, "propose_home_control", args)
        _ = try await call(tools, "propose_home_control", args)
        XCTAssertEqual(tools.pending.count, 1); XCTAssertEqual(device.writes, 0)
        XCTAssertTrue(tools.confirmAll().isEmpty)
        _ = await tools.confirmIncludingSystemChanges()
        _ = await tools.confirmIncludingSystemChanges()
        XCTAssertEqual(device.writes, 1)
    }
    func testRiskyBatchRetainsLocalAndDiskQueueWithoutSideEffects() async throws {
        let (chat, tools, device, dir) = try setup(); defer { withExtendedLifetime(chat) {} }
        _ = try await tools.home.apply(.access(true), operationID: UUID(), soleConfirmation: true)
        let lock = FakeHomeDevice.control(.lock)
        device.live = .init(id: device.live.id, name: "家", rooms: [], controls: [lock], scenes: [])
        _ = try await call(tools, "propose_home_control", ["home_id": device.live.id.uuidString, "control_id": lock.id.uuidString, "target": 0])
        let note = LocalMemory(id: UUID(), title: "保持不写", text: "普通修改", quantity: nil, revision: 1)
        tools.add(.note(note), title: "记笔记", detail: nil)
        let disk = dir.appendingPathComponent("pending-changes.json"), before = try Data(contentsOf: disk)
        chat.confirm()
        XCTAssertNotNil(chat.error)
        XCTAssertEqual(try Data(contentsOf: disk), before)
        XCTAssertEqual(tools.pending.count, 2)
        XCTAssertTrue(tools.confirmAll().joined().contains("单独确认"))
        let refused = await tools.confirmIncludingSystemChanges()
        XCTAssertTrue(refused.joined().contains("单独确认"))
        XCTAssertFalse(tools.notes.records.contains { $0.id == note.id })
        XCTAssertEqual(device.writes, 0)
        _ = await tools.confirmIncludingSystemChanges(ids: [tools.pending[0].id])
        XCTAssertEqual(device.writes, 1); XCTAssertEqual(tools.pending.count, 1)
        XCTAssertFalse(tools.notes.records.contains { $0.id == note.id })
    }
    func testSchemasAreStrictAndPaginationIsBounded() async throws {
        let (chat, tools, device, _) = try setup(); defer { withExtendedLifetime(chat) {} }
        let schemas = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("[\(ButlerTools.homeTools)]".utf8)) as? [[String: Any]])
        XCTAssertEqual(schemas.count, 8)
        for schema in schemas {
            XCTAssertEqual(schema["strict"] as? Bool, true)
            let p = try XCTUnwrap(schema["parameters"] as? [String: Any])
            XCTAssertEqual(p["additionalProperties"] as? Bool, false)
            XCTAssertEqual(Set(p["required"] as? [String] ?? []), Set((p["properties"] as? [String: Any] ?? [:]).keys))
        }
        _ = try await tools.home.apply(.access(true), operationID: UUID(), soleConfirmation: true)
        device.live = .init(id: device.live.id, name: "家", rooms: [], controls: (0..<47).map { _ in FakeHomeDevice.control() }, scenes: [])
        let response = try await call(tools, "get_home_details", ["home_id": device.live.id.uuidString, "offset": 30])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        XCTAssertEqual(json["control_count"] as? Int, 47)
        XCTAssertEqual(((json["page"] as? [String: Any])?["controls"] as? [Any])?.count, 17)
    }
}
