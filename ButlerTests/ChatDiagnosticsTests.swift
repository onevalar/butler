import Foundation
import XCTest
@testable import Butler

final class ChatDiagnosticsTests: XCTestCase {
    func testConcurrentAppendsKeepEveryCompleteLineExactlyOnce() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        DispatchQueue.concurrentPerform(iterations: 400) { index in
            ChatDiagnostics.log("entry-\(index)", to: url)
        }
        ChatDiagnostics.log("finished", to: url)
        let text = try await contents(after: "finished", at: url)
        let lines = text.split(separator: "\n").map { String($0.split(separator: " ").last!) }
        XCTAssertEqual(lines.count, 401)
        XCTAssertEqual(Set(lines), Set((0..<400).map { "entry-\($0)" } + ["finished"]))
    }

    func testRotationKeepsRecentWholeChineseLinesAndSubsequentAppends() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let old = (0..<12_000).map { "旧记录-\($0)-中文\n" }.joined()
        try Data(old.utf8).write(to: url)
        XCTAssertGreaterThan(old.utf8.count, 200_000)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            ChatDiagnostics.log("new-\(index)", to: url)
        }
        ChatDiagnostics.log("finished", to: url)
        let text = try await contents(after: "finished", at: url)
        XCTAssertLessThan(text.utf8.count, 200_000)
        XCTAssertFalse(text.contains("旧记录-0-中文"))
        XCTAssertTrue(text.contains("旧记录-11999-中文"))
        XCTAssertTrue(text.hasPrefix("旧记录-"), "rotation must not split a line or a Chinese character")
        let new = text.split(separator: "\n").filter { $0.contains(" new-") }
        XCTAssertEqual(new.count, 100)
        XCTAssertEqual(Set(new.map { String($0.split(separator: " ").last!) }), Set((0..<100).map { "new-\($0)" }))
    }

    func testWriteFailureDoesNotPreventLaterLogsAndErrorsDoNotExposeDescriptions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        ChatDiagnostics.log("cannot write over a directory", to: directory)
        let url = directory.appendingPathComponent("log")
        ChatDiagnostics.log("finished", to: url)
        let text = try await contents(after: "finished", at: url)
        XCTAssertTrue(text.contains("finished"))
        let error = NSError(domain: "fixture", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "Authorization: Bearer fictional-secret; full request text"
        ])
        let description = ChatDiagnostics.describe(error)
        XCTAssertTrue(description.contains("fixture 42"))
        XCTAssertFalse(description.contains("fictional-secret"))
        XCTAssertFalse(description.contains("request text"))
    }

    private func contents(after marker: String, at url: URL) async throws -> String {
        for _ in 0..<200 {
            if let text = try? String(contentsOf: url, encoding: .utf8), text.hasSuffix("\(marker)\n") { return text }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The serial writer did not finish")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
