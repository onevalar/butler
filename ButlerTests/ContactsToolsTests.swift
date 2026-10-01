import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor final class ContactsToolsTests: XCTestCase {
    private func setup() throws -> (ButlerChat, ButlerTools, FakeContactsDevice, URL) {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "contacts-tools-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { try? FileManager.default.removeItem(at: dir); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let config = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ButlerStore.schema, configurations: [config])
        let chat = ButlerChat(container: container,
            reminders: ReminderStore(file: dir.appendingPathComponent("reminders.json"), schedules: false),
            connection: SubscriptionConnection(keychainAccount: suite), directory: dir, defaults: defaults)
        let tools = try XCTUnwrap(chat.tools), device = FakeContactsDevice()
        tools.contacts = ContactsStore(file: dir.appendingPathComponent("contacts.json"), device: device)
        return (chat, tools, device, dir)
    }
    private func call(_ tools: ButlerTools, _ name: String, _ args: [String: Any] = [:]) async throws -> String {
        await tools.execute(LocalToolCall(id: UUID().uuidString, name: name,
            arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)))
    }
    func testNoImplicitAccessAndDeniedPermissionDoesNotBlockNotes() async throws {
        let (chat, tools, device, dir) = try setup(); defer { withExtendedLifetime(chat) {} }
        XCTAssertTrue(tools.toolJSON.contains("propose_contacts_access"))
        _ = try await call(tools, "get_contacts_capabilities")
        XCTAssertEqual(device.grants, 0); XCTAssertEqual(device.searches, 0)
        _ = try await call(tools, "propose_contacts_access", ["allowed": true])
        _ = try await call(tools, "propose_contacts_access", ["allowed": true])
        XCTAssertEqual(tools.pending.count, 1); XCTAssertEqual(device.grants, 0)
        XCTAssertTrue(tools.confirmAll().isEmpty)
        let disk = try JSONDecoder().decode([PendingChange].self, from: Data(contentsOf: dir.appendingPathComponent("pending-changes.json")))
        XCTAssertTrue(disk.isEmpty)
        device.grant = .denied
        let receipt = await tools.confirmIncludingSystemChanges()
        XCTAssertTrue(receipt.joined().contains("✗"))
        let note = LocalMemory(id: UUID(), title: "普通笔记", text: "不依赖通讯录", quantity: nil, revision: 1)
        tools.add(.note(note), title: note.title, detail: nil)
        XCTAssertTrue(tools.confirmAll().joined().contains("✓"))
        XCTAssertTrue(tools.notes.records.contains { $0.id == note.id })
        XCTAssertEqual(device.searches, 0); XCTAssertEqual(device.writes, 0)
    }
    func testSearchAndReadProposalDoNotLeakDetailsUntilConfirmation() async throws {
        let (chat, tools, device, _) = try setup(); defer { withExtendedLifetime(chat) {} }
        device.people["id"] = .init(givenName: "敏", familyName: "李", organization: "单位", phones: [.init(label: nil, value: "PHONE-PRIVATE-729")], emails: [])
        _ = try await tools.contacts.apply(.access(true), operationID: UUID())
        let found = try await call(tools, "search_contacts", ["name": "李"])
        XCTAssertFalse(found.contains("PHONE-PRIVATE-729"))
        _ = try await call(tools, "propose_contact_read", ["id": "id", "field": "phones"])
        _ = try await call(tools, "propose_contact_read", ["id": "id", "field": "phones"])
        XCTAssertEqual(tools.pending.count, 1)
        XCTAssertTrue(device.reads.isEmpty)
        XCTAssertFalse(tools.pendingContext.contains("PHONE-PRIVATE-729"))
        let result = await tools.confirmIncludingSystemChanges()
        XCTAssertTrue(result.joined().contains("PHONE-PRIVATE-729"))
        XCTAssertEqual(device.reads, [.phones]); XCTAssertEqual(device.writes, 0)
        _ = await tools.confirmIncludingSystemChanges()
        XCTAssertEqual(device.reads, [.phones])
    }
    func testToolSchemasAreStrictIncludingNestedValues() throws {
        let schemas = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("[\(ButlerTools.contactsTools)]".utf8)) as? [[String: Any]])
        XCTAssertEqual(schemas.count, 8)
        func check(_ object: [String: Any]) {
            if object["type"] as? String == "object" {
                XCTAssertEqual(object["additionalProperties"] as? Bool, false)
                XCTAssertEqual(Set(object["required"] as? [String] ?? []), Set((object["properties"] as? [String: Any] ?? [:]).keys))
            }
            for value in object.values { if let nested = value as? [String: Any] { check(nested) } }
        }
        for schema in schemas { XCTAssertEqual(schema["strict"] as? Bool, true); check(schema) }
    }
}
