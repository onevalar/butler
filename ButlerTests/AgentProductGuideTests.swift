import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor
final class AgentProductGuideTests: XCTestCase {
    private func fixture() throws -> (ButlerTools, ProductGuideJudge) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("product-guide-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let judge = ProductGuideJudge()
        let tools = ButlerTools(container: try ButlerStore.makePreviewContainer(),
                                notes: try LocalMemoryStore(file: root.appendingPathComponent("notes.json")),
                                reminders: ReminderStore(file: root.appendingPathComponent("tasks.json"), schedules: false, publishesChanges: false),
                                jev: judge, household: HouseholdStore(directory: root.appendingPathComponent("household")),
                                publishesChanges: false)
        return (tools, judge)
    }

    private func guide(_ tools: ButlerTools, _ topic: String) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["topic": topic])
        let result = await tools.execute(.init(id: UUID().uuidString, name: "get_product_guide", arguments: String(decoding: data, as: UTF8.self)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
    }

    func testDirectoryCoversEveryAdvertisedToolOnceAndReflectsOptionalJev() async throws {
        let (tools, judge) = try fixture()
        let advertised = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tools.toolJSON.utf8)) as? [[String: Any]])
        let names = advertised.compactMap { $0["name"] as? String }
        XCTAssertEqual(names.count, Set(names).count)
        var indexed: [String] = []
        for topic in AgentProductGuide.Topic.allCases where topic != .overview {
            let result = try await guide(tools, topic.rawValue)
            let entries = try XCTUnwrap(result["tools"] as? [[String: String]])
            indexed += entries.compactMap { $0["name"] }
            for entry in entries {
                XCTAssertEqual(entry["description"], advertised.first { $0["name"] as? String == entry["name"] }?["description"] as? String)
            }
        }
        XCTAssertEqual(indexed.sorted(), names.sorted())
        let overview = try await guide(tools, "overview")
        XCTAssertEqual(overview["tool_count"] as? Int, names.count)
        XCTAssertEqual(overview["permission_status"] as? String, "not_checked")
        XCTAssertFalse(indexed.contains("judge_with_jev"))
        judge.enabled = true
        let updated = try await guide(tools, "conversation")
        XCTAssertTrue((updated["tools"] as? [[String: String]] ?? []).contains { $0["name"] == "judge_with_jev" })
        XCTAssertEqual(judge.calls, 0, "Discovering an optional tool must not invoke its provider")
    }

    func testProductGuideDoesNotReadPersonalContextOrCreateAProposal() async throws {
        let (tools, _) = try fixture()
        var reads = 0
        tools.currentContext = { reads += 1; return #"{"private_note":"fixture-secret"}"# }
        tools.proposeReminder(TimedReminder(text: "fixture-secret", fireDate: .now.addingTimeInterval(86400)))
        let before = try XCTUnwrap(tools.pending.first).editFingerprint
        for topic in AgentProductGuide.Topic.allCases {
            let result = try await guide(tools, topic.rawValue)
            XCTAssertFalse(String(describing: result).contains("fixture-secret"))
            XCTAssertEqual(result["read_only"] as? Bool, true)
        }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(try tools.pending.first?.editFingerprint, before)
        XCTAssertTrue(tools.reminders.reminders.isEmpty)
        XCTAssertFalse(tools.travel.allowed)
    }

    func testInvalidTopicAndUnexpectedArgumentsAreRejectedWithoutSideEffects() async throws {
        let (tools, _) = try fixture()
        let invalid = try await guide(tools, "delete_everything")
        XCTAssertNotNil(invalid["error"])
        let result = await tools.execute(.init(id: "bad", name: "get_product_guide",
            arguments: #"{"topic":"overview","authorize":true}"#))
        XCTAssertTrue(result.contains("error"))
        XCTAssertTrue(tools.pending.isEmpty)
        XCTAssertTrue(tools.reminders.reminders.isEmpty)
    }

    func testProductClassificationKeepsProfilesAndSystemRemindersInTheirOwnDomains() {
        XCTAssertEqual(AgentProductGuide.topic(forTool: "propose_item_profile"), .inventory)
        XCTAssertEqual(AgentProductGuide.topic(forTool: "get_apple_reminders"), .appleReminders)
        XCTAssertEqual(AgentProductGuide.topic(forTool: "propose_task_update"), .arrangements)
        XCTAssertEqual(AgentProductGuide.topic(forTool: "propose_item_sharing"), .household)
        XCTAssertEqual(AgentProductGuide.topic(forTool: "propose_export_text_file"), .files)
        XCTAssertEqual(AgentProductGuide.topic(forTool: "search_weather_places"), .weather)
    }
}

@MainActor private final class ProductGuideJudge: ConditionJudge {
    var enabled = false
    var calls = 0
    var isConfigured: Bool { true }
    var isEnabled: Bool { enabled }
    nonisolated deinit {}
    func judge(request: String, questions: [JevClient.Question]) async throws -> [String: Double] {
        calls += 1
        return [:]
    }
}
