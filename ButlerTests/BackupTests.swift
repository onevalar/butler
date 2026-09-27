import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor
final class BackupTests: XCTestCase {
    func testBackupRoundTripRestoresInventoryHistoryFilesAndSettings() throws {
        let container = try ButlerStore.makePreviewContainer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "backup-test-\(UUID())"))
        defaults.set("我是小安", forKey: "butlerProfile")
        defaults.set(3, forKey: "expiryWarningDays")

        let actions = InventoryActions(modelContainer: container)
        try actions.add([.init(name: "红枣酸奶", quantity: 2, unit: "瓶", storage: "冷藏",
                               packageExpiry: Date.now.addingTimeInterval(3.0 * 86_400), plannedUseBy: nil)], sourceText: "测试")
        try Data(#"[{"id":"00000000-0000-0000-0000-000000000001","text":"吃药","fireDate":0,"repeats":"daily","createdAt":0}]"#.utf8)
            .write(to: directory.appendingPathComponent("reminders.json"))
        try Data("chat".utf8).write(to: directory.appendingPathComponent("butler-chat.json"))

        let original = try BackupService.makeBackup(container: container, directory: directory, defaults: defaults)
        let data = try BackupService.encode(original)
        XCTAssertEqual(original.activeLotCount, 1)
        XCTAssertFalse(original.evidence.isEmpty)
        XCTAssertFalse(original.events.isEmpty)

        // Change everything after the backup.
        let context = ModelContext(container)
        let lot = try XCTUnwrap(context.fetch(FetchDescriptor<InventoryLot>()).first)
        let product = try XCTUnwrap(context.fetch(FetchDescriptor<CatalogProduct>()).first)
        try actions.close(LotFacts(lot: lot, product: product), as: .depleted)
        try actions.add([.init(name: "面包", quantity: 1, unit: "袋", storage: nil, packageExpiry: nil, plannedUseBy: nil)], sourceText: "测试")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("reminders.json"))
        defaults.set("别人", forKey: "butlerProfile")

        try BackupService.restore(BackupService.decode(data), container: container, directory: directory, defaults: defaults)

        let after = ModelContext(container)
        let lots = try after.fetch(FetchDescriptor<InventoryLot>())
        XCTAssertEqual(lots.count, 1)
        XCTAssertEqual(lots.first?.state, .active)
        XCTAssertEqual(lots.first?.quantity, 2)
        XCTAssertEqual(lots.first?.storageLocation, "冷藏")
        XCTAssertEqual(try after.fetch(FetchDescriptor<CatalogProduct>()).map(\.canonicalName), ["红枣酸奶"])
        XCTAssertEqual(try after.fetchCount(FetchDescriptor<InventoryEvent>()), original.events.count)
        XCTAssertEqual(try after.fetchCount(FetchDescriptor<FieldEvidence>()), original.evidence.count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("reminders.json").path))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("butler-chat.json"), encoding: .utf8), "chat")
        XCTAssertEqual(defaults.string(forKey: "butlerProfile"), "我是小安")
        XCTAssertEqual(defaults.integer(forKey: "expiryWarningDays"), 3)

        // The data that was replaced was kept as a safety copy.
        let safety = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(safety.count, 1)
        let saved = try BackupService.decode(Data(contentsOf: safety[0]))
        XCTAssertEqual(saved.lots.count, 2)
    }

    func testOtherFilesAreRejected() {
        XCTAssertThrowsError(try BackupService.decode(Data(#"{"hello":"world"}"#.utf8)))
        var future = ButlerBackup()
        future.version = 99
        let data = try! BackupService.encode(future)
        XCTAssertThrowsError(try BackupService.decode(data)) { error in
            XCTAssertEqual((error as? BackupError)?.errorDescription?.contains("更新"), true)
        }
    }
}
