import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor final class TaskContextPayloadTests: XCTestCase {
    private final class NoJudge: ConditionJudge {
        var isConfigured: Bool { false }
        nonisolated deinit {}
        func judge(request: String, questions: [JevClient.Question]) async throws -> [String: Double] { [:] }
    }

    private let start = Date(timeIntervalSince1970: 4_070_937_600) // 2099-01-01 UTC

    private func makeTools(_ tasks: [TimedReminder]) throws -> ButlerTools {
        let directory = URL.temporaryDirectory.appendingPathComponent("TaskContextPayloadTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tasks.json")
        try JSONEncoder().encode(tasks).write(to: file)
        let configuration = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let household = HouseholdStore(directory: directory.appendingPathComponent("household"))
        return ButlerTools(container: try ModelContainer(for: ButlerStore.schema, configurations: [configuration]),
                           notes: try LocalMemoryStore(file: directory.appendingPathComponent("notes.json")),
                           reminders: ReminderStore(file: file, schedules: false, publishesChanges: false),
                           jev: NoJudge(), household: household, publishesChanges: false)
    }

    private func task(index: Int = 0, activities: Int) -> TimedReminder {
        TimedReminder(text: "测试任务\(index)", fireDate: start, createdAt: start.addingTimeInterval(-86_400),
                      revision: activities + 1, timeZoneIdentifier: "Asia/Shanghai",
                      activity: (0..<activities).map { offset in
            ReminderActivity(date: start.addingTimeInterval(Double(offset)), kind: "updated",
                             detail: "第\(offset)次操作：调整提醒计划，保留任务内容和家庭共享设置。")
        })
    }

    private func call(_ tools: ButlerTools, name: String = "get_tasks", fields: [String: Any]) async throws -> (String, [String: Any]) {
        let data = try JSONSerialization.data(withJSONObject: fields)
        let output = await tools.execute(LocalToolCall(id: UUID().uuidString, name: name,
                                                      arguments: String(decoding: data, as: UTF8.self)))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertNil(result["error"])
        return (output, result)
    }

    private func rows(_ result: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(result["tasks"] as? [[String: Any]])
    }

    func testListBoundsActivityAndReportsIncompleteHistoryWithoutChangingSavedTasks() async throws {
        let originals = [0, 2, 3, 9].enumerated().map { task(index: $0.offset, activities: $0.element) }
        let tools = try makeTools(originals)
        let (_, result) = try await call(tools, fields: ["id": NSNull()])
        let listed = try rows(result)
        XCTAssertEqual(result["total"] as? Int, originals.count)
        XCTAssertEqual(result["truncated"] as? Bool, false)
        for original in originals {
            let row = try XCTUnwrap(listed.first { $0["id"] as? String == original.id.uuidString })
            let activity = try XCTUnwrap(row["activity"] as? [[String: Any]])
            XCTAssertEqual(activity.compactMap { $0["id"] as? String }, original.activity.suffix(3).map { $0.id.uuidString })
            XCTAssertEqual(row["activity_total"] as? Int, original.activity.count)
            XCTAssertEqual(row["activity_truncated"] as? Bool, original.activity.count > 3)
            XCTAssertEqual(tools.reminders.reminder(id: original.id), original)
        }
        XCTAssertTrue(tools.pending.isEmpty)
    }

    func testDetailRestoresFullHistoryAndListPreservesAllOtherRuleAndFamilyFields() async throws {
        var original = task(activities: 20)
        let owner = UUID(), member = UUID()
        original.phases = [ReminderPhase(startDate: start, repeats: .daily, maxOccurrences: 10)]
        original.endDate = start.addingTimeInterval(20 * 86_400)
        original.autoCompleteAt = start.addingTimeInterval(21 * 86_400)
        original.sharing = TaskSharing(scope: .household, createdBy: owner, assignee: member)
        original.sharing?.notify = [member]
        original.sharing?.escalateTo = owner
        original.sharing?.escalateAfter = 30
        // This older fact must still appear in family.completed_by even when the activity is omitted from the list.
        original.activity[0].kind = "completed"
        original.activity[0].by = member
        let tools = try makeTools([original])
        tools.household.begin(HouseholdState(id: UUID(), name: "测试家庭", role: .owner, zoneName: "test",
                                            zoneOwner: "test", me: owner, joinedAt: start),
                              me: HouseholdMember(id: owner, name: "小安", isOwner: true, joinedAt: start))
        tools.household.upsert(HouseholdMember(id: member, name: "小林", isOwner: false, joinedAt: start))
        let (_, listResult) = try await call(tools, fields: ["id": NSNull()])
        let (_, detailResult) = try await call(tools, fields: ["id": original.id.uuidString])
        var list = try XCTUnwrap(rows(listResult).first)
        var detail = try XCTUnwrap(rows(detailResult).first)
        XCTAssertEqual((detail["activity"] as? [[String: Any]])?.count, 20)
        XCTAssertEqual(detail["activity_total"] as? Int, 20)
        XCTAssertEqual(detail["activity_truncated"] as? Bool, false)
        XCTAssertEqual((list["family"] as? [String: Any])?["completed_by"] as? String, "小林")
        XCTAssertEqual((list["next_notifications"] as? [String])?.count, 6)
        list.removeValue(forKey: "activity"); detail.removeValue(forKey: "activity")
        list.removeValue(forKey: "activity_truncated"); detail.removeValue(forKey: "activity_truncated")
        XCTAssertEqual(try tools.encode(list), try tools.encode(detail), "Only activity completeness differs between list and detail")
        XCTAssertEqual(tools.reminders.reminder(id: original.id), original)
    }

    func testPatchUsingListRevisionKeepsHistoryThatWasNotInList() async throws {
        var original = task(activities: 15)
        original.timePeriod = .afternoon
        original.status = .paused
        let tools = try makeTools([original])
        let (_, listResult) = try await call(tools, fields: ["id": NSNull()])
        let listed = try XCTUnwrap(rows(listResult).first)
        _ = try await call(tools, name: "propose_task_update", fields: [
            "id": try XCTUnwrap(listed["id"] as? String),
            "expected_revision": try XCTUnwrap(listed["revision"] as? Int),
            "text": "更新后的事项", "schedule": NSNull(), "family": NSNull()
        ])
        XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✓"), true)
        let saved = try XCTUnwrap(tools.reminders.reminder(id: original.id))
        XCTAssertEqual(saved.activity.count, original.activity.count + 1)
        XCTAssertEqual(Array(saved.activity.prefix(original.activity.count)), original.activity)
        XCTAssertEqual(saved.text, "更新后的事项")
        XCTAssertEqual(saved.timePeriod, original.timePeriod)
        XCTAssertEqual(saved.status, original.status)
        XCTAssertEqual(saved.revision, original.revision + 1)
    }

    func testLargeSyntheticListShrinksPayloadAndKeepsTaskTruncationSeparate() async throws {
        let originals = (0..<105).map { task(index: $0, activities: 100) }
        let tools = try makeTools(originals)
        let (output, result) = try await call(tools, fields: ["id": NSNull()])
        let listed = try rows(result)
        XCTAssertEqual(listed.count, 100)
        XCTAssertEqual(result["total"] as? Int, 105)
        XCTAssertEqual(result["truncated"] as? Bool, true)
        XCTAssertTrue(listed.allSatisfy { ($0["activity"] as? [[String: Any]])?.count == 3 && $0["activity_total"] as? Int == 100 })
        var baseline = result
        baseline["tasks"] = try tools.reminders.reminders.suffix(100).map { task in
            var full = try tools.taskDescription(task)
            // Before this optimization, list rows contained all history without completeness metadata.
            full.removeValue(forKey: "activity_total")
            full.removeValue(forKey: "activity_truncated")
            return full
        }
        let beforeBytes = try tools.encode(baseline).utf8.count
        let afterBytes = output.utf8.count
        XCTAssertLessThan(afterBytes, beforeBytes / 5)
        print("TaskContextPayload synthetic 100 tasks x 100 activities: before=\(beforeBytes) bytes after=\(afterBytes) bytes")
        XCTAssertEqual(tools.reminders.reminders, originals)
    }
}
