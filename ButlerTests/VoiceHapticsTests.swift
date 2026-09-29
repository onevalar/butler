import XCTest
@testable import Butler

@MainActor
final class VoiceHapticsTests: XCTestCase {
    func testReleaseAndReadyStopPreparationAndANewPressStartsCleanly() async throws {
        let feedback = VoiceHaptics()
        feedback.touchDown()
        XCTAssertTrue(feedback.preparing)
        feedback.stopPreparing()
        XCTAssertFalse(feedback.preparing)
        feedback.recordingReady() // A late microphone callback after release must do nothing.
        XCTAssertFalse(feedback.preparing)
        feedback.touchDown()
        XCTAssertTrue(feedback.preparing)
        feedback.recordingReady()
        XCTAssertFalse(feedback.preparing)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(feedback.preparing, "A cancelled preparation cannot be reactivated by a late callback")
    }

    func testFailureAndBackgroundAlwaysEndPreparation() {
        let feedback = VoiceHaptics()
        feedback.touchDown()
        feedback.failed()
        XCTAssertFalse(feedback.preparing)
        feedback.touchDown()
        feedback.suspend()
        XCTAssertFalse(feedback.preparing)
    }
}
