import Foundation
import XCTest
@testable import Butler

final class ScreenshotHandoffTests: XCTestCase {
    func testOriginalSurvivesReopeningInboxAndInvocationsStaySeparate() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareInbox(root: root)
        let bytes = Data([7, 8, 9])
        let first = try ScreenshotHandoff.save(bytes, inbox: inbox)
        let second = try ScreenshotHandoff.save(bytes, inbox: inbox)
        XCTAssertNotEqual(first.id, second.id)
        let reopened = ShareInbox(root: root)
        XCTAssertEqual(try reopened.list().records.count, 2)
        XCTAssertEqual(first.text, "")
        XCTAssertEqual(try Data(contentsOf: reopened.fileURL(first.attachments[0], in: first)), bytes)
    }

    func testInvalidTransportDoesNotPublishPartialRecord() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareInbox(root: root)
        XCTAssertThrowsError(try ScreenshotHandoff.save(Data(), inbox: inbox))
        XCTAssertTrue(try inbox.list().records.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
