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

    func testBriefSnapshotIncludesEveryTaskAndConfirmedNoteWithoutRequestingCalendarPermission() async throws {
        let (tools, device) = try setup()
        let now = Date.now
        for index in 0..<37 {
            try tools.reminders.add(TimedReminder(text: index == 36 ? "明早出差" : "任务\(index)",
                fireDate: now.addingTimeInterval(Double(index + 1) * 3600)))
        }
        let note = LocalMemory(id: UUID(), title: "临时安排", text: "这周出差，周六回来", quantity: nil, revision: 1)
        try tools.notes.upsert(note)
        tools.add(.note(.init(id: UUID(), title: "未确认", text: "不能当成偏好", quantity: nil, revision: 1)),
                  title: "未确认", detail: nil)
        let before = try tools.reminders.taskSnapshot()
        let context = BriefSources.snapshot(tools: tools, now: now)
        XCTAssertEqual(context.sections["tasks"]?.count, 37)
        XCTAssertTrue(context.sections["tasks"]?.contains { $0["text"] as? String == "明早出差" } == true)
        XCTAssertEqual(context.sections["notes"]?.count, 1)
        XCTAssertEqual(context.sections["notes"]?.first?["text"] as? String, note.text)
        XCTAssertNil(context.sections["calendar"])
        XCTAssertEqual(device.reads, 0)
        XCTAssertEqual(device.authorizationCalls, 0)
        XCTAssertEqual(try tools.reminders.taskSnapshot(), before)
        XCTAssertEqual(tools.pending.count, 1)
        var corrected = note; corrected.text = "不是周六，是周五回来"; corrected.revision = 2
        try tools.notes.upsert(corrected)
        XCTAssertNotEqual(context.signature, BriefSources.snapshot(tools: tools, now: now).signature)
    }

    func testBriefCalendarReadsKeepConsentGateAndRevokeCapturedSnapshot() async throws {
        let (tools, device) = try setup()
        let now = try ButlerTools.calendarDate("2027-07-13T00:00:00+08:00")
        let model = CloudBriefModel(connection: SubscriptionConnection(keychainAccount: "brief-calendar-\(UUID())"), tools: tools)
        let blocked = model.snapshot(now: now)
        let reads = BriefReadSession(context: blocked)
        let output = await reads.execute(.init(id: "calendar", name: "get_system_calendars", arguments: "{}"), readTool: tools.execute)
        XCTAssertTrue(output.contains("error"))
        XCTAssertEqual(device.reads, 0)
        _ = try await tools.systemCalendar.apply(.access(true), operationID: UUID())
        _ = try await call(tools, "propose_calendar_event", create())
        _ = await tools.confirmIncludingSystemChanges()
        let captured = model.snapshot(now: now)
        XCTAssertEqual(captured.sections["calendar"]?.count, 1)
        XCTAssertNoThrow(try model.validateSources(for: captured))
        let writes = device.writes, permissions = device.authorizationCalls
        _ = model.snapshot(now: now)
        XCTAssertEqual(device.writes, writes)
        XCTAssertEqual(device.authorizationCalls, permissions)
        _ = try await tools.systemCalendar.apply(.access(false), operationID: UUID())
        XCTAssertThrowsError(try model.validateSources(for: captured))
        XCTAssertNil(model.snapshot(now: now).sections["calendar"])
    }

    func testBriefReadsAllRecentTurnsAcrossPagesAndRejectsShiftedHistoryNumbers() throws {
        let (tools, _) = try setup()
        let turns = (0..<14).map { index in
            ChatTurn(question: "第\(index)轮" + String(repeating: "长原文", count: 2200), answer: "已收到",
                     date: Date(timeIntervalSince1970: Double(index + 100)))
        }
        tools.conversation = { ConversationArchive(turns: turns, recentStart: nil, summaryThrough: nil) }
        let model = CloudBriefModel(connection: SubscriptionConnection(keychainAccount: "brief-history-\(UUID())"), tools: tools)
        let captured = model.snapshot(now: .now)
        let recent = try XCTUnwrap(captured.sections["recent_conversation"])
        XCTAssertEqual(recent.count, 12)
        XCTAssertEqual(recent.first?["user"] as? String, turns[2].question)
        XCTAssertEqual(recent.last?["user"] as? String, turns[13].question)
        XCTAssertNoThrow(try model.validateSources(for: captured))
        let imported = ChatTurn(question: "补同步的旧交代", date: Date(timeIntervalSince1970: 1))
        tools.conversation = { ConversationArchive(turns: [imported] + turns, recentStart: nil, summaryThrough: nil) }
        XCTAssertThrowsError(try model.validateSources(for: captured))
        XCTAssertNoThrow(try model.validateSources(for: model.snapshot(now: .now)))
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
