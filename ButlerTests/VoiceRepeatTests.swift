import XCTest
@testable import Butler

@MainActor
final class VoiceRepeatTests: XCTestCase {
    func testEveryCancelledPressCanBeImmediatelyReplacedWithoutAcceptingOldCallbacks() {
        var session = VoiceInteractionSession()
        var old: [UUID] = []
        for _ in 0..<50 {
            let current = session.begin()
            XCTAssertTrue(session.contains(current))
            XCTAssertTrue(old.allSatisfy { !session.contains($0) })
            session.invalidate()
            XCTAssertFalse(session.contains(current))
            old.append(current)
        }
        let next = session.begin()
        XCTAssertTrue(session.contains(next))
        XCTAssertTrue(old.allSatisfy { !session.contains($0) })
    }

    func testLateFinalizationCannotCompleteANewSession() {
        var session = VoiceInteractionSession()
        let previous = session.begin()
        session.invalidate()
        let current = session.begin()
        XCTAssertFalse(session.contains(previous))
        XCTAssertTrue(session.contains(current))
    }

    func testRepeatedHapticCancelAndRetryNeverLeavesPreparationActive() {
        let feedback = VoiceHaptics()
        for _ in 0..<20 {
            feedback.touchDown()
            XCTAssertTrue(feedback.preparing)
            feedback.recordingReady()
            feedback.cancelled()
            XCTAssertFalse(feedback.preparing)
            feedback.touchDown()
            XCTAssertTrue(feedback.preparing)
            feedback.cancelled()
            XCTAssertFalse(feedback.preparing)
        }
    }
}
