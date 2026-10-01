import Foundation
import SwiftData
import XCTest
@testable import Butler

/// Exercises the real conversation dispatcher and confirmation path. Requires the iOS test host.
@MainActor final class AlarmToolsTests: XCTestCase {
    private func makeTools() throws -> (ButlerTools, FakeAlarmDevice) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alarm-tools-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ButlerStore.schema, configurations: [configuration])
        let tools = ButlerTools(container: container,
                                notes: try LocalMemoryStore(file: directory.appendingPathComponent("notes.json")),
                                reminders: ReminderStore(file: directory.appendingPathComponent("reminders.json"), schedules: false),
                                jev: AlarmNoJudge())
        let device = FakeAlarmDevice()
        tools.alarms = AlarmStore(file: directory.appendingPathComponent("alarms.json"), device: device)
        return (tools, device)
    }

    private func call(_ tools: ButlerTools, _ name: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let json = try JSONSerialization.data(withJSONObject: arguments)
        let output = await tools.execute(LocalToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: json, as: UTF8.self)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

    private func timer(_ seconds: Int = 173) -> [String: Any] {
        ["id": NSNull(), "expected_revision": NSNull(), "title": "煮面", "mode": "timer",
         "at": NSNull(), "hour": NSNull(), "minute": NSNull(), "weekdays": [], "seconds": seconds]
    }

    func testProposalRoundTripDeduplicationAndConfirmationOnlyOnce() async throws {
        let (tools, device) = try makeTools()
        _ = try await call(tools, "get_alarm_capabilities")
        _ = try await call(tools, "get_alarms", ["id": NSNull()])
        _ = try await call(tools, "propose_alarm", timer())
        _ = try await call(tools, "propose_alarm", timer())
        XCTAssertEqual(tools.pending.count, 1)
        XCTAssertEqual(device.authorizationCalls, 0)
        XCTAssertTrue(device.events.isEmpty)
        XCTAssertTrue(tools.confirmAll().isEmpty, "The synchronous path must not consume a system proposal")
        let persisted = try JSONEncoder().encode(tools.pending)
        tools.restorePending(try JSONDecoder().decode([PendingChange].self, from: persisted))
        let receipts = await tools.confirmIncludingSystemChanges()
        XCTAssertEqual(receipts.count, 1)
        XCTAssertTrue(receipts[0].hasPrefix("✓"), receipts[0])
        XCTAssertTrue(tools.pending.isEmpty)
        let replay = await tools.confirmIncludingSystemChanges()
        XCTAssertTrue(replay.isEmpty)
        XCTAssertEqual(device.events.count, 1)
        XCTAssertEqual(tools.alarms.records.first?.rule, .timer(seconds: 173))
        XCTAssertTrue(tools.reminders.upcoming.isEmpty, "An alarm must not create a second notification")
    }

    func testMalformedRulesCannotBecomeProposalsAndOffsetIsPreserved() async throws {
        let (tools, device) = try makeTools()
        var mixed = timer(); mixed["hour"] = 7
        var invalidDuration = timer(); invalidDuration["seconds"] = 0
        var missingRevision = timer(); missingRevision["id"] = UUID().uuidString
        var noZone = timer(); noZone["mode"] = "once"; noZone["seconds"] = NSNull()
        noZone["at"] = "2099-10-03T07:23:00"
        for arguments in [mixed, invalidDuration, missingRevision, noZone] {
            let output = try await call(tools, "propose_alarm", arguments)
            XCTAssertNotNil(output["error"], "\(output)")
        }
        XCTAssertTrue(tools.pending.isEmpty)
        var dated = noZone; dated["at"] = "2099-10-03T07:23:00+08:00"
        let output = try await call(tools, "propose_alarm", dated)
        XCTAssertNil(output["error"])
        guard case .alarm(.set(_, _, .once(let date), nil)) = tools.pending.first?.kind else {
            return XCTFail("Expected a one-time alarm proposal")
        }
        XCTAssertEqual(ISO8601DateFormatter().string(from: date), "2099-10-02T23:23:00Z")
        XCTAssertEqual(device.authorizationCalls, 0)
    }

    func testDenialAndPartialBatchSuccessAreReportedIndividually() async throws {
        let (tools, device) = try makeTools()
        device.authorization = "denied"
        _ = try await call(tools, "propose_alarm", timer())
        _ = try await call(tools, "propose_note", ["id": NSNull(), "title": "偏好", "text": "煮面不放辣椒"])
        let receipts = await tools.confirmIncludingSystemChanges()
        XCTAssertEqual(receipts.filter { $0.hasPrefix("✓") }.count, 1)
        XCTAssertEqual(receipts.filter { $0.hasPrefix("✗") && $0.contains("权限") }.count, 1)
        XCTAssertEqual(tools.notes.records.count, 1)
        XCTAssertTrue(tools.alarms.records.isEmpty)
        XCTAssertTrue(device.events.isEmpty)
        XCTAssertTrue(tools.pending.isEmpty)
    }

    func testSelectiveConfirmationAndNoDuplicateWhilePermissionWaits() async throws {
        let (tools, device) = try makeTools()
        _ = try await call(tools, "propose_alarm", timer(173))
        _ = try await call(tools, "propose_alarm", timer(239))
        let firstID = try XCTUnwrap(tools.pending.first?.id)
        var permission: CheckedContinuation<Void, Never>?
        device.onAuthorize = { await withCheckedContinuation { permission = $0 } }
        let first = Task { await tools.confirmIncludingSystemChanges(ids: [firstID]) }
        while permission == nil { await Task.yield() }
        let duplicate = await tools.confirmIncludingSystemChanges(ids: [firstID])
        XCTAssertTrue(duplicate.isEmpty)
        XCTAssertEqual(tools.pending.count, 1)
        permission?.resume()
        let results = await first.value
        XCTAssertEqual(results.filter { $0.hasPrefix("✓") }.count, 1)
        XCTAssertEqual(device.events.count, 1)
        XCTAssertEqual(tools.alarms.records.first?.rule, .timer(seconds: 173))
    }

    func testRemainingTimeNeverUsesOriginalDurationAndStaleActionIsRejected() async throws {
        let (tools, device) = try makeTools()
        _ = try await call(tools, "propose_alarm", timer())
        _ = await tools.confirmIncludingSystemChanges()
        let value = try XCTUnwrap(tools.alarms.records.first)
        let unknown = try await call(tools, "get_alarms", ["id": value.id.uuidString])
        let rows = try XCTUnwrap(unknown["alarms"] as? [[String: Any]])
        XCTAssertTrue(rows[0]["remaining_seconds"] is NSNull)
        device.live = [SystemAlarm(id: value.systemID, state: .countdown, remainingSeconds: 61)]
        let known = try await call(tools, "get_alarms", ["id": value.id.uuidString])
        XCTAssertEqual((known["alarms"] as? [[String: Any]])?.first?["remaining_seconds"] as? Double, 61)
        _ = try await call(tools, "propose_alarm_action", ["id": value.id.uuidString, "expected_revision": 1, "action": "pause"])
        try await tools.alarms.apply(.action(id: value.id, action: .cancel, expectedRevision: 1,
                                            expiresAt: .now.addingTimeInterval(300)), operationID: UUID())
        let results = await tools.confirmIncludingSystemChanges()
        XCTAssertEqual(results.filter { $0.hasPrefix("✗") && $0.contains("变化") }.count, 1)
        XCTAssertFalse(device.events.contains { $0.hasPrefix("pause:") })
    }

    func testSearchAndPaginationKeepOlderAlarmsReachable() async throws {
        let (tools, _) = try makeTools()
        for title in ["周末叫醒", "煮面", "午睡叫醒"] {
            try await tools.alarms.apply(.set(id: UUID(), title: title, rule: .timer(seconds: 173), expectedRevision: nil), operationID: UUID())
        }
        let first = try await call(tools, "get_alarms", ["query": "叫醒", "limit": 1])
        XCTAssertEqual(first["total"] as? Int, 2)
        XCTAssertEqual(first["next_offset"] as? Int, 1)
        XCTAssertEqual((first["alarms"] as? [[String: Any]])?.first?["title"] as? String, "周末叫醒")
        let second = try await call(tools, "get_alarms", ["query": "叫醒", "limit": 1, "offset": 1])
        XCTAssertEqual((second["alarms"] as? [[String: Any]])?.first?["title"] as? String, "午睡叫醒")
        XCTAssertTrue(second["next_offset"] is NSNull)
        let outside = try await call(tools, "get_alarms", ["offset": Int.max])
        XCTAssertEqual((outside["alarms"] as? [[String: Any]])?.count, 0)
        XCTAssertTrue(outside["next_offset"] is NSNull)
        let invalid = try await call(tools, "get_alarms", ["limit": 101])
        XCTAssertNotNil(invalid["error"])
    }

    func testAlarmToolSchemasRequireAllPropertiesAndForbidExtras() throws {
        let schemas = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("[\(ButlerTools.alarmTools)]".utf8)) as? [[String: Any]])
        XCTAssertEqual(Set(schemas.compactMap { $0["name"] as? String }),
                       Set(["get_alarm_capabilities", "get_alarms", "propose_alarm", "propose_alarm_action"]))
        for schema in schemas {
            XCTAssertEqual(schema["strict"] as? Bool, true)
            let parameters = try XCTUnwrap(schema["parameters"] as? [String: Any])
            let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
            XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)
            XCTAssertEqual(Set(parameters["required"] as? [String] ?? []), Set(properties.keys))
        }
    }
}

@MainActor private final class AlarmNoJudge: ConditionJudge {
    var isConfigured: Bool { false }
    nonisolated deinit {}
    func judge(request: String, questions: [JevClient.Question]) async throws -> [String: Double] { [:] }
}
