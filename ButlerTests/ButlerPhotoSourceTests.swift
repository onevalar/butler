import Foundation
import SwiftData
import UIKit
import XCTest
@testable import Butler

@MainActor final class ButlerPhotoSourceTests: XCTestCase {
    private func make() throws -> (ModelContainer, URL) {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let config = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return (try ModelContainer(for: ButlerStore.schema, configurations: [config]), root)
    }
    private func image(_ color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 3, height: 2)).pngData { ctx in
            color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        }
    }
    func testItemImagePreservesProfileAndRefusesStaleOrInvalidImage() throws {
        let (container, root) = try make(), context = ModelContext(container)
        let product = CatalogProduct(canonicalName: "测试盒子")
        let lot = InventoryLot(productID: product.id, quantity: 3, unit: "个", revision: 9)
        var profile = ItemProfile(category: .household); profile.tags = ["保留标签"]
        lot.profileData = try SyncRecord.encode(profile)
        context.insert(product); context.insert(lot); try context.save()
        let source = ButlerPhotoSource(container: container, root: root, working: { false }, didImport: {})
        let key = SyncRecord.Key(kind: .itemPhoto, id: lot.id)
        let photo = SyncPhotoBundle(scopeKey: nil, files: [.init(name: "image", data: image(.red))])
        XCTAssertTrue(try source.apply(key, before: nil, after: photo))
        let received = try ModelContext(container).fetch(FetchDescriptor<InventoryLot>())[0]
        XCTAssertEqual(received.itemProfile?.tags, profile.tags); XCTAssertEqual(received.revision, 10)
        XCTAssertEqual(try source.photos()[key]?.bundle, photo)
        let other = SyncPhotoBundle(scopeKey: nil, files: [.init(name: "image", data: image(.blue))])
        XCTAssertThrowsError(try source.apply(key, before: nil, after: other))
        let invalid = SyncPhotoBundle(scopeKey: nil, files: [.init(name: "image", data: Data([0, 1]))])
        XCTAssertThrowsError(try source.apply(key, before: photo, after: invalid))
        XCTAssertEqual(try source.photos()[key]?.bundle, photo)
    }
    func testChatPartialRecoveryChecksEveryFileAndLeavesDraftUntouched() throws {
        let (container, root) = try make(), files = ChatSessionFiles(scope: .general, root: root)
        var turn = ChatTurn(question: "两张照片")
        turn.photos = (0..<2).map { "\(turn.id)-\($0).jpg" }
        try files.saveTurns([turn])
        let draft = Data("private draft".utf8); try draft.write(to: files.draft)
        let source = ButlerPhotoSource(container: container, root: root, working: { false }, didImport: {})
        let key = SyncRecord.Key(kind: .chatPhoto, id: turn.id)
        let photo = SyncPhotoBundle(scopeKey: ChatScope.general.key, files: [
            .init(name: turn.photos![0], data: image(.red)), .init(name: turn.photos![1], data: image(.blue))])
        XCTAssertEqual(try source.photos()[key]?.incomplete, true)
        try FileManager.default.createDirectory(at: files.photos, withIntermediateDirectories: true)
        try photo.files[0].data.write(to: files.photos.appendingPathComponent(photo.files[0].name))
        XCTAssertTrue(try source.apply(key, before: nil, after: photo))
        XCTAssertEqual(try source.photos()[key]?.bundle, photo)
        let changed = image(.green), second = files.photos.appendingPathComponent(photo.files[1].name)
        try changed.write(to: second)
        XCTAssertThrowsError(try source.apply(key, before: photo, after: nil))
        XCTAssertEqual(try Data(contentsOf: files.photos.appendingPathComponent(photo.files[0].name)), photo.files[0].data)
        XCTAssertEqual(try Data(contentsOf: second), changed)
        XCTAssertEqual(try Data(contentsOf: files.draft), draft)
        let busy = ButlerPhotoSource(container: container, root: root, working: { true }, didImport: {})
        XCTAssertThrowsError(try busy.photos())
    }
}
