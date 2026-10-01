import AVFoundation
import XCTest
@testable import Butler

final class VoiceInteractionTests: XCTestCase {
    // MARK: Shape

    private func outline(_ geometry: VoiceGeometry, centerY: CGFloat = 266) -> [[CGPoint]] {
        geometry.contours(width: 390, height: 340, centerY: centerY)
    }

    func testTheBarIsOneRoundedPieceWithSemicircleEnds() {
        let geometry = VoiceGeometry(barWidth: 176)
        let contours = outline(geometry)
        XCTAssertEqual(contours.count, 1)
        let xs = contours[0].map(\.x), ys = contours[0].map(\.y)
        XCTAssertEqual(xs.min()!, 195 - 88, accuracy: 2)
        XCTAssertEqual(xs.max()!, 195 + 88, accuracy: 2)
        XCTAssertEqual(ys.max()! - ys.min()!, 62, accuracy: 2)
        // Semicircle ends: at the far end the outline is still round, not a point or a corner.
        let ends = contours[0].filter { $0.x > 195 + 88 - 6 }
        XCTAssertGreaterThan(ends.count, 4, "a rounded end has many points near its tip")
        XCTAssertLessThan((ends.map(\.y).max()! - ends.map(\.y).min()!), 40, "and stays inside the bar's height")
    }

    func testWidthOfTheBallIsACircle() {
        let geometry = VoiceGeometry(barWidth: VoiceGeometry.ballWidth)
        let box = outline(geometry)[0]
        XCTAssertEqual(box.map(\.x).max()! - box.map(\.x).min()!, 62, accuracy: 2)
        XCTAssertEqual(box.map(\.y).max()! - box.map(\.y).min()!, 62, accuracy: 2)
    }

    func testTheCancelZoneGrowsOutOfTheSameGlassAndNeverSeparates() {
        for extent in stride(from: CGFloat(0.02), through: 1, by: 0.02) {
            let geometry = VoiceGeometry(barWidth: 176, extent: extent)
            let contours = outline(geometry)
            XCTAssertEqual(contours.count, 1, "extent \(extent) must be one connected piece")
            let top = contours[0].map(\.y).min()!
            XCTAssertEqual(top, 266 - geometry.topReach, accuracy: 6, "extent \(extent): the melted joint may rise a few points above the estimate")
        }
        let grown = VoiceGeometry(barWidth: 176, extent: 1)
        XCTAssertEqual(grown.topReach, VoiceGeometry.reach + VoiceGeometry.zoneHeight / 2, accuracy: 0.5)
        // A neck: between the bar and the zone the glass is narrower than either.
        let contour = outline(grown)[0]
        func halfWidth(at y: CGFloat) -> CGFloat {
            let row = contour.filter { abs($0.y - y) < 1.5 }
            return (row.map(\.x).max() ?? 195) - 195
        }
        let neck = halfWidth(at: 266 - 78)
        XCTAssertLessThan(neck, halfWidth(at: 266))
        XCTAssertLessThan(neck, halfWidth(at: 266 - VoiceGeometry.reach))
        XCTAssertGreaterThan(neck, 8, "the neck is joined, not a thread")
    }

    func testTopReachOnlyGrowsWithTheFinger() {
        var previous: CGFloat = 0
        for extent in stride(from: CGFloat(0), through: 1, by: 0.05) {
            let reach = VoiceGeometry(barWidth: 176, extent: extent).topReach
            XCTAssertGreaterThanOrEqual(reach, previous - 0.001)
            previous = reach
        }
    }

    // MARK: Gesture

    func testOnlySlidingUpGrowsTheZoneAndDownOrSidewaysNeverCancels() {
        XCTAssertEqual(VoiceGesture.extent(forTranslation: CGSize(width: 0, height: 0)), 0)
        XCTAssertEqual(VoiceGesture.extent(forTranslation: CGSize(width: 0, height: 200)), 0, "down")
        XCTAssertEqual(VoiceGesture.extent(forTranslation: CGSize(width: 300, height: 0)), 0, "sideways")
        XCTAssertEqual(VoiceGesture.extent(forTranslation: CGSize(width: -300, height: 12)), 0)
        XCTAssertEqual(VoiceGesture.extent(forTranslation: CGSize(width: 0, height: -8)), 0, "a little wobble is ignored")
        XCTAssertEqual(VoiceGesture.extent(forTranslation: CGSize(width: 0, height: -400)), 1)
        let half = VoiceGesture.extent(forTranslation: CGSize(width: 0, height: -10 - VoiceGesture.travel / 2))
        XCTAssertEqual(half, 0.5, accuracy: 0.001)
        // Sliding sideways while up doesn't change how far up it is.
        XCTAssertEqual(VoiceGesture.extent(forTranslation: CGSize(width: 150, height: -60)),
                       VoiceGesture.extent(forTranslation: CGSize(width: -20, height: -60)))
    }

    func testCancelNeedsTheFingerInTheZoneAndSlidingBackUndoesIt() {
        XCTAssertFalse(VoiceGesture.cancels(extent: 0.5, wasCancelling: false))
        XCTAssertFalse(VoiceGesture.cancels(extent: 0.8, wasCancelling: false))
        XCTAssertTrue(VoiceGesture.cancels(extent: 0.9, wasCancelling: false))
        XCTAssertTrue(VoiceGesture.cancels(extent: 0.78, wasCancelling: true), "slack once in")
        XCTAssertFalse(VoiceGesture.cancels(extent: 0.6, wasCancelling: true), "back down: talking again")
        XCTAssertFalse(VoiceGesture.cancels(extent: 0, wasCancelling: true))
    }

    func testASlowTapIsATapButRealTalkingIsNot() {
        XCTAssertTrue(VoiceGesture.isSlowTap(listening: true, cancelling: false, heldFor: 0.2, heardSomething: false))
        XCTAssertFalse(VoiceGesture.isSlowTap(listening: true, cancelling: false, heldFor: 0.2, heardSomething: true))
        XCTAssertFalse(VoiceGesture.isSlowTap(listening: true, cancelling: false, heldFor: 0.9, heardSomething: false),
                       "a long hold that heard nothing still explains itself")
        XCTAssertFalse(VoiceGesture.isSlowTap(listening: true, cancelling: true, heldFor: 0.2, heardSomething: false))
        XCTAssertFalse(VoiceGesture.isSlowTap(listening: false, cancelling: false, heldFor: 0.05, heardSomething: false))
    }

    func testHoldStartsRecordingAlmostAtOnce() {
        XCTAssertEqual(OrbPress.holdDuration, 0.12, accuracy: 0.001)
        XCTAssertLessThan(OrbPress.holdDuration, VoiceGesture.tapGrace)
    }

    // MARK: Keeping what was said while the recognizer starts

    private func buffer(_ value: Float, frames: AVAudioFrameCount = 256) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = value }
        return buffer
    }

    func testAudioHeardBeforeTheRecognizerIsReadyIsReplayedFirstAndInOrder() {
        let relay = AudioRelay()
        let source = buffer(1)
        relay.push(source)
        source.floatChannelData![0][0] = 99 // the microphone reuses its buffers
        relay.push(buffer(2))
        relay.push(buffer(3))
        var heard: [Float] = []
        relay.attach { heard.append($0.floatChannelData![0][0]) }
        XCTAssertEqual(heard, [1, 2, 3], "the copy kept the first buffer's own content, in order")
        relay.push(buffer(4))
        relay.push(buffer(5))
        XCTAssertEqual(heard, [1, 2, 3, 4, 5], "after that, straight through")
    }

    func testNothingIsReplayedTwiceAndAttachWithoutBacklogIsFine() {
        let relay = AudioRelay()
        var heard = 0
        relay.attach { _ in heard += 1 }
        XCTAssertEqual(heard, 0)
        relay.push(buffer(1))
        XCTAssertEqual(heard, 1)
    }

    func testOverlappingPushesNeverRunTheConsumerConcurrently() {
        let relay = AudioRelay()
        let lock = NSLock()
        // All probe state is protected by lock, including inside the consumer.
        nonisolated(unsafe) var active = 0
        nonisolated(unsafe) var maximum = 0
        nonisolated(unsafe) var heard: [Float] = []
        relay.attach { buffer in
            lock.lock()
            active += 1
            maximum = max(maximum, active)
            lock.unlock()
            usleep(1_000) // Allow a competing push to enter if relay serialization is missing.
            lock.lock()
            heard.append(buffer.floatChannelData![0][0])
            active -= 1
            lock.unlock()
        }
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            relay.push(self.buffer(Float(index), frames: 64))
        }
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(heard.count, 100)
        XCTAssertEqual(Set(heard), Set((0..<100).map { Float($0) }))
    }

    func testTheRelayKeepsUpWhilePushedFromAnotherThread() {
        let relay = AudioRelay()
        let lock = NSLock()
        var heard: [Float] = []
        let done = expectation(description: "pushed")
        DispatchQueue.global().async {
            for value in 1...400 {
                relay.push(self.buffer(Float(value), frames: 64))
                if value == 150 { usleep(2_000) }
            }
            done.fulfill()
        }
        usleep(1_500)
        relay.attach { buffer in
            lock.lock(); heard.append(buffer.floatChannelData![0][0]); lock.unlock()
        }
        wait(for: [done], timeout: 10)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(heard.count, 400)
        XCTAssertEqual(heard, heard.sorted(), "never out of order, whichever side of the switch a buffer landed on")
        XCTAssertEqual(heard.first, 1)
        XCTAssertEqual(heard.last, 400)
    }
}
