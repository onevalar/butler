import Foundation
import UIKit
import XCTest
@testable import Butler

@MainActor final class ShareContentReaderTests: XCTestCase {
    private func fixture(_ inputs: [(String, String, Data)], text: String = "") throws -> (ShareInbox, ShareInbox.Record) {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareInbox(root: root.appendingPathComponent("inbox")), id = UUID()
        try inbox.begin(id: id)
        var files: [ShareInbox.Attachment] = []
        for (name, type, bytes) in inputs {
            let source = root.appendingPathComponent(UUID().uuidString)
            try bytes.write(to: source)
            files.append(try inbox.copyFile(source, name: name, type: type, id: id, existing: files))
        }
        return (inbox, try inbox.publish(id: id, text: text, attachments: files))
    }

    func testInvalidUTF8IsNotReplacedWithPlausibleText() throws {
        let (inbox, record) = try fixture([
            ("invalid.txt", "public.plain-text", Data([0x41, 0xff, 0x42])),
            ("valid.txt", "public.plain-text", Data("牛奶2盒，金额23.50".utf8))
        ])
        let content = try ShareContentReader.read(record, inbox: inbox)
        XCTAssertTrue(content.text.contains("不是有效UTF-8"))
        XCTAssertTrue(content.text.contains("牛奶2盒，金额23.50"))
        XCTAssertFalse(content.text.contains("�")); XCTAssertTrue(content.photos.isEmpty)
        XCTAssertEqual(try Data(contentsOf: inbox.fileURL(record.attachments[0], in: record)), Data([0x41, 0xff, 0x42]))
    }

    func testManifestSurvivesTruncationAndFitsEmptyDraft() throws {
        let names = (0..<8).map { "file-\($0)-" + String(repeating: "名", count: 180) }
        let inputs = names.map { ($0, "public.plain-text", Data(String(repeating: "文", count: 5100).utf8)) }
        let (inbox, record) = try fixture(inputs, text: String(repeating: "说明", count: 5000))
        let content = try ShareContentReader.read(record, inbox: inbox)
        for name in names { XCTAssertTrue(content.text.contains(name)) }
        XCTAssertTrue(content.text.contains("仅附入前6500字"))
        XCTAssertLessThan(content.text.count, 8000)
        XCTAssertTrue(content.text.contains("不是对已有待确认项的批准"))
        XCTAssertEqual(try inbox.list().records, [record])
    }

    func testBrokenAndImageOnlyPDFDoNotPretendToHaveText() throws {
        let scanned = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 40, height: 30)).pdfData { context in
            context.beginPage(); UIColor.red.setFill(); context.fill(CGRect(x: 1, y: 1, width: 10, height: 10))
        }
        let (inbox, record) = try fixture([
            ("broken.pdf", "com.adobe.pdf", Data("not a pdf".utf8)),
            ("scanned.pdf", "com.adobe.pdf", scanned)
        ])
        let content = try ShareContentReader.read(record, inbox: inbox)
        XCTAssertTrue(content.text.contains("PDF无法解析"))
        XCTAssertTrue(content.text.contains("未提取到文字"))
        XCTAssertEqual(try Data(contentsOf: inbox.fileURL(record.attachments[1], in: record)), scanned)
    }

    func testImageDecoderDownsamplesAndRejectsInvalidAndOversizedData() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 3200, height: 800), format: format).pngData { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3200, height: 800))
        }
        let jpeg = try ShareContentReader.image(bytes), image = try XCTUnwrap(UIImage(data: jpeg)?.cgImage)
        XCTAssertEqual(image.width, 1600); XCTAssertEqual(image.height, 400)
        XCTAssertLessThanOrEqual(jpeg.count, 4_000_000)
        XCTAssertThrowsError(try ShareContentReader.image(Data([1, 2, 3])))
        XCTAssertThrowsError(try ShareContentReader.image(Data(repeating: 0, count: ShareInbox.maxFileBytes + 1)))
    }

    func testCancelledReaderDoesNotReturnImportableContent() async throws {
        let (inbox, record) = try fixture([], text: "https://example.com/receipt")
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ShareContentReader.read(record, inbox: inbox)
        }
        do { _ = try await task.value; XCTFail("Must not produce content after cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try inbox.list().records, [record])
    }
}
