#if DEBUG
import Foundation
import XCTest
@testable import Butler

@MainActor
final class AgentScenarioTests: XCTestCase {
    /// Uses the phone's actual tool loop, proposals, confirmation and stores. The model is scripted:
    /// a pass establishes execution/checker correctness, not natural-language understanding quality.
    func testScriptedMobileScenariosCheckActualStateAcrossTurns() async throws {
        for scenario in AgentScenario.all {
            let runner = try AgentScenarioRunner()
            defer { runner.clean() }
            let notifications = ScenarioNotificationCounter()
            let observer = NotificationCenter.default.addObserver(forName: .init("butlerBriefSourcesChanged"),
                object: nil, queue: nil) { _ in notifications.increment() }
            defer { NotificationCenter.default.removeObserver(observer) }
            let model = ScenarioScript(steps: try script(scenario, runner: runner))
            let report = try await runner.run(scenario) { context in
                XCTAssertTrue(context.toolsJSON.contains("revise_pending_change"))
                XCTAssertFalse(context.toolsJSON.contains("propose_nudge"))
                return model
            }
            let exported = String(decoding: try report.export(), as: UTF8.self)
            XCTAssertTrue(report.passed, exported)
            XCTAssertEqual(model.remaining, 0, scenario.id)
            XCTAssertEqual(report.steps.reduce(0) { $0 + $1.modelRounds }, model.requests)
            XCTAssertTrue(report.steps.allSatisfy { $0.blockedTools.isEmpty })
            XCTAssertNotNil(report.steps.first?.firstActionableSeconds)
            XCTAssertEqual(notifications.value, 0, "The isolated evaluation must not wake production brief/widget observers")
            let path = runner.directory
            runner.clean()
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        }
    }

    func testCheckerRejectsWrongBatchAdditionalTaskAndChangedFamily() async throws {
        let runner = try AgentScenarioRunner()
        defer { runner.clean() }
        let inventory = AgentScenario.all.first { $0.id == "inventory-correction" }!
        _ = await runner.tools.execute(try Self.call("propose_set_quantity", ["lot_id": AgentScenario.frozen.uuidString, "quantity": 5]))
        let proposed = try runner.checks(inventory.steps[1].expected, previousProposalIDs: runner.tools.pending.map(\.id))
        XCTAssertFalse(try XCTUnwrap(proposed["pending_matches"]))
        _ = await runner.tools.confirmResults()
        let saved = try runner.checks(inventory.steps.last!.expected, previousProposalIDs: [])
        XCTAssertFalse(try XCTUnwrap(saved["inventory_exactly_matches_expected_batches"]))

        var changed = try XCTUnwrap(runner.tools.reminders.reminder(id: AgentScenario.sharedTask))
        changed.sharing?.notify = [AgentScenario.lin]
        try runner.tools.reminders.update(changed)
        let unchanged = try runner.checks(.init(), previousProposalIDs: [])
        XCTAssertFalse(try XCTUnwrap(unchanged["saved_tasks_unchanged"]))
        let extra = TimedReminder(text: "未经要求的购买", fireDate: AgentScenarioRunner.day(1, from: runner.now))
        try runner.tools.reminders.add(extra)
        XCTAssertFalse(try XCTUnwrap(runner.checks(.init(), previousProposalIDs: [])["saved_tasks_unchanged"]))
    }

    func testClaimingSuccessWithoutProposalCannotPass() async throws {
        let runner = try AgentScenarioRunner()
        defer { runner.clean() }
        let scenario = AgentScenario.all[1]
        let report = try await runner.run(scenario) { _ in
            ScenarioScript(steps: [Self.answer, Self.answer])
        }
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.steps[0].checks["pending_matches"], false)
        XCTAssertEqual(report.steps[2].checks["confirmation_has_successful_receipt"], false)
        XCTAssertEqual(report.steps[2].checks["inventory_exactly_matches_expected_batches"], false)
    }

    func testUnisolatedToolsAreBlockedBeforeExecutionAndLiveUsageRequiresOptIn() async throws {
        let runner = try AgentScenarioRunner()
        defer { runner.clean() }
        var createdModel = false
        do {
            _ = try await runner.run(AgentScenario.all[0], mode: .liveModel) { _ in
                createdModel = true
                return ScenarioScript(steps: [])
            }
            XCTFail("Live evaluation must not start without explicit authorization")
        } catch AgentScenarioRunner.Failure.liveModelNotAuthorized { }
        XCTAssertFalse(createdModel)
        let scenario = AgentScenario(id: "unisolated-tool-counterexample", title: "禁止访问系统和真实家庭", steps: [
            .init(input: .say("这是合成评估"), expected: .init())
        ])
        let report = try await runner.run(scenario) { _ in
            ScenarioScript(steps: [
                { _ in .init(text: "", calls: [try Self.call("propose_nudge", ["id": AgentScenario.sharedTask.uuidString]),
                                                try Self.call("get_health_data", [:]),
                                                try Self.call("propose_current_travel_place", [:])]) },
                Self.answer
            ])
        }
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.steps[0].blockedTools, ["propose_nudge", "get_health_data", "propose_current_travel_place"])
        XCTAssertTrue(report.steps[0].checks.values.allSatisfy { $0 })
        XCTAssertTrue(runner.tools.pending.isEmpty)
    }

    func testRoundLimitAndExportDoNotClaimSuccessfulUnderstanding() async throws {
        let runner = try AgentScenarioRunner()
        defer { runner.clean() }
        let loop = ScenarioScript(steps: Array(repeating: { _ in
            .init(text: "", calls: [try Self.call("get_pending_changes", [:])])
        }, count: 8))
        let report = try await runner.run(AgentScenario.all[0]) { _ in loop }
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.steps.count, 1)
        XCTAssertEqual(report.steps[0].modelRounds, 8)
        XCTAssertNotNil(report.steps[0].error)
        let exported = String(decoding: try report.export(), as: UTF8.self)
        XCTAssertTrue(exported.contains("scripted"))
        XCTAssertFalse(exported.contains("wireOutput"))
    }

    private static func call(_ name: String, _ args: [String: Any]) throws -> LocalToolCall {
        .init(id: UUID().uuidString, name: name,
              arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self))
    }
    private static let answer: ScenarioScript.Step = { _ in .init(text: "已准备好。", calls: []) }
    private func scriptedCall(_ name: String, _ args: [String: Any]) -> ScenarioScript.Step {
        { _ in .init(text: "", calls: [try Self.call(name, args)]) }
    }
    private func revise(_ patch: [String: Any], key: String) -> ScenarioScript.Step {
        { messages in
            let outputs = messages.compactMap { message -> String? in
                if case .tool(_, let output) = message { return output }; return nil
            }
            let latest = try XCTUnwrap(outputs.last)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(latest.utf8)) as? [String: Any])
            let changes = try XCTUnwrap(object["changes"] as? [[String: Any]])
            let change = try XCTUnwrap(changes.first)
            return .init(text: "", calls: [try Self.call("revise_pending_change", [
                "proposal_id": try XCTUnwrap(change["id"] as? String),
                "expected_fingerprint": try XCTUnwrap(change["fingerprint"] as? String),
                "task_patch": key == "task_patch" ? patch : NSNull(),
                "item_patch": key == "item_patch" ? patch : NSNull()
            ])])
        }
    }
    private func script(_ scenario: AgentScenario, runner: AgentScenarioRunner) throws -> [ScenarioScript.Step] {
        func schedule(_ day: Int, _ period: String) -> [String: Any] {
            ["time": runner.dateText(day), "period": period, "time_zone": TimeZone.current.identifier]
        }
        func update(_ revision: Int, text: String? = nil, schedule: [String: Any]? = nil, family: [String: Any]? = nil) -> ScenarioScript.Step {
            scriptedCall("propose_task_update", ["id": AgentScenario.sharedTask.uuidString,
                "expected_revision": revision, "text": text as Any? ?? NSNull(),
                "schedule": schedule as Any? ?? NSNull(), "family": family as Any? ?? NSNull()])
        }
        let readTask = scriptedCall("get_tasks", ["id": AgentScenario.sharedTask.uuidString])
        switch scenario.id {
        case "fuzzy-time-correction": return [
            scriptedCall("propose_reminder", ["text": "买面包", "time": runner.dateText(1), "period": "afternoon", "repeat": "none", "family": NSNull()]),
            Self.answer,
            scriptedCall("get_pending_changes", [:]),
            revise(["text": NSNull(), "schedule": schedule(2, "afternoon"), "family": NSNull()], key: "task_patch"),
            Self.answer
        ]
        case "inventory-correction": return [
            scriptedCall("search_inventory", ["query": "牛奶", "include_finished": false]),
            scriptedCall("propose_set_quantity", ["lot_id": AgentScenario.cold.uuidString, "quantity": 2]),
            Self.answer,
            scriptedCall("get_pending_changes", [:]),
            revise(["quantity": 5, "name": NSNull(), "unit": NSNull(), "storage": NSNull()], key: "item_patch"),
            Self.answer
        ]
        case "saved-task-partial-update": return [
            readTask, update(1, schedule: schedule(2, "day")), Self.answer,
            readTask, update(2, text: "买面包"), Self.answer
        ]
        case "family-assignee-only": return [
            readTask, update(1, family: ["assignee": ["value": AgentScenario.lin.uuidString]]), Self.answer
        ]
        case "permission-denied": return [scriptedCall("propose_travel_access", ["allowed": true]), Self.answer, Self.answer]
        case "permission-granted-boundary": return [scriptedCall("propose_travel_access", ["allowed": true]), Self.answer,
            scriptedCall("get_saved_places", [:]), Self.answer]
        default: throw AgentScenarioRunner.Failure.roundsExceeded
        }
    }
}

private final class ScenarioNotificationCounter: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var count = 0
    nonisolated func increment() { lock.withLock { count += 1 } }
    nonisolated var value: Int { lock.withLock { count } }
}

@MainActor private final class ScenarioScript: LocalAgentModel {
    typealias Step = ([LocalAgentMessage]) throws -> LocalModelReply
    private var steps: [Step]
    private(set) var requests = 0
    var remaining: Int { steps.count }
    init(steps: [Step]) { self.steps = steps }
    nonisolated deinit {}
    func reply(to messages: [LocalAgentMessage]) async throws -> LocalModelReply {
        requests += 1
        guard !steps.isEmpty else { throw AgentScenarioRunner.Failure.roundsExceeded }
        return try steps.removeFirst()(messages)
    }
}
#endif
