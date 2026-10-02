import Foundation
import XCTest
@testable import Butler

final class ConfirmationJournalTests: XCTestCase {
    @MainActor private func fixture() throws -> (URL, ConfirmationJournal, [ConfirmationResult]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("journal.json")
        let values = (0..<3).map { ConfirmationResult(proposalID: UUID(), requestTurnID: UUID(), title: "项目\($0)", state: .notStarted, message: "未开始") }
        return (file, ConfirmationJournal(file: file), values)
    }

    @MainActor func testInterruptionPreservesCompletedAndUnstartedButDoesNotCallRunningFailed() async throws {
        let (file, journal, initial) = try fixture()
        let id = try journal.begin(ids: initial.map(\.id), titles: initial.map(\.title), results: initial)
        var progress = initial
        progress[0].state = .succeeded; progress[0].message = "第一项已保存"
        progress[1].state = .running
        try journal.progress(id, receipts: progress.map(\.message), results: progress)
        let reopened = ConfirmationJournal(file: file)
        let saved = try XCTUnwrap(reopened.records().first?.results)
        let recovered = saved.map(\.recovered)
        XCTAssertEqual(recovered.map(\.state), [.succeeded, .needsVerification, .notStarted])
        XCTAssertEqual(recovered[0].message, "第一项已保存")
        XCTAssertEqual(recovered.map(\.requestTurnID), initial.map(\.requestTurnID))
        XCTAssertThrowsError(try reopened.begin(ids: [initial[2].id], titles: ["不要重放未开始项"]))
        XCTAssertEqual(try reopened.consumedIDs(), Set(initial.map(\.id)))
    }

    @MainActor func testFinalResultsSurviveReopenAndAcknowledgementKeepsReplayProtection() async throws {
        let (file, journal, initial) = try fixture()
        let id = try journal.begin(ids: initial.map(\.id), titles: initial.map(\.title), results: initial)
        var final = initial
        final[0].state = .succeeded; final[1].state = .failed; final[2].state = .needsVerification
        try journal.progress(id, receipts: final.map(\.message), finished: true, results: final)
        let reopened = ConfirmationJournal(file: file)
        XCTAssertEqual(try reopened.records().first?.results, final)
        XCTAssertThrowsError(try reopened.progress(id, receipts: []))
        try reopened.acknowledge([id])
        let after = ConfirmationJournal(file: file)
        XCTAssertTrue(try XCTUnwrap(after.records().first).reported)
        XCTAssertNil(try after.records().first?.results)
        XCTAssertThrowsError(try after.begin(ids: [initial[0].id], titles: ["duplicate"]))
    }

    @MainActor func testMismatchedResultsAndRunningFinalAreRejectedWithoutChangingSavedProgress() async throws {
        let (file, journal, initial) = try fixture()
        let id = try journal.begin(ids: initial.map(\.id), titles: initial.map(\.title), results: initial)
        let original = try Data(contentsOf: file)
        XCTAssertThrowsError(try journal.progress(id, receipts: [], results: Array(initial.reversed())))
        var running = initial; running[1].state = .running
        XCTAssertThrowsError(try journal.progress(id, receipts: [], finished: true, results: running))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    @MainActor func testWriteFailureDoesNotAdvanceInMemoryEvidence() async throws {
        let (file, journal, initial) = try fixture()
        let id = try journal.begin(ids: initial.map(\.id), titles: initial.map(\.title), results: initial)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        var running = initial; running[0].state = .running
        XCTAssertThrowsError(try journal.progress(id, receipts: [], results: running))
        XCTAssertEqual(try journal.records().first?.results, initial)
    }

    @MainActor func testLegacyCheckmarkIsNotParsedAsStructuredSuccess() async throws {
        let (file, _, initial) = try fixture()
        let old: [[String: Any]] = [["id": UUID().uuidString, "proposalIDs": [initial[0].id.uuidString],
            "titles": ["old"], "date": 42, "receipts": ["✓ 仅提出了请求，不代表完成"], "finished": true, "reported": false]]
        try JSONSerialization.data(withJSONObject: old).write(to: file)
        let saved = try XCTUnwrap(ConfirmationJournal(file: file).records().first)
        XCTAssertNil(saved.results)
        XCTAssertEqual(saved.receipts, ["✓ 仅提出了请求，不代表完成"])
    }

    @MainActor func testPickerNeedsFreshVerificationAfterRelaunchNotAutomaticAuthorization() async throws {
        let (_, _, initial) = try fixture()
        var waiting = initial[0]; waiting.state = .awaitingUser
        XCTAssertEqual(waiting.recovered.state, .needsVerification)
        XCTAssertEqual(waiting.recovered.proposalID, waiting.proposalID)
        var reported = initial[1]; reported.state = .reported
        XCTAssertEqual(reported.recovered, reported)
    }
}
