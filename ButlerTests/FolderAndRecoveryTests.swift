import Foundation
import XCTest
@testable import Butler

@MainActor final class FakeFolderDevice: FolderDevice {
    var creates = 0
    var beforeCreate: (() throws -> Void)?
    var duringCreate: (() async throws -> Void)?
    var duringSearch: (() throws -> Void)?
    func grant(_ url: URL) throws -> FolderGrant {
        FolderGrant(id: UUID(), name: url.lastPathComponent, bookmark: Data(url.path.utf8))
    }
    func search(_ grant: FolderGrant, query: String) async throws -> FolderSearch {
        try duringSearch?()
        return FolderSearch(paths: ["a.txt"], inspected: 1, truncated: false)
    }
    func create(_ grant: FolderGrant, export: FolderExport) async throws {
        creates += 1
        try beforeCreate?()
        try await duringCreate?()
        try FolderFileIO.create(URL(fileURLWithPath: String(decoding: grant.bookmark, as: UTF8.self)), export: export)
    }
}

@MainActor final class FolderAndRecoveryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testExportRejectsPathsAndByteBoundaryAndFormula() async throws {
        let id = UUID()
        for name in ["../a.txt", "a/b.md", "a\\b.csv", ".a.txt", "a.txt\n", "a.pdf", "/a.txt", "a:b.txt"] {
            XCTAssertThrowsError(try FolderExport(folderID: id, filename: name, text: "x").validate(), name)
        }
        try FolderExport(folderID: id, filename: "清单.md", text: String(repeating: "a", count: 20_000)).validate()
        XCTAssertThrowsError(try FolderExport(folderID: id, filename: "清单.md", text: String(repeating: "a", count: 20_001)).validate())
        XCTAssertThrowsError(try FolderExport(folderID: id, filename: "清单.md", text: String(repeating: "中", count: 6667)).validate())
        for formula in ["name,=1+2", "name,\"-1\"", "name,\t@SUM(1)", "name,+1"] {
            XCTAssertThrowsError(try FolderExport(folderID: id, filename: "a.csv", text: formula).validate())
        }
        try FolderExport(folderID: id, filename: "a.csv", text: "名称,数量\n牛奶,2").validate()
    }

    func testRealCreationNeverOverwritesFilesOrSymlinkTargets() async throws {
        let root = try directory(), outside = try directory().appendingPathComponent("outside.txt")
        try Data("KEEP".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: outside)
        let value = FolderExport(folderID: UUID(), filename: "new.md", text: "hello 中文")
        try FolderFileIO.create(root, export: value)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new.md"), encoding: .utf8), "hello 中文")
        XCTAssertThrowsError(try FolderFileIO.create(root, export: .init(folderID: value.folderID, filename: "new.md", text: "replace")))
        XCTAssertThrowsError(try FolderFileIO.create(root, export: .init(folderID: value.folderID, filename: "link.txt", text: "replace")))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "KEEP")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new.md"), encoding: .utf8), "hello 中文")
    }

    func testSearchSubfoldersSkipsLinksHiddenFilesAndReportsTruncation() async throws {
        let root = try directory(), outside = try directory()
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data().write(to: sub.appendingPathComponent("Warranty.txt"))
        try Data().write(to: root.appendingPathComponent(".Warranty.txt"))
        try Data().write(to: outside.appendingPathComponent("Warranty-secret.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        let result = try FolderFileIO.search(root, query: "warranty")
        XCTAssertEqual(result.paths, ["sub/Warranty.txt"]); XCTAssertFalse(result.truncated)
        for index in 0..<101 { try Data().write(to: root.appendingPathComponent("match-\(index).txt")) }
        let bounded = try FolderFileIO.search(root, query: "match-")
        XCTAssertEqual(bounded.paths.count, 100); XCTAssertTrue(bounded.truncated)
    }

    func testWriteAheadAndReplayAfterReopen() async throws {
        let root = try directory(), file = try directory().appendingPathComponent("state.json"), device = FakeFolderDevice()
        let store = AuthorizedFolderStore(file: file, device: device)
        let grant = try store.authorize(root), id = UUID()
        device.beforeCreate = {
            let saved = try AuthorizedFolderStore(file: file, device: device).writes()
            XCTAssertEqual(saved.map(\.id), [id]); XCTAssertFalse(saved[0].completed)
        }
        let value = FolderExport(folderID: grant.id, filename: "a.txt", text: "original")
        _ = try await store.export(value, operationID: id)
        let reopened = AuthorizedFolderStore(file: file, device: device)
        _ = try await reopened.export(value, operationID: id)
        XCTAssertEqual(device.creates, 1); XCTAssertTrue(try reopened.writes()[0].completed)
    }

    func testUnknownReceiptNeverRetriesAndJournalFailurePreventsWrite() async throws {
        let root = try directory(), stateRoot = try directory(), file = stateRoot.appendingPathComponent("state.json")
        let device = FakeFolderDevice(), store = AuthorizedFolderStore(file: file, device: FakeFolderDevice())
        let grant = try store.authorize(root)
        let active = AuthorizedFolderStore(file: file, device: device), id = UUID()
        device.beforeCreate = {
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        }
        let value = FolderExport(folderID: grant.id, filename: "a.txt", text: "written")
        do { _ = try await active.export(value, operationID: id); XCTFail("Lost receipt must not report success") } catch {}
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8), "written")
        do { _ = try await active.export(value, operationID: id); XCTFail("Unknown replay must not report success") }
        catch { XCTAssertTrue(error.localizedDescription.contains("待核查")) }
        XCTAssertEqual(device.creates, 1)
        do { _ = try await active.export(.init(folderID: grant.id, filename: "b.txt", text: "x"), operationID: UUID()); XCTFail() } catch {}
        XCTAssertEqual(device.creates, 1)
    }

    func testRevocationRejectsOldGrantAndDiscardsLateSearch() async throws {
        let root = try directory(), file = try directory().appendingPathComponent("state.json"), device = FakeFolderDevice()
        let store = AuthorizedFolderStore(file: file, device: device), grant = try store.authorize(root)
        device.duringSearch = { try store.revoke(grant.id) }
        do { _ = try await store.search(grant.id, query: "a"); XCTFail() } catch {}
        let new = try store.authorize(root)
        XCTAssertNotEqual(new.id, grant.id)
        do { _ = try await store.export(.init(folderID: grant.id, filename: "a.txt", text: "x"), operationID: UUID()); XCTFail() } catch {}
        XCTAssertEqual(device.creates, 0)
    }

    func testCancelBeforeWriteAndLateCompletionDoNotRestoreRevokedGrant() async throws {
        let root = try directory(), file = try directory().appendingPathComponent("state.json"), device = FakeFolderDevice()
        let store = AuthorizedFolderStore(file: file, device: device), grant = try store.authorize(root)
        let value = FolderExport(folderID: grant.id, filename: "a.txt", text: "x")
        let cancelled = Task { _ = try await store.export(value, operationID: UUID()) }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail() } catch {}
        XCTAssertEqual(device.creates, 0); XCTAssertTrue(try store.writes().isEmpty)
        device.duringCreate = { try store.revoke(grant.id) }
        _ = try await store.export(value, operationID: UUID())
        XCTAssertTrue(try store.grants().isEmpty); XCTAssertTrue(try store.writes()[0].completed)
    }

    func testJournalReopenPreservesPartialEvidenceWithoutReplay() async throws {
        let file = try directory().appendingPathComponent("journal.json"), first = UUID(), second = UUID()
        let journal = ConfirmationJournal(file: file)
        let id = try journal.begin(ids: [first, second], titles: ["first", "second"])
        try journal.progress(id, receipts: ["✓ first"])
        let reopened = ConfirmationJournal(file: file), entry = try XCTUnwrap(reopened.records().first)
        XCTAssertFalse(entry.finished); XCTAssertFalse(entry.reported); XCTAssertEqual(entry.receipts, ["✓ first"])
        XCTAssertEqual(try reopened.consumedIDs(), [first, second])
        XCTAssertThrowsError(try reopened.begin(ids: [second], titles: ["again"]))
        try reopened.acknowledge([id])
        let after = ConfirmationJournal(file: file)
        XCTAssertEqual(try after.consumedIDs(), [first, second]); XCTAssertTrue(try after.records()[0].receipts.isEmpty)
        XCTAssertTrue(try after.records()[0].titles.isEmpty)
        XCTAssertThrowsError(try after.progress(id, receipts: ["late"]))
    }

    func testJournalFinishedFailureAndCorruptRecordsFailClosed() async throws {
        let file = try directory().appendingPathComponent("journal.json"), journal = ConfirmationJournal(file: file)
        let id = try journal.begin(ids: [UUID()], titles: ["one"])
        try journal.progress(id, receipts: ["✗ result unknown"], finished: true)
        XCTAssertTrue(try journal.records()[0].finished)
        XCTAssertThrowsError(try journal.progress(id, receipts: ["wrong"]))
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try ConfirmationJournal(file: file).begin(ids: [UUID()], titles: ["new"]))
        XCTAssertThrowsError(try AuthorizedFolderStore(file: file, device: FakeFolderDevice()).grants())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "broken")
    }
}
