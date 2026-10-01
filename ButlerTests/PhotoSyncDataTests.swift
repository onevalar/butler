import Foundation
import XCTest
@testable import Butler

@MainActor private final class PhotoSource: SyncPhotoSource {
    var values: [SyncRecord.Key: SyncPhotoSourceValue] = [:]
    var crashAfterWrite = false
    func photos() throws -> [SyncRecord.Key: SyncPhotoSourceValue] { values }
    func apply(_ key: SyncRecord.Key, before: SyncPhotoBundle?, after: SyncPhotoBundle?) throws -> Bool {
        guard let current = values[key] else { return false }
        let existing = current.bundle?.files ?? []
        guard existing.allSatisfy({ file in
            before?.files.contains(file) == true || after?.files.contains(file) == true
        }) else { throw SyncFailure("changed locally") }
        values[key] = .init(bundle: after, incomplete: false)
        if crashAfterWrite { throw SyncFailure("interrupted") }
        return true
    }
}

@MainActor final class PhotoSyncDataTests: XCTestCase {
    private let key = SyncRecord.Key(kind: .itemPhoto, id: UUID())
    private func bundle(_ text: String) -> SyncPhotoBundle {
        .init(scopeKey: nil, files: [.init(name: "image", data: Data(text.utf8))])
    }
    private func directory() throws -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testOrphanSurvivesRestartAndHydratesOnlyAfterOwnerArrives() async throws {
        let file = try directory().appendingPathComponent("photos.json"), source = PhotoSource()
        let photo = bundle("remote"), payload = try SyncRecord.encode(photo)
        let local = try PhotoSyncData(file: file, source: source)
        try local.replace(key, expected: nil, with: payload)
        XCTAssertTrue(source.values.isEmpty)
        let restarted = try PhotoSyncData(file: file, source: source)
        XCTAssertEqual(try restarted.snapshot()[key], payload)
        source.values[key] = .init(bundle: nil, incomplete: false)
        XCTAssertEqual(try restarted.snapshot()[key], payload)
        XCTAssertEqual(source.values[key]?.bundle, photo)
        source.values[key] = nil
        XCTAssertNil(try restarted.snapshot()[key], "An owner removed after import really is a deletion")
    }
    func testMissingAttachmentRepairsWithoutUploadingDeletionOrEcho() async throws {
        let dir = try directory(), source = PhotoSource(), cloud = FakeSyncCloud()
        let photo = bundle("cloud bytes"), payload = try SyncRecord.encode(photo)
        cloud.records = [.init(id: UUID(), key: key, parents: [], payload: payload, device: UUID())]
        source.values[key] = .init(bundle: nil, incomplete: true)
        let local = try PhotoSyncData(file: dir.appendingPathComponent("photos.json"), source: source)
        let store = SyncStore(file: dir.appendingPathComponent("sync.json"), local: local, transport: cloud, kinds: [.itemPhoto])
        XCTAssertFalse(store.enabled); XCTAssertEqual(cloud.requests, 0)
        try await store.setEnabled(true); try await store.synchronize()
        XCTAssertEqual(source.values[key]?.bundle, photo)
        source.values[key] = .init(bundle: nil, incomplete: true)
        try await store.synchronize()
        XCTAssertEqual(source.values[key]?.bundle, photo)
        XCTAssertEqual(cloud.records.count, 1)
        source.values[key] = .init(bundle: nil, incomplete: false)
        try await store.synchronize()
        XCTAssertEqual(cloud.records.count, 2); XCTAssertNil(cloud.records.last?.payload)
    }
    func testPartialAttachmentRepairRefusesChangedBytes() async throws {
        let dir = try directory(), source = PhotoSource()
        let key = SyncRecord.Key(kind: .chatPhoto, id: UUID())
        let first = SyncPhotoBundle.File(name: "\(key.id)-0.jpg", data: Data([1, 2]))
        let second = SyncPhotoBundle.File(name: "\(key.id)-1.jpg", data: Data([3, 4, 5]))
        let photo = SyncPhotoBundle(scopeKey: "general", files: [first, second])
        source.values[key] = .init(bundle: nil, incomplete: true)
        let local = try PhotoSyncData(file: dir.appendingPathComponent("photos.json"), source: source)
        try local.replace(key, expected: nil, with: SyncRecord.encode(photo))
        source.values[key] = .init(bundle: .init(scopeKey: "general", files: [first]), incomplete: true)
        XCTAssertEqual(try local.snapshot()[key], try SyncRecord.encode(photo))
        let changed = SyncPhotoBundle(scopeKey: "general", files: [.init(name: first.name, data: Data([9]))])
        source.values[key] = .init(bundle: changed, incomplete: true)
        XCTAssertThrowsError(try local.snapshot())
        XCTAssertEqual(source.values[key]?.bundle, changed)
    }
    func testInterruptedImportResumesButRestoreDiscardsPendingWrite() async throws {
        let file = try directory().appendingPathComponent("photos.json"), source = PhotoSource()
        let local = try PhotoSyncData(file: file, source: source), photo = bundle("remote")
        source.values[key] = .init(bundle: nil, incomplete: false); source.crashAfterWrite = true
        XCTAssertThrowsError(try local.replace(key, expected: nil, with: SyncRecord.encode(photo)))
        source.crashAfterWrite = false
        let restarted = try PhotoSyncData(file: file, source: source)
        XCTAssertEqual(try restarted.snapshot()[key], try SyncRecord.encode(photo))
        source.crashAfterWrite = true
        XCTAssertThrowsError(try restarted.replace(key, expected: SyncRecord.encode(photo), with: SyncRecord.encode(bundle("new"))))
        try restarted.abandonImport()
        source.crashAfterWrite = false
        let restored = bundle("restored local backup")
        source.values[key] = .init(bundle: restored, incomplete: false)
        XCTAssertEqual(try restarted.snapshot()[key], try SyncRecord.encode(restored))
    }
    func testStaleExpectedImageCannotOverwriteLocalReplacement() async throws {
        let source = PhotoSource(), local = try PhotoSyncData(file: directory().appendingPathComponent("photos.json"), source: source)
        let old = bundle("old"), edited = bundle("local replacement")
        source.values[key] = .init(bundle: old, incomplete: false)
        _ = try local.snapshot()
        source.values[key] = .init(bundle: edited, incomplete: false)
        XCTAssertThrowsError(try local.replace(key, expected: SyncRecord.encode(old), with: SyncRecord.encode(bundle("remote"))))
        XCTAssertEqual(source.values[key]?.bundle, edited)
    }
    func testBundleRejectsTraversalDuplicateWrongOwnerAndOversize() async throws {
        let key = SyncRecord.Key(kind: .chatPhoto, id: UUID())
        let valid = SyncPhotoBundle.File(name: "\(key.id)-0.jpg", data: Data([1]))
        try SyncPhotoBundle(scopeKey: "general", files: [valid]).validate(for: key)
        for photo in [
            SyncPhotoBundle(scopeKey: "../general", files: [valid]),
            SyncPhotoBundle(scopeKey: "general", files: [valid, valid]),
            SyncPhotoBundle(scopeKey: "general", files: [.init(name: "\(UUID())-0.jpg", data: Data([1]))]),
            SyncPhotoBundle(scopeKey: "general", files: [.init(name: "../photo.jpg", data: Data([1]))]),
            SyncPhotoBundle(scopeKey: "general", files: [.init(name: valid.name, data: Data(repeating: 1, count: 4_000_001))])
        ] { XCTAssertThrowsError(try photo.validate(for: key)) }
        try SyncPhotoBundle(scopeKey: "general", files: [.init(name: valid.name, data: Data(repeating: 1, count: 4_000_000))]).validate(for: key)
    }
}
