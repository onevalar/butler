import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor final class SyncToolsTests: XCTestCase {
    func testSyncConsentIsExplicitSoleAndNotPersisted() async throws {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "sync-tools-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: dir); defaults.removePersistentDomain(forName: suite) }
        let config = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ButlerStore.schema, configurations: [config])
        let chat = ButlerChat(container: container,
            reminders: ReminderStore(file: dir.appendingPathComponent("tasks.json"), schedules: false),
            connection: SubscriptionConnection(keychainAccount: suite), directory: dir, defaults: defaults)
        defer { withExtendedLifetime(chat) {} }
        let tools = try XCTUnwrap(chat.tools), cloud = FakeSyncCloud()
        let store = SyncStore(file: dir.appendingPathComponent("sync.json"), local: FakeSyncData(), transport: cloud)
        tools.synchronization = store
        let chatCloud = FakeSyncCloud()
        let chatStore = SyncStore(file: dir.appendingPathComponent("chat-sync.json"), local: FakeSyncData(), transport: chatCloud, kinds: [.chat])
        tools.chatSynchronization = chatStore
        let photoCloud = FakeSyncCloud()
        let photoStore = SyncStore(file: dir.appendingPathComponent("photo-sync.json"), local: FakeSyncData(), transport: photoCloud, kinds: [.itemPhoto, .chatPhoto])
        tools.photoSynchronization = photoStore
        _ = await tools.execute(.init(id: "status", name: "get_sync_status", arguments: "{}"))
        _ = await tools.execute(.init(id: "enable", name: "propose_sync_enabled", arguments: #"{"enabled":true}"#))
        _ = await tools.execute(.init(id: "duplicate", name: "propose_sync_enabled", arguments: #"{"enabled":true}"#))
        XCTAssertEqual(tools.pending.count, 1); XCTAssertEqual(cloud.requests, 0)
        let proposal = try XCTUnwrap(tools.pending.first)
        XCTAssertFalse(proposal.persists); XCTAssertTrue(proposal.requiresSoleConfirmation)
        XCTAssertTrue(tools.confirmAll().isEmpty); XCTAssertFalse(store.enabled)
        tools.add(.note(.init(id: UUID(), title: "普通笔记", text: "独立保存", quantity: nil, revision: 1)), title: "笔记", detail: nil)
        let mixed = await tools.confirmIncludingSystemChanges()
        XCTAssertTrue(mixed.joined().contains("单独确认")); XCTAssertFalse(store.enabled)
        _ = await tools.confirmIncludingSystemChanges(ids: [proposal.id])
        XCTAssertTrue(store.enabled); XCTAssertTrue(cloud.records.isEmpty)
        XCTAssertEqual(tools.pending.count, 1)
        XCTAssertFalse(chatStore.enabled); XCTAssertEqual(chatCloud.requests, 0)
        _ = await tools.execute(.init(id: "chats", name: "propose_chat_sync_enabled", arguments: #"{"enabled":true}"#))
        _ = await tools.execute(.init(id: "chats-duplicate", name: "propose_chat_sync_enabled", arguments: #"{"enabled":true}"#))
        XCTAssertEqual(tools.pending.count, 2); XCTAssertEqual(chatCloud.requests, 0)
        let chatProposal = try XCTUnwrap(tools.pending.last)
        XCTAssertFalse(chatProposal.persists); XCTAssertTrue(chatProposal.requiresSoleConfirmation)
        _ = await tools.confirmIncludingSystemChanges(ids: [chatProposal.id])
        XCTAssertTrue(chatStore.enabled); XCTAssertTrue(chatCloud.records.isEmpty)
        XCTAssertFalse(photoStore.enabled); XCTAssertEqual(photoCloud.requests, 0)
        _ = await tools.execute(.init(id: "photos", name: "propose_photo_sync_enabled", arguments: #"{"enabled":true}"#))
        let photoProposal = try XCTUnwrap(tools.pending.last)
        XCTAssertFalse(photoProposal.persists); XCTAssertTrue(photoProposal.requiresSoleConfirmation)
        XCTAssertEqual(photoCloud.requests, 0)
        _ = await tools.confirmIncludingSystemChanges(ids: [photoProposal.id])
        XCTAssertTrue(photoStore.enabled); XCTAssertTrue(photoCloud.records.isEmpty)
        _ = await tools.execute(.init(id: "off", name: "propose_sync_enabled", arguments: #"{"enabled":false}"#))
        _ = await tools.confirmIncludingSystemChanges(ids: [try XCTUnwrap(tools.pending.last?.id)])
        XCTAssertFalse(store.enabled); XCTAssertFalse(chatStore.enabled); XCTAssertFalse(photoStore.enabled)
        _ = await tools.execute(.init(id: "again", name: "propose_sync_enabled", arguments: #"{"enabled":true}"#))
        _ = await tools.confirmIncludingSystemChanges(ids: [try XCTUnwrap(tools.pending.last?.id)])
        XCTAssertTrue(store.enabled); XCTAssertFalse(chatStore.enabled); XCTAssertFalse(photoStore.enabled)
        _ = await tools.execute(.init(id: "clean", name: "propose_sync_cleanup", arguments: #"{"scope":"content","mode":"everything"}"#))
        let cleanup = try XCTUnwrap(tools.pending.last)
        XCTAssertTrue(cleanup.requiresSoleConfirmation); XCTAssertFalse(cleanup.persists)
        XCTAssertNil(cloud.cloudHead.epoch)
        _ = await tools.confirmIncludingSystemChanges(ids: [cleanup.id])
        XCTAssertNotNil(cloud.cloudHead.epoch); XCTAssertTrue(store.needsReconnect)
        _ = await tools.execute(.init(id: "reconnect", name: "propose_sync_reconnect", arguments: #"{"scope":"content"}"#))
        let reconnect = try XCTUnwrap(tools.pending.last)
        XCTAssertTrue(reconnect.requiresSoleConfirmation); XCTAssertFalse(store.enabled)
        _ = await tools.confirmIncludingSystemChanges(ids: [reconnect.id])
        XCTAssertTrue(store.enabled); XCTAssertFalse(chatStore.enabled); XCTAssertFalse(photoStore.enabled)
    }
}
