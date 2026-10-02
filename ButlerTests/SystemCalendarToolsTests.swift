import Foundation
import SwiftData
import XCTest
@testable import Butler

/// Runs against the real dispatcher/confirmation path in the iOS test host.
@MainActor final class SystemCalendarToolsTests: XCTestCase {
    private func setup() throws -> (ButlerTools, FakeCalendarDevice) {
        let dir = URL.temporaryDirectory.appendingPathComponent("calendar-tools-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let config = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let tools = ButlerTools(container: try ModelContainer(for: ButlerStore.schema, configurations: [config]),
            notes: try LocalMemoryStore(file: dir.appendingPathComponent("notes.json")),
            reminders: ReminderStore(file: dir.appendingPathComponent("reminders.json"), schedules: false), jev: CalendarNoJudge())
        let device = FakeCalendarDevice()
        tools.systemCalendar = SystemCalendarStore(file: dir.appendingPathComponent("calendar.json"), device: device)
        return (tools, device)
    }
    private func call(_ tools: ButlerTools, _ name: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: args)
        let result = await tools.execute(LocalToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: data, as: UTF8.self)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
    }
    private func create() -> [String: Any] {
        ["calendar_id": "work", "frequency": NSNull(), "fields": ["title": "交材料", "notes": String(repeating: "原", count: 201),
            "location": "东门", "start": "2027-07-13T09:27:00+08:00", "end": "2027-07-13T10:12:00+08:00",
            "timeZone": "Asia/Shanghai", "allDay": false, "alertMinutes": 17]]
    }
    func testSeparateConsentProposalRestoreAndNoDuplicateOrLocalNotification() async throws {
        let (tools, device) = try setup()
        XCTAssertTrue(device.authorized)
        let blocked = try await call(tools, "get_system_calendars")
        XCTAssertNotNil(blocked["error"]); XCTAssertEqual(device.reads, 0)
        _ = try await call(tools, "propose_calendar_access", ["allowed": true])
        XCTAssertFalse(tools.systemCalendar.conversationAllowed)
        XCTAssertTrue(tools.confirmAll().isEmpty)
        _ = await tools.confirmIncludingSystemChanges()
        XCTAssertTrue(tools.systemCalendar.conversationAllowed); XCTAssertEqual(device.reads, 0)
        _ = try await call(tools, "propose_calendar_event", create())
        _ = try await call(tools, "propose_calendar_event", create())
        XCTAssertEqual(tools.pending.count, 1); XCTAssertEqual(device.writes, 0)
        let saved = try JSONEncoder().encode(tools.pending)
        tools.restorePending(try JSONDecoder().decode([PendingChange].self, from: saved))
        let receipts = await tools.confirmResults()
        XCTAssertEqual(receipts.first?.state, .reported)
        _ = await tools.confirmIncludingSystemChanges()
        XCTAssertEqual(device.writes, 1); XCTAssertEqual(device.live.first?.calendar.id, "work")
        XCTAssertTrue(tools.reminders.upcoming.isEmpty)
        _ = try await call(tools, "propose_calendar_access", ["allowed": false])
        _ = await tools.confirmIncludingSystemChanges()
        let revoked = try await call(tools, "get_calendar_operations", ["operation_id": NSNull()])
        XCTAssertNotNil(revoked["error"])
    }
    func testQueriesPreserveKeyAndFullNotesAndMalformedDeleteCannotBecomeProposal() async throws {
        let (tools, _) = try setup()
        _ = try await tools.systemCalendar.apply(.access(true), operationID: UUID())
        _ = try await call(tools, "propose_calendar_event", create())
        _ = await tools.confirmIncludingSystemChanges()
        let page = try await call(tools, "get_calendar_events", ["start": "2027-07-13T00:00:00Z", "end": "2027-07-14T00:00:00Z", "limit": 1])
        let row = try XCTUnwrap((page["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["notes_truncated"] as? Bool, true)
        let key = try XCTUnwrap(row["key"] as? [String: Any])
        XCTAssertEqual(key["start"] as? String, "2027-07-13T01:27:00Z")
        let full = try await call(tools, "get_calendar_event", ["key": key])
        let event = try XCTUnwrap(full["event"] as? [String: Any])
        XCTAssertEqual(((event["fields"] as? [String: Any])?["notes"] as? String)?.count, 201)
        let invalid = try await call(tools, "propose_calendar_event_edit", ["key": key, "expected_revision": row["revision"]!,
            "field": "delete", "span": "thisEvent", "text": "不可忽略的内容", "schedule": NSNull()])
        XCTAssertNotNil(invalid["error"]); XCTAssertTrue(tools.pending.isEmpty)
    }
    func testStrictSchemasAndDateParsing() throws {
        let schemas = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("[\(ButlerTools.systemCalendarTools)]".utf8)) as? [[String: Any]])
        XCTAssertEqual(schemas.count, 8)
        func check(_ value: Any) throws {
            if let object = value as? [String: Any] {
                if object["type"] as? String == "object" {
                    let properties = try XCTUnwrap(object["properties"] as? [String: Any])
                    XCTAssertEqual(object["additionalProperties"] as? Bool, false)
                    XCTAssertEqual(Set(object["required"] as? [String] ?? []), Set(properties.keys))
                }
                for child in object.values { try check(child) }
            } else if let array = value as? [Any] { for child in array { try check(child) } }
        }
        try check(schemas)
        for schema in schemas { XCTAssertEqual(schema["strict"] as? Bool, true) }
        let actual = try ButlerTools.calendarDate("2027-07-13T09:27:00+08:00")
        XCTAssertEqual(ISO8601DateFormatter().string(from: actual), "2027-07-13T01:27:00Z")
        for invalid in ["2027-02-30T09:27:00Z", "2027-07-13T09:27:00", "2027-07-13T09:27:00+14:01"] {
            XCTAssertThrowsError(try ButlerTools.calendarDate(invalid))
        }
    }
}

@MainActor private final class CalendarNoJudge: ConditionJudge {
    var isConfigured: Bool { false }
    nonisolated deinit {}
    func judge(request: String, questions: [JevClient.Question]) async throws -> [String: Double] { [:] }
}
