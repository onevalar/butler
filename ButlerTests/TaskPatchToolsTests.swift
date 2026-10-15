import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor final class TaskPatchToolsTests: XCTestCase {
    private final class NoJudge: ConditionJudge {
        var isConfigured: Bool { false }
        nonisolated deinit {}
        func judge(request: String, questions: [JevClient.Question]) async throws -> [String: Double] { [:] }
    }

    private func directory() throws -> URL {
        let directory = URL.temporaryDirectory.appendingPathComponent("TaskPatchToolsTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func tools(_ task: TimedReminder, household: HouseholdStore? = nil) throws -> ButlerTools {
        let directory = try directory()
        let file = directory.appendingPathComponent("tasks.json")
        try JSONEncoder().encode([task]).write(to: file)
        let configuration = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ButlerTools(container: try ModelContainer(for: ButlerStore.schema, configurations: [configuration]),
                           notes: try LocalMemoryStore(file: directory.appendingPathComponent("notes.json")),
                           reminders: ReminderStore(file: file, schedules: false), jev: NoJudge(), household: household)
    }

    private func call(_ tools: ButlerTools, task: TimedReminder, patch: [String: Any]) async throws -> [String: Any] {
        var fields = patch
        fields["id"] = task.id.uuidString
        fields["expected_revision"] = task.revision
        let arguments = try JSONSerialization.data(withJSONObject: fields)
        let output = await tools.execute(LocalToolCall(id: UUID().uuidString, name: "propose_task_update",
                                                       arguments: String(decoding: arguments, as: UTF8.self)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

    private func patch(_ fields: [String: Any]) throws -> TaskUpdatePatch {
        try JSONDecoder().decode(TaskUpdatePatch.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func household() throws -> (HouseholdStore, UUID, UUID, UUID) {
        let owner = UUID(), first = UUID(), second = UUID()
        let store = HouseholdStore(directory: try directory())
        store.begin(HouseholdState(id: UUID(), name: "测试家庭", role: .owner, zoneName: "test", zoneOwner: "test", me: owner, joinedAt: .now),
                    me: HouseholdMember(id: owner, name: "小安", isOwner: true, joinedAt: .now))
        store.upsert(HouseholdMember(id: first, name: "小林", isOwner: false, joinedAt: .now))
        store.upsert(HouseholdMember(id: second, name: "小周", isOwner: false, joinedAt: .now))
        return (store, owner, first, second)
    }

    func testTextOnlyPatchPreservesComplexRuleIdentityFamilyAndPausedStatus() async throws {
        let start = Date.now.addingTimeInterval(86_400)
        let phase = ReminderPhase(startDate: start, intervalMinutes: 30, maxOccurrences: 4)
        var original = TimedReminder(text: "买水", fireDate: start, status: .paused,
                                     endDate: start.addingTimeInterval(86_400), phases: [phase],
                                     timeZoneIdentifier: "Asia/Shanghai")
        original.sharing = TaskSharing(scope: .household, createdBy: UUID(), assignee: UUID())
        original.syncReceived = true
        let tools = try tools(original)
        let output = try await call(tools, task: original, patch: ["text": "买矿泉水", "schedule": NSNull(), "family": NSNull()])
        XCTAssertNil(output["error"])
        XCTAssertEqual(output["saved"] as? Bool, false)
        XCTAssertEqual(tools.reminders.reminder(id: original.id), original)
        XCTAssertEqual(tools.pending.count, 1)
        XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✓"), true)
        let saved = try XCTUnwrap(tools.reminders.reminder(id: original.id))
        XCTAssertEqual(saved.text, "买矿泉水")
        XCTAssertEqual(saved.fireDate, original.fireDate)
        XCTAssertEqual(saved.phases, original.phases)
        XCTAssertEqual(saved.endDate, original.endDate)
        XCTAssertEqual(saved.timeZoneIdentifier, original.timeZoneIdentifier)
        XCTAssertEqual(saved.sharing, original.sharing)
        XCTAssertEqual(saved.createdAt, original.createdAt)
        XCTAssertEqual(saved.syncReceived, original.syncReceived)
        XCTAssertEqual(saved.status, .paused)
        XCTAssertEqual(saved.revision, original.revision + 1)
        XCTAssertEqual(tools.reminders.reminders.count, 1)
    }

    func testVagueDatePatchKeepsSharingAndDoesNotInventNotificationTime() async throws {
        var original = TimedReminder(text: "洗头", fireDate: .now.addingTimeInterval(86_400), status: .paused,
                                     timeZoneIdentifier: "Asia/Shanghai")
        original.sharing = TaskSharing(scope: .household, createdBy: UUID(), assignee: UUID())
        let tools = try tools(original)
        let output = try await call(tools, task: original, patch: [
            "schedule": ["time": "2099-01-02", "period": "morning", "time_zone": NSNull()]
        ])
        XCTAssertNil(output["error"])
        let proposed = try XCTUnwrap(output["task"] as? [String: Any])
        XCTAssertEqual(proposed["next_notifications"] as? [String], [])
        XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✓"), true)
        let saved = try XCTUnwrap(tools.reminders.reminder(id: original.id))
        XCTAssertEqual(saved.timePeriod, .morning)
        XCTAssertEqual(saved.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(saved.text, original.text)
        XCTAssertEqual(saved.sharing, original.sharing)
        XCTAssertEqual(saved.status, .paused)
        var preview = saved
        preview.status = .active
        XCTAssertTrue(ReminderSchedule.preview(preview).isEmpty)
    }

    func testStaleRevisionAtProposalAndConfirmationCannotOverwriteNewerTask() async throws {
        let original = TimedReminder(text: "取快递", fireDate: .now.addingTimeInterval(86_400))
        let tools = try tools(original)
        _ = try await call(tools, task: original, patch: ["text": "取包裹"])
        try tools.reminders.pause(original.id)
        let paused = try XCTUnwrap(tools.reminders.reminder(id: original.id))
        let stale = try await call(tools, task: original, patch: ["text": "买菜"])
        XCTAssertNotNil(stale["error"])
        XCTAssertEqual(tools.pending.count, 1)
        XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✗"), true)
        XCTAssertEqual(tools.reminders.reminder(id: original.id), paused)
    }

    func testInvalidMixedPatchNeverLeavesPartialProposalOrChangesExistingOne() async throws {
        let original = TimedReminder(text: "买菜", fireDate: .now.addingTimeInterval(86_400), repeats: .daily)
        let tools = try tools(original)
        _ = try await call(tools, task: original, patch: ["text": "买水果"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(tools.pending)
        let invalid = try await call(tools, task: original, patch: [
            "text": "另一个标题", "schedule": ["time": "2099-01-02", "period": "day", "time_zone": NSNull()]
        ])
        XCTAssertNotNil(invalid["error"])
        XCTAssertEqual(try encoder.encode(tools.pending), before)
        XCTAssertEqual(tools.reminders.reminder(id: original.id), original)
    }

    func testUnknownFieldsNoOpAndEndedTaskAreRejected() async throws {
        let original = TimedReminder(text: "买菜", fireDate: .now.addingTimeInterval(86_400))
        let tools = try tools(original)
        for fields: [String: Any] in [
            ["text": "买水果", "timezone": "UTC"],
            ["schedule": ["time": "2099-01-02", "period": "day", "time_zone": NSNull(), "repeat": "daily"]],
            ["family": ["assigned_to": "小林"]],
            ["family": ["assignee": [:]]],
            ["text": NSNull(), "schedule": NSNull(), "family": NSNull()],
            ["text": "   "]
        ] {
            let output = try await call(tools, task: original, patch: fields)
            XCTAssertNotNil(output["error"], String(describing: fields))
            XCTAssertTrue(tools.pending.isEmpty)
            XCTAssertEqual(tools.reminders.reminder(id: original.id), original)
        }
        try tools.reminders.complete(original.id)
        let completed = try XCTUnwrap(tools.reminders.reminder(id: original.id))
        let output = try await call(tools, task: completed, patch: ["text": "买水果"])
        XCTAssertNotNil(output["error"])
        XCTAssertTrue(tools.pending.isEmpty)
        XCTAssertEqual(tools.reminders.reminder(id: original.id), completed)
    }

    func testFamilyPartialPatchPreservesOtherChoicesAndExplicitClearWorks() throws {
        let (household, owner, first, second) = try household()
        var task = TimedReminder(text: "交水费", fireDate: .now.addingTimeInterval(86_400))
        var sharing = TaskSharing(scope: .household, createdBy: owner, assignee: first)
        sharing.notify = [owner]
        sharing.escalateTo = owner
        sharing.escalateAfter = 45
        task.sharing = sharing
        let changed = try patch(["family": ["assignee": ["value": second.uuidString]]]).applying(to: task, household: household)
        XCTAssertEqual(changed.sharing?.assignee, second)
        XCTAssertEqual(changed.sharing?.scope, sharing.scope)
        XCTAssertEqual(changed.sharing?.notify, sharing.notify)
        XCTAssertEqual(changed.sharing?.escalateTo, sharing.escalateTo)
        XCTAssertEqual(changed.sharing?.escalateAfter, sharing.escalateAfter)
        XCTAssertEqual(changed.fireDate, task.fireDate)
        let cleared = try patch(["family": ["assignee": ["value": NSNull()], "notify": [],
                                             "escalation": ["person": NSNull(), "after_minutes": NSNull()]]])
            .applying(to: changed, household: household)
        XCTAssertNil(cleared.sharing?.assignee)
        XCTAssertEqual(cleared.sharing?.notify, [])
        XCTAssertNil(cleared.sharing?.escalateTo)
        XCTAssertNil(cleared.sharing?.escalateAfter)
        XCTAssertEqual(cleared.sharing?.scope, .household)
        XCTAssertEqual(cleared.sharing?.createdBy, owner)
    }

    func testFamilyPatchRejectsSilentVisibilityExpansionAndInvalidMembers() throws {
        let (household, owner, first, _) = try household()
        var task = TimedReminder(text: "准备礼物", fireDate: .now.addingTimeInterval(86_400))
        task.sharing = TaskSharing(scope: .personal, createdBy: owner)
        let before = task
        XCTAssertThrowsError(try patch(["family": ["assignee": ["value": first.uuidString]]]).applying(to: task, household: household))
        XCTAssertThrowsError(try patch(["family": ["assignee": ["value": UUID().uuidString]]]).applying(to: task, household: household))
        XCTAssertThrowsError(try patch(["family": ["escalation": ["person": first.uuidString, "after_minutes": NSNull()]]]).applying(to: task, household: household))
        XCTAssertEqual(task, before)
        let explicit = try patch(["family": ["visibility": "people", "people": [first.uuidString],
                                              "assignee": ["value": first.uuidString]]]).applying(to: task, household: household)
        XCTAssertEqual(explicit.sharing?.scope, .people)
        XCTAssertEqual(explicit.sharing?.people, [first])
        XCTAssertEqual(explicit.sharing?.assignee, first)
    }

    func testFamilyPatchThroughToolConfirmsAndReturnsExactChoices() async throws {
        let (household, owner, first, second) = try household()
        var task = TimedReminder(text: "交水费", fireDate: .now.addingTimeInterval(86_400))
        var sharing = TaskSharing(scope: .household, createdBy: owner, assignee: first)
        sharing.notify = [owner]
        sharing.escalateTo = owner
        sharing.escalateAfter = 45
        task.sharing = sharing
        let tools = try tools(task, household: household)
        let output = try await call(tools, task: task, patch: ["family": ["assignee": ["value": second.uuidString]]])
        XCTAssertNil(output["error"])
        XCTAssertEqual(tools.reminders.reminder(id: task.id), task)
        let proposal = try XCTUnwrap(output["task"] as? [String: Any])
        let family = try XCTUnwrap(proposal["family"] as? [String: Any])
        XCTAssertEqual(family["visibility"] as? String, "household")
        XCTAssertEqual(family["assignee_id"] as? String, second.uuidString)
        XCTAssertEqual(family["notify"] as? [String], [owner.uuidString])
        XCTAssertEqual((family["escalation"] as? [String: Any])?["after_minutes"] as? Int, 45)
        XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✓"), true)
        let saved = try XCTUnwrap(tools.reminders.reminder(id: task.id))
        XCTAssertEqual(saved.sharing?.assignee, second)
        XCTAssertEqual(saved.sharing?.notify, sharing.notify)
        XCTAssertEqual(saved.sharing?.escalateTo, sharing.escalateTo)
        XCTAssertEqual(saved.sharing?.escalateAfter, sharing.escalateAfter)
        XCTAssertEqual(saved.text, task.text)
        XCTAssertEqual(saved.fireDate, task.fireDate)
    }

    func testConflictingFamilyAndTextCorrectionIsAtomicThroughTool() async throws {
        let (household, owner, first, _) = try household()
        var task = TimedReminder(text: "准备礼物", fireDate: .now.addingTimeInterval(86_400))
        task.sharing = TaskSharing(scope: .personal, createdBy: owner)
        let tools = try tools(task, household: household)
        let output = try await call(tools, task: task, patch: [
            "text": "准备惊喜", "family": ["assignee": ["value": first.uuidString]]
        ])
        XCTAssertNotNil(output["error"])
        XCTAssertTrue(tools.pending.isEmpty)
        XCTAssertEqual(tools.reminders.reminder(id: task.id), task)
    }

    func testLeavingHouseholdAfterProposalBlocksFamilyWriteButNotUnchangedSharing() async throws {
        let (household, owner, first, second) = try household()
        var task = TimedReminder(text: "交水费", fireDate: .now.addingTimeInterval(86_400))
        task.sharing = TaskSharing(scope: .household, createdBy: owner, assignee: first)
        let tools = try tools(task, household: household)
        _ = try await call(tools, task: task, patch: ["family": ["assignee": ["value": second.uuidString]]])
        household.end()
        XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✗"), true)
        XCTAssertEqual(tools.reminders.reminder(id: task.id), task)
        _ = try await call(tools, task: task, patch: ["text": "缴纳水费"])
        XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✓"), true)
        XCTAssertEqual(tools.reminders.reminder(id: task.id)?.text, "缴纳水费")
        XCTAssertEqual(tools.reminders.reminder(id: task.id)?.sharing, task.sharing)
    }

    func testRemovingRecipientAfterProposalBlocksWriteWithoutChangingTask() async throws {
        let (household, owner, first, second) = try household()
        var task = TimedReminder(text: "交水费", fireDate: .now.addingTimeInterval(86_400))
        task.sharing = TaskSharing(scope: .household, createdBy: owner, assignee: first)
        let tools = try tools(task, household: household)
        _ = try await call(tools, task: task, patch: ["text": "缴纳水费", "family": ["assignee": ["value": second.uuidString]]])
        household.removeMember(second)
        XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✗"), true)
        XCTAssertEqual(tools.reminders.reminder(id: task.id), task)
    }

    func testNewReminderCannotKeepAnotherCreatorsFamilyProposal() throws {
        let (household, owner, first, _) = try household()
        let existing = TimedReminder(text: "原任务", fireDate: .now.addingTimeInterval(86_400))
        let tools = try tools(existing, household: household)
        var proposed = TimedReminder(text: "错误家庭", fireDate: .now.addingTimeInterval(86_400))
        proposed.sharing = TaskSharing(scope: .personal, createdBy: first)
        tools.proposeReminder(proposed)
        XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✗"), true)
        XCTAssertNil(tools.reminders.reminder(id: proposed.id))
        proposed.sharing = TaskSharing(scope: .household, createdBy: owner, assignee: first)
        tools.proposeReminder(proposed)
        household.end()
        XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✗"), true)
        XCTAssertNil(tools.reminders.reminder(id: proposed.id))
    }

    func testParticipantCanEditTaskSharedOnlyWithThemWithoutChangingVisibility() throws {
        let (household, owner, first, _) = try household()
        let state = try XCTUnwrap(household.state)
        household.begin(HouseholdState(id: state.id, name: state.name, role: .member,
                                        zoneName: state.zoneName, zoneOwner: state.zoneOwner, me: first, joinedAt: .now),
                        me: HouseholdMember(id: first, name: "小林", isOwner: false, joinedAt: .now))
        household.upsert(HouseholdMember(id: owner, name: "小安", isOwner: true, joinedAt: .now))
        var task = TimedReminder(text: "缴费", fireDate: .now.addingTimeInterval(86_400))
        var sharing = TaskSharing(scope: .people, createdBy: owner)
        sharing.people = [first]
        task.sharing = sharing
        let changed = try patch(["family": ["escalation": ["person": first.uuidString, "after_minutes": 30]]])
            .applying(to: task, household: household)
        XCTAssertEqual(changed.sharing?.createdBy, owner)
        XCTAssertEqual(changed.sharing?.people, sharing.people)
        XCTAssertEqual(changed.sharing?.scope, .people)
        XCTAssertEqual(changed.sharing?.escalateTo, first)
    }
}
