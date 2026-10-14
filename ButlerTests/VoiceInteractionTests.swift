import AVFoundation
import XCTest
@testable import Butler

final class VoiceInteractionTests: XCTestCase {
    // MARK: Shape

    private func outline(_ geometry: VoiceGeometry, centerY: CGFloat = 266) -> [[CGPoint]] {
        geometry.contours(width: 390, height: 340, centerY: centerY)
    }

    func testContactIndentsBeforeThePerimeterExpandsRadially() {
        let contact = VoiceGeometry(barWidth: 66)
        XCTAssertGreaterThan(contact.contactDepth, 0)
        XCTAssertEqual(contact.spread, 0)
        var previousDiameter: CGFloat = 62
        for pressure in stride(from: CGFloat(0), through: 1, by: 0.05) {
            let geometry = VoiceGeometry(barWidth: 62 + 38 * pressure)
            let contour = outline(geometry)[0]
            let w = contour.map(\.x).max()! - contour.map(\.x).min()!
            let h = contour.map(\.y).max()! - contour.map(\.y).min()!
            XCTAssertEqual(w, h, accuracy: 0.2, "Radial displacement, never a horizontal squash")
            XCTAssertGreaterThanOrEqual(w + 0.01, previousDiameter)
            previousDiameter = w
        }
        XCTAssertGreaterThan(previousDiameter, 70)
        XCTAssertLessThan(previousDiameter, 74)
    }

    func testWidthOfTheBallIsACircle() {
        let geometry = VoiceGeometry(barWidth: VoiceGeometry.ballWidth)
        let box = outline(geometry)[0]
        XCTAssertEqual(box.map(\.x).max()! - box.map(\.x).min()!, 62, accuracy: 2)
        XCTAssertEqual(box.map(\.y).max()! - box.map(\.y).min()!, 62, accuracy: 2)
    }

    func testPullTransfersAreaAndEmptiesTheOriginalDock() {
        var previousWidth: CGFloat = 73
        for frame in 0...100 {
            let geometry = VoiceGeometry(barWidth: 100, extent: CGFloat(frame) / 100)
            let contour = outline(geometry)[0]
            var area: CGFloat = 0
            for index in contour.indices {
                let a = contour[index], b = contour[(index + 1) % contour.count]
                area += a.x * b.y - b.x * a.y
            }
            XCTAssertEqual(abs(area) / 2, geometry.area, accuracy: 1, "The cancel area comes from the bar")
            let width = (contour.map(\.x).max() ?? 0) - (contour.map(\.x).min() ?? 0)
            XCTAssertLessThan(abs(width - previousWidth), 6, "No frame-sized horizontal pop")
            previousWidth = width
        }
        let pulled = VoiceGeometry(barWidth: 100, extent: 0.83, separation: 1)
        let contour = outline(pulled)[0]
        XCTAssertLessThan(contour.map(\.y).max()!, 266 - 60, "Original horizontal bar is completely gone when cancel is selected")
        XCTAssertEqual(pulled.topReach, VoiceGeometry.reach + pulled.dropRadius, accuracy: 0.01)
        let half = outline(VoiceGeometry(barWidth: 100, extent: 0.5))[0]
        let midY = (half.map(\.y).max()! + half.map(\.y).min()!) / 2
        let upper = half.filter { $0.y < midY }.map { abs($0.x - 195) }.max()!
        let lower = half.filter { $0.y > midY }.map { abs($0.x - 195) }.max()!
        XCTAssertGreaterThan(upper, lower, "Pulled droplet has a round head and a smaller lower tail")
        XCTAssertEqual(outline(pulled), outline(VoiceGeometry(barWidth: 100, extent: 0.83, separation: 1)), "Shape depends only on drag position, so reversing is continuous")
    }

    func testMaximumPullStaysPlumpAndLiftsInsteadOfStretchingIntoANeedle() {
        for frame in 0...100 {
            for separation in [CGFloat(0), 0.5, 1] {
                let shape = VoiceGeometry(barWidth: 100, extent: CGFloat(frame) / 100, separation: separation)
                let points = outline(shape)[0]
                let width = points.map(\.x).max()! - points.map(\.x).min()!
                let height = points.map(\.y).max()! - points.map(\.y).min()!
                XCTAssertLessThanOrEqual(height / width, 2.02, "Reference droplet is the maximum stretch, not an intermediate frame")
                let bottom = points.map(\.y).max()!
                let nearTip = points.filter { abs($0.y - (bottom - 4)) < 0.5 }.map { abs($0.x - 195) }.max() ?? 0
                XCTAssertGreaterThan(nearTip, 4, "The last four points must have a rounded cap, not a sharp tip")
            }
        }
        let beforeLimit = VoiceGeometry(barWidth: 100, extent: 0.55)
        let fullPull = VoiceGeometry(barWidth: 100, extent: 0.79)
        XCTAssertLessThan(fullPull.bottom, beforeLimit.bottom, "After reaching the shape limit, the bottom rises with the body")
        XCTAssertLessThan(fullPull.topReach + fullPull.bottom, 89)
    }

    func testConeShoulderAndRetractionStayContinuous() {
        func radius(_ geometry: VoiceGeometry, y: CGFloat) -> CGFloat {
            let points = outline(geometry)[0].filter { $0.x >= 195 }.sorted { $0.y < $1.y }
            for (a, b) in zip(points, points.dropFirst()) where a.y <= y && b.y >= y && b.y > a.y {
                return a.x - 195 + (b.x - a.x) * (y - a.y) / (b.y - a.y)
            }
            return 0
        }
        let pulled = VoiceGeometry(barWidth: 100, extent: 0.76)
        let shoulder = 266 - pulled.zoneOffset + pulled.dropRadius * 0.25
        let before = radius(pulled, y: shoulder) - radius(pulled, y: shoulder - 1)
        let after = radius(pulled, y: shoulder + 1) - radius(pulled, y: shoulder)
        XCTAssertEqual(before, after, accuracy: 0.08, "No abrupt circle-to-stem corner")
        var previous = outline(VoiceGeometry(barWidth: 100, extent: 0.9))[0].map(\.x).max()!
        for frame in 0...120 {
            let shape = VoiceGeometry(barWidth: 100, extent: 0.9, separation: CGFloat(frame) / 120)
            let width = outline(shape)[0].map(\.x).max()!
            XCTAssertLessThan(abs(width - previous), 1.5, "Retraction must not suddenly become a wide semicircle")
            previous = width
            XCTAssertGreaterThan(radius(shape, y: 266 - shape.zoneOffset + 12), 5,
                                 "The lower head cannot be cut off during retraction")
        }
    }

    func testCancellationMarkSharesTheFallingSphereAndFadesBeforeImpact() {
        var previousY: CGFloat = 166
        var previousOpacity: CGFloat = 1
        for frame in 0...100 {
            let pose = VoiceReturnPose(progress: CGFloat(frame) / 100)
            XCTAssertGreaterThanOrEqual(pose.centerY(dockY: 266), previousY)
            XCTAssertLessThanOrEqual(pose.cancelOpacity, previousOpacity)
            XCTAssertGreaterThanOrEqual(pose.cancelOpacity, 0)
            if pose.progress >= 0.6 { XCTAssertEqual(pose.cancelOpacity, 0) }
            previousY = pose.centerY(dockY: 266)
            previousOpacity = pose.cancelOpacity
        }
        XCTAssertEqual(VoiceReturnPose(progress: 0).centerY(dockY: 266), 166)
        XCTAssertEqual(VoiceReturnPose(progress: 1).centerY(dockY: 266), 266)
    }

    func testPullHasOneContinuousBellyWithoutASecondaryBudOrNeedle() {
        for frame in 0...100 {
            let geometry = VoiceGeometry(barWidth: 100, extent: CGFloat(frame) / 100)
            let side = Array(outline(geometry)[0].prefix(241))
            let widths = side.map { $0.x - 195 }
            let peak = widths.indices.max(by: { widths[$0] < widths[$1] })!
            for i in 1...peak { XCTAssertGreaterThanOrEqual(widths[i] + 0.0001, widths[i - 1]) }
            if peak < widths.count - 1 {
                for i in (peak + 1)..<widths.count { XCTAssertLessThanOrEqual(widths[i], widths[i - 1] + 0.0001) }
            }
            if frame > 65 {
                let bottom = side.last!.y
                let lower = side.filter { abs($0.y - (bottom - 8)) < 1 }.map { $0.x - 195 }.max()!
                XCTAssertGreaterThan(lower, 2, "Last 8 points retain visible volume instead of a hairline")
            }
        }
    }

    func testTopReachOnlyGrowsWithTheFinger() {
        var previous: CGFloat = 0
        for extent in stride(from: CGFloat(0), through: 1, by: 0.05) {
            let reach = VoiceGeometry(barWidth: 100, extent: extent).topReach
            XCTAssertGreaterThanOrEqual(reach, previous - 0.001)
            previous = reach
        }
    }

    func testCancelGrowthStartsInsideTheBarWithoutAFrameJump() {
        var previousTop: CGFloat = 266 - VoiceGeometry(barWidth: VoiceGeometry.barWidth).topReach
        for frame in 0...120 {
            let geometry = VoiceGeometry(barWidth: VoiceGeometry.barWidth, extent: CGFloat(frame) / 120)
            let points = outline(geometry).flatMap { $0 }
            let top = points.map(\.y).min()!
            XCTAssertLessThan(abs(top - previousTop), 2.5, "No pop as the cancel neck first appears, frame \(frame)")
            XCTAssertLessThanOrEqual(points.map(\.y).max()!, 303, "Only a shrinking root remains at the dock")
            previousTop = top
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
