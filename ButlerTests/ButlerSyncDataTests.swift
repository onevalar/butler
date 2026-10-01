import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor final class ButlerSyncDataTests: XCTestCase {
    private func make() throws -> ButlerSyncData {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let config = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ButlerSyncData(container: try ModelContainer(for: ButlerStore.schema, configurations: [config]),
            notes: try LocalMemoryStore(file: dir.appendingPathComponent("notes.json")),
            tasks: ReminderStore(file: dir.appendingPathComponent("tasks.json"), schedules: false),
            revisionFile: dir.appendingPathComponent("revision.json"))
    }
    func testInventoryRoundTripPreservesIDsAndOmitsPhotosAndLocalRevisions() throws {
        let a = try make(), b = try make(), context = ModelContext(a.container)
        let product = CatalogProduct(canonicalName: "牛奶", brand: "测试", revision: 37)
        let lot = InventoryLot(productID: product.id, quantity: 7, unit: "盒", storageLocation: "冰箱", revision: 43)
        var profile = ItemProfile(category: .food); profile.photo = Data("private-photo-761".utf8); profile.tags = ["早餐"]
        lot.profileData = try JSONEncoder().encode(profile)
        context.insert(product); context.insert(lot); try context.save()
        let key = SyncRecord.Key(kind: .inventory, id: product.id), original = try XCTUnwrap(a.snapshot()[key])
        let portable = try JSONDecoder().decode(ButlerSyncData.Inventory.self, from: original)
        XCTAssertEqual(portable.product.revision, 0); XCTAssertEqual(portable.lots[0].revision, 0)
        let portableProfile = try JSONDecoder().decode(ItemProfile.self, from: XCTUnwrap(portable.lots[0].profileData))
        XCTAssertNil(portableProfile.photo); XCTAssertEqual(portableProfile.tags, ["早餐"])
        try b.replace(key, expected: nil, with: original)
        XCTAssertEqual(try b.snapshot()[key], original)
        let target = try ModelContext(b.container).fetch(FetchDescriptor<InventoryLot>())[0]
        XCTAssertEqual(target.id, lot.id); XCTAssertEqual(target.quantity, 7); XCTAssertEqual(target.storageLocation, "冰箱")
        XCTAssertEqual(try JSONDecoder().decode(ItemProfile.self, from: XCTUnwrap(lot.profileData)).photo, profile.photo)
    }
    func testTaskReceiptDoesNotAcquireNotificationOwnershipAndSurvivesEditing() throws {
        let a = try make(), b = try make()
        let task = TimedReminder(text: "明天交材料", fireDate: .now.addingTimeInterval(3600))
        try a.tasks.add(task)
        let key = SyncRecord.Key(kind: .task, id: task.id), data = try XCTUnwrap(a.snapshot()[key])
        try b.replace(key, expected: nil, with: data)
        XCTAssertEqual(b.tasks.reminder(id: task.id)?.syncReceived, true)
        XCTAssertEqual(try b.snapshot()[key], data)
        b.tasks.reload()
        var received = try XCTUnwrap(b.tasks.reminder(id: task.id)); received.text = "改内容"
        try b.tasks.update(received)
        XCTAssertEqual(b.tasks.reminder(id: task.id)?.syncReceived, true)
        let remoteEdit = try XCTUnwrap(b.snapshot()[key])
        try a.replace(key, expected: data, with: remoteEdit)
        XCTAssertNotEqual(a.tasks.reminder(id: task.id)?.syncReceived, true)
        XCTAssertEqual(a.tasks.reminder(id: task.id)?.text, "改内容")
    }
    func testStaleImportRefusesAndLocalRevisionsIncreaseAcrossDeleteAndResurrection() throws {
        let source = try make(), id = UUID(), key = SyncRecord.Key(kind: .note, id: id)
        let first = LocalMemory(id: id, title: "偏好", text: "不辣", quantity: nil, revision: 0)
        let data = try SyncRecord.encode(first)
        try source.replace(key, expected: nil, with: data)
        let before = try XCTUnwrap(source.notes.records.first)
        var edited = before; edited.revision += 1; edited.text = "微辣"; try source.notes.upsert(edited)
        XCTAssertThrowsError(try source.replace(key, expected: data, with: nil))
        try source.replace(key, expected: source.snapshot()[key], with: nil)
        try source.replace(key, expected: nil, with: data)
        XCTAssertGreaterThan(try XCTUnwrap(source.notes.records.first?.revision), edited.revision)
        XCTAssertThrowsError(try source.notes.upsert(edited))
    }
    func testRemovingRemoteProfileRetainsLocalPhotoWithoutSyncEcho() throws {
        let source = try make(), context = ModelContext(source.container)
        let product = CatalogProduct(canonicalName: "盒子"), photo = Data("keep-local".utf8)
        let lot = InventoryLot(productID: product.id, quantity: 1, unit: "个")
        var profile = ItemProfile(category: .household); profile.photo = photo
        lot.profileData = try SyncRecord.encode(profile)
        context.insert(product); context.insert(lot); try context.save()
        let key = SyncRecord.Key(kind: .inventory, id: product.id), before = try XCTUnwrap(source.snapshot()[key])
        var remote = try JSONDecoder().decode(ButlerSyncData.Inventory.self, from: before)
        remote.lots[0].profileData = nil
        let after = try SyncRecord.encode(remote)
        try source.replace(key, expected: before, with: after)
        XCTAssertEqual(try source.snapshot()[key], after)
        let updated = try ModelContext(source.container).fetch(FetchDescriptor<InventoryLot>())[0]
        XCTAssertEqual(updated.itemProfile?.photo, photo)
    }
}
