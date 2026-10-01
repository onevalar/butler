import Foundation
import XCTest
@testable import Butler

final class ShareInboxTests: XCTestCase {
    private func fixture() throws -> (ShareInbox, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (ShareInbox(root: root.appendingPathComponent("inbox")), root)
    }

    func testInterruptedTransferIsNotPublishedAndOriginalIsCopiedBeforeProviderDeletesIt() throws {
        let (inbox, root) = try fixture(), id = UUID()
        let source = root.appendingPathComponent("receipt.txt")
        let original = Data("牛奶2瓶\n2026-10-01".utf8)
        try original.write(to: source)
        try inbox.begin(id: id)
        let file = try inbox.copyFile(source, name: "../../receipt.txt", type: "public.plain-text", id: id, existing: [])
        try FileManager.default.removeItem(at: source)
        XCTAssertTrue(try ShareInbox(root: inbox.root).list().records.isEmpty)
        let record = try inbox.publish(id: id, text: "https://example.com/order/123", attachments: [file])
        let reopened = ShareInbox(root: inbox.root)
        XCTAssertEqual(try reopened.list().records, [record])
        XCTAssertEqual(try Data(contentsOf: reopened.fileURL(file, in: record)), original)
        XCTAssertEqual(try reopened.fileURL(file, in: record).lastPathComponent, file.id.uuidString)
        XCTAssertEqual(file.name, "../../receipt.txt") // Display name never becomes a path.
    }

    func testSameInvocationCannotOverwriteButSeparateIdenticalSharesRemainDistinct() throws {
        let (inbox, _) = try fixture(), first = UUID(), second = UUID()
        try inbox.begin(id: first)
        XCTAssertThrowsError(try inbox.begin(id: first))
        let original = try inbox.publish(id: first, text: "相同的订单", attachments: [])
        XCTAssertThrowsError(try inbox.begin(id: first))
        XCTAssertThrowsError(try inbox.publish(id: first, text: "覆盖内容", attachments: []))
        try inbox.begin(id: second)
        _ = try inbox.publish(id: second, text: "相同的订单", attachments: [])
        XCTAssertEqual(Set(try inbox.list().records.map(\.id)), [first, second])
        XCTAssertEqual(try inbox.list().records.first { $0.id == first }, original)
    }

    func testCancelRemovesOnlyOwnedStagingNotPublishedOrOtherInvocations() throws {
        let (inbox, _) = try fixture(), first = UUID(), second = UUID()
        try inbox.begin(id: first)
        let saved = try inbox.publish(id: first, text: "已保存", attachments: [])
        try inbox.begin(id: second)
        inbox.cancel(id: second)
        inbox.cancel(id: first)
        XCTAssertEqual(try inbox.list().records, [saved])
        try inbox.begin(id: second)
    }

    func testTextBoundaryAndEmptyRejection() throws {
        let (inbox, _) = try fixture(), id = UUID()
        try inbox.begin(id: id)
        XCTAssertThrowsError(try inbox.publish(id: id, text: " \n", attachments: []))
        XCTAssertThrowsError(try inbox.publish(id: id, text: String(repeating: "字", count: 20_001), attachments: []))
        XCTAssertTrue(try inbox.list().records.isEmpty)
        _ = try inbox.publish(id: id, text: String(repeating: "字", count: 20_000), attachments: [])
        XCTAssertEqual(try inbox.list().records.first?.text.count, 20_000)
    }

    func testByteAndFileCountLimitsRejectBeforePublishing() throws {
        let (inbox, root) = try fixture(), id = UUID()
        let source = root.appendingPathComponent("large")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        defer { try? handle.close() }
        try inbox.begin(id: id)
        try handle.truncate(atOffset: 20 * 1024 * 1024 + 1)
        XCTAssertThrowsError(try inbox.copyFile(source, name: "big", type: "public.data", id: id, existing: []))
        try handle.truncate(atOffset: 20 * 1024 * 1024)
        let first = try inbox.copyFile(source, name: "first", type: "public.data", id: id, existing: [])
        let second = try inbox.copyFile(source, name: "second", type: "public.data", id: id, existing: [first])
        try handle.truncate(atOffset: 1)
        XCTAssertThrowsError(try inbox.copyFile(source, name: "overflow", type: "public.data", id: id, existing: [first, second]))
        let other = UUID()
        try inbox.begin(id: other)
        var files: [ShareInbox.Attachment] = []
        for _ in 0..<8 { files.append(try inbox.copyFile(source, name: "small", type: "public.data", id: other, existing: files)) }
        XCTAssertThrowsError(try inbox.copyFile(source, name: "ninth", type: "public.data", id: other, existing: files))
        XCTAssertTrue(try inbox.list().records.isEmpty)
    }

    func testUnreadableRecordIsReportedWithoutHidingHealthyRecordsOrDeletingEvidence() throws {
        let (inbox, root) = try fixture(), good = UUID(), broken = UUID()
        try inbox.begin(id: good)
        let saved = try inbox.publish(id: good, text: "完整", attachments: [])
        try inbox.begin(id: broken)
        let source = root.appendingPathComponent("source")
        try Data([5, 9, 2]).write(to: source)
        let file = try inbox.copyFile(source, name: "source", type: "public.data", id: broken, existing: [])
        let record = try inbox.publish(id: broken, text: "损坏", attachments: [file])
        try Data([1]).write(to: inbox.fileURL(file, in: record))
        let result = try inbox.list()
        XCTAssertEqual(result.records, [saved])
        XCTAssertEqual(result.unreadableCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.root.appendingPathComponent(broken.uuidString).appendingPathComponent("record.json").path))
    }

    func testPublishRechecksStagedFileAndRejectsDuplicateReferences() throws {
        let (inbox, root) = try fixture(), id = UUID(), source = root.appendingPathComponent("original")
        try Data([2, 7, 9]).write(to: source); try inbox.begin(id: id)
        let file = try inbox.copyFile(source, name: "receipt", type: "public.data", id: id, existing: [])
        XCTAssertThrowsError(try inbox.publish(id: id, text: "", attachments: [file, file]))
        let staged = inbox.root.appendingPathComponent(".receiving-\(id)").appendingPathComponent(file.filename)
        try Data([1]).write(to: staged)
        XCTAssertThrowsError(try inbox.publish(id: id, text: "", attachments: [file]))
        XCTAssertTrue(try inbox.list().records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), Data([2, 7, 9]))
        try FileManager.default.removeItem(at: staged)
        try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: source)
        XCTAssertThrowsError(try inbox.publish(id: id, text: "", attachments: [file]))
    }

    func testStoredMetadataLimitsAreRecheckedWithoutDeletingRecords() throws {
        let (inbox, root) = try fixture(), id = UUID(), source = root.appendingPathComponent("original")
        try Data([4]).write(to: source); try inbox.begin(id: id)
        let file = try inbox.copyFile(source, name: "receipt", type: "public.data", id: id, existing: [])
        let saved = try inbox.publish(id: id, text: "", attachments: [file])
        let metadata = inbox.root.appendingPathComponent(id.uuidString).appendingPathComponent("record.json")
        for invalid in [
            ShareInbox.Record(id: id, createdAt: saved.createdAt, text: "", attachments: [file, file]),
            ShareInbox.Record(id: id, createdAt: saved.createdAt, text: String(repeating: "字", count: 20_001), attachments: [file])
        ] {
            let bytes = try JSONEncoder().encode(invalid); try bytes.write(to: metadata)
            let listing = try inbox.list()
            XCTAssertEqual(listing.unreadableCount, 1); XCTAssertTrue(listing.records.isEmpty)
            XCTAssertThrowsError(try inbox.fileURL(file, in: invalid))
            XCTAssertEqual(try Data(contentsOf: metadata), bytes)
        }
    }

    func testRecordValidationRejectsOverflowAndAcceptsExactTotalBoundary() throws {
        let id = UUID()
        func record(_ sizes: [Int]) -> ShareInbox.Record {
            .init(id: id, createdAt: .now, text: "", attachments: sizes.map {
                .init(id: UUID(), name: "file", type: "public.data", bytes: $0)
            })
        }
        try record([ShareInbox.maxFileBytes, ShareInbox.maxFileBytes]).validate()
        for sizes in [[Int.max, 1], [-1], [0], [ShareInbox.maxFileBytes + 1],
                      [ShareInbox.maxFileBytes, ShareInbox.maxFileBytes, 1], Array(repeating: 1, count: 9)] {
            XCTAssertThrowsError(try record(sizes).validate())
        }
    }

    func testPublishedFolderLinkCannotReadOutsideInbox() throws {
        let (inbox, root) = try fixture(), id = UUID()
        try inbox.begin(id: id)
        let saved = try inbox.publish(id: id, text: "text only", attachments: [])
        let folder = inbox.root.appendingPathComponent(id.uuidString), outside = root.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: folder, to: outside)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        let listing = try inbox.list()
        XCTAssertTrue(listing.records.isEmpty); XCTAssertEqual(listing.unreadableCount, 1)
        XCTAssertEqual(try JSONDecoder().decode(ShareInbox.Record.self, from: Data(contentsOf: outside.appendingPathComponent("record.json"))), saved)
    }

    func testPickerBatchPreservesOrderOriginalsAndSameOperationId() throws {
        let (inbox, root) = try fixture(), id = UUID()
        let first = root.appendingPathComponent("receipt.pdf"), second = root.appendingPathComponent("note.txt")
        try Data([3, 9, 1]).write(to: first); try Data("备注".utf8).write(to: second)
        let sources = [(url: first, type: "com.adobe.pdf"), (url: second, type: "public.plain-text")]
        let saved = try inbox.importFiles(sources, id: id)
        XCTAssertEqual(saved.attachments.map(\.name), ["receipt.pdf", "note.txt"])
        XCTAssertEqual(saved.attachments.map(\.type), ["com.adobe.pdf", "public.plain-text"])
        XCTAssertThrowsError(try inbox.importFiles(sources, id: id))
        try FileManager.default.removeItem(at: first)
        XCTAssertEqual(try Data(contentsOf: inbox.fileURL(saved.attachments[0], in: saved)), Data([3, 9, 1]))
        XCTAssertEqual(try ShareInbox(root: inbox.root).list().records, [saved])
        XCTAssertEqual(try Data(contentsOf: second), Data("备注".utf8))
    }

    func testPickerBatchFailureDoesNotPublishPartialFilesOrRemoveOtherReceipt() throws {
        let (inbox, root) = try fixture(), id = UUID(), source = root.appendingPathComponent("ok.txt")
        try Data("原件".utf8).write(to: source)
        let good = try inbox.importFiles([(source, "public.plain-text")], id: UUID())
        XCTAssertThrowsError(try inbox.importFiles([(source, "public.plain-text"),
            (root.appendingPathComponent("missing.pdf"), "com.adobe.pdf")], id: id))
        XCTAssertEqual(try inbox.list().records, [good])
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.root.appendingPathComponent(".receiving-\(id)").path))
        XCTAssertEqual(try Data(contentsOf: source), Data("原件".utf8))
        XCTAssertThrowsError(try inbox.importFiles([(source, "public.plain-text"), (source, "public.plain-text")], id: UUID()))
        XCTAssertThrowsError(try inbox.importFiles((0..<9).map { (root.appendingPathComponent("\($0)"), "public.data") }, id: UUID()))
    }

    func testCancelledPickerBatchNeverPublishesOrRemovesExistingRecord() async throws {
        let (inbox, root) = try fixture(), source = root.appendingPathComponent("ok.txt")
        try Data([1, 8]).write(to: source)
        let good = try inbox.importFiles([(source, "public.plain-text")], id: UUID())
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try inbox.importFiles([(source, "public.plain-text")], id: UUID())
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected: \(error)") }
        XCTAssertEqual(try inbox.list().records, [good])
    }

    func testFolderAndSymlinkAreRejected() throws {
        let (inbox, root) = try fixture(), id = UUID()
        try inbox.begin(id: id)
        XCTAssertThrowsError(try inbox.copyFile(root, name: "folder", type: "public.folder", id: id, existing: []))
        let source = root.appendingPathComponent("source"), link = root.appendingPathComponent("link")
        try Data([2, 3]).write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try inbox.copyFile(link, name: "link", type: "public.data", id: id, existing: []))
    }
}
