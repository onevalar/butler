import Foundation
import XCTest
@testable import Butler

final class OrbMotionTests: XCTestCase {
    func testReverseStartsAtDisplayedPoseAndOnlyTravelsRemainingDistance() {
        var motion = OrbMotion()
        motion.move(to: true, at: 10, animated: true)
        let reversedAt = 10 + 0.95 * 0.7
        XCTAssertEqual(motion.progress(at: reversedAt), 0.7, accuracy: 0.000001)
        motion.move(to: false, at: reversedAt, animated: true)
        XCTAssertEqual(motion.progress(at: reversedAt), 0.7, accuracy: 0.000001)
        XCTAssertEqual(motion.duration, 0.665, accuracy: 0.000001)
        XCTAssertEqual(motion.progress(at: reversedAt + 0.3325), 0.35, accuracy: 0.000001)
        XCTAssertEqual(motion.progress(at: reversedAt + 0.665), 0, accuracy: 0.000001)
    }

    func testRepeatedRetargetingDoesNotJumpOrOvershoot() {
        var motion = OrbMotion()
        motion.move(to: true, at: 0, animated: true)
        motion.move(to: false, at: 0.19, animated: true)
        XCTAssertEqual(motion.progress(at: 0.19), 0.2, accuracy: 0.000001)
        motion.move(to: true, at: 0.2375, animated: true)
        XCTAssertEqual(motion.progress(at: 0.2375), 0.15, accuracy: 0.000001)
        XCTAssertEqual(motion.duration, 0.8075, accuracy: 0.000001)
        XCTAssertEqual(motion.progress(at: 20), 1)
    }

    func testReducedMotionAndBackgroundSnapWithoutResidualTravel() {
        var motion = OrbMotion()
        motion.move(to: true, at: 0, animated: true)
        motion.move(to: true, at: 0.27, animated: false)
        XCTAssertEqual(motion.progress(at: 0.27), 1)
        XCTAssertEqual(motion.duration, 0)
        motion.move(to: false, at: 0.28, animated: false)
        XCTAssertEqual(motion.progress(at: 0.28), 0)
        XCTAssertEqual(motion.progress(at: 2), 0)
    }

    func testContactFeedbackHasOneCrossingInEachDirection() {
        for width: CGFloat in [320, 393, 768] {
            var previous = false
            var changes = 0
            let roundTrip = Array(0...120) + Array((0..<120).reversed())
            for frame in roundTrip {
                let geometry = OrbLiquidGeometry(pose: .at(CGFloat(frame) / 120))
                // This is the same connectivity test used by the displayed surface.
                let connected = geometry.contours(width: width, height: 170).count == 1
                if connected != previous { changes += 1 }
                previous = connected
            }
            XCTAssertEqual(changes, 2, "One contact and one separation, no repeated timer feedback")
        }
    }

    func testCancellationClearsAllGestureStateBeforeAnotherTouch() {
        var gesture = OrbInteraction()
        gesture.begin(onBall: true)
        gesture.drag(CGSize(width: 78, height: -104))
        XCTAssertTrue(gesture.pressing && gesture.dragging)
        XCTAssertGreaterThan(gesture.pull.width, 0)
        XCTAssertLessThan(gesture.pull.height, 0)
        gesture.reset()
        XCTAssertFalse(gesture.pressing)
        XCTAssertFalse(gesture.dragging)
        XCTAssertFalse(gesture.startedOnBall)
        XCTAssertEqual(gesture.pull, .zero)
        gesture.begin(onBall: true)
        gesture.drag(CGSize(width: -20, height: 0))
        XCTAssertTrue(gesture.dragging)
        XCTAssertLessThan(gesture.pull.width, 0, "No offset inherited from the interrupted drag")
    }

    func testDragThresholdAndDirectTrackingWithSpatialResistance() {
        var gesture = OrbInteraction()
        gesture.begin(onBall: true)
        gesture.drag(CGSize(width: 6, height: 8))
        XCTAssertFalse(gesture.dragging, "Exactly ten points remains a tap/hold")
        gesture.drag(CGSize(width: 78, height: -104)) // length 130, direction 0.6, -0.8
        XCTAssertTrue(gesture.dragging)
        XCTAssertEqual(gesture.pull.width, 16.687982753, accuracy: 0.00001)
        XCTAssertEqual(gesture.pull.height, -22.25064367, accuracy: 0.00001)
        gesture.drag(.zero)
        XCTAssertEqual(gesture.pull, .zero, "No time-based lag on a move event")
        XCTAssertTrue(gesture.dragging, "Moving back to the start must not turn a drag into a tap")
    }

    func testWaterAndMorphTouchesNeverStartABallDrag() {
        var gesture = OrbInteraction()
        gesture.begin(onBall: false)
        gesture.drag(CGSize(width: 200, height: -180))
        XCTAssertTrue(gesture.pressing)
        XCTAssertFalse(gesture.dragging)
        XCTAssertEqual(gesture.pull, .zero)
    }

    func testReleaseVelocityUsesReturnDirectionAndRubberBandDerivative() {
        XCTAssertEqual(OrbInteraction.returnVelocity(translation: CGSize(width: 130, height: 0),
                                                    velocity: CGSize(width: 130, height: 0)), -0.581976707, accuracy: 0.000001)
        XCTAssertEqual(OrbInteraction.returnVelocity(translation: CGSize(width: 0, height: -130),
                                                    velocity: CGSize(width: 0, height: 130)), 0.581976707, accuracy: 0.000001)
        XCTAssertEqual(OrbInteraction.returnVelocity(translation: .zero, velocity: CGSize(width: 500, height: 0)), 0)
    }
}
