import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor final class WebPageToolsTests: XCTestCase {
    func testReadRequiresSoleConfirmationAndCannotReplay() async throws {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "web-tools-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: dir); defaults.removePersistentDomain(forName: suite) }
        let config = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ButlerStore.schema, configurations: [config])
        let chat = ButlerChat(container: container,
            reminders: ReminderStore(file: dir.appendingPathComponent("tasks.json"), schedules: false),
            connection: SubscriptionConnection(keychainAccount: suite), directory: dir, defaults: defaults)
        defer { withExtendedLifetime(chat) {} }
        let tools = try XCTUnwrap(chat.tools), network = FakeWebPageTransport()
        tools.webPageReader = WebPageReader(transport: network)
        for id in ["first", "duplicate"] {
            _ = await tools.execute(.init(id: id, name: "propose_read_webpage", arguments: #"{"url":"https://example.com/event"}"#))
        }
        XCTAssertEqual(tools.pending.count, 1); XCTAssertTrue(network.urls.isEmpty)
        let proposal = try XCTUnwrap(tools.pending.first)
        XCTAssertTrue(proposal.requiresAsyncConfirmation); XCTAssertTrue(proposal.requiresSoleConfirmation)
        XCTAssertFalse(proposal.persists); XCTAssertTrue(tools.confirmAll().isEmpty)
        tools.add(.note(.init(id: UUID(), title: "保留原笔记提案", text: "原内容", quantity: nil, revision: 1)), title: "笔记", detail: nil)
        let blocked = await tools.confirmIncludingSystemChanges()
        XCTAssertTrue(blocked.joined().contains("单独确认")); XCTAssertTrue(network.urls.isEmpty)
        let receipt = await tools.confirmIncludingSystemChanges(ids: [proposal.id])
        XCTAssertEqual(network.urls.count, 1); XCTAssertTrue(receipt.joined().contains("公开活动"))
        XCTAssertEqual(tools.pending.count, 1); XCTAssertTrue(tools.notes.records.isEmpty)
        _ = await tools.confirmIncludingSystemChanges(ids: [proposal.id])
        XCTAssertEqual(network.urls.count, 1)
        _ = await tools.execute(.init(id: "local", name: "propose_read_webpage", arguments: #"{"url":"https://127.0.0.1"}"#))
        XCTAssertEqual(tools.pending.count, 1); XCTAssertEqual(network.urls.count, 1)
        _ = await tools.execute(.init(id: "next", name: "propose_read_webpage", arguments: #"{"url":"https://example.com/next"}"#))
        let next = try XCTUnwrap(tools.pending.last)
        tools.removePending(next.id)
        _ = await tools.confirmIncludingSystemChanges(ids: [next.id])
        XCTAssertEqual(network.urls.count, 1)
    }
}
