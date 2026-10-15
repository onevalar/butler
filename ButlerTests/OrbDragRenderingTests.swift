import SwiftUI
import XCTest
@testable import Butler

final class OrbDragRenderingTests: XCTestCase {
    func testLateralAndDownwardFeedbackIsImmediateBoundedAndReversible() {
        for distance in stride(from: CGFloat(1), through: 500, by: 3) {
            let right = VoiceDragResponse.offset(for: CGSize(width: distance, height: 0))
            let left = VoiceDragResponse.offset(for: CGSize(width: -distance, height: 0))
            XCTAssertGreaterThan(right.width, 0)
            XCTAssertLessThanOrEqual(right.width, 36)
            XCTAssertEqual(left.width, -right.width, accuracy: 0.0001)
            let down = VoiceDragResponse.offset(for: CGSize(width: 0, height: distance))
            XCTAssertGreaterThan(down.height, 0)
            XCTAssertLessThanOrEqual(down.height, 14)
            XCTAssertEqual(VoiceGesture.extent(forTranslation: CGSize(width: distance, height: distance)), 0)
        }
        XCTAssertEqual(VoiceDragResponse.offset(for: .zero), .zero)
        XCTAssertEqual(VoiceDragResponse.offset(for: CGSize(width: 50, height: -100)).height, 0)
        let reduced = VoiceDragResponse.offset(for: CGSize(width: 500, height: 500), reducedMotion: true)
        XCTAssertLessThanOrEqual(reduced.width, 12)
        XCTAssertLessThanOrEqual(reduced.height, 5)
    }

    func testCompactCurveMatchesReferenceContourWithoutNeedles() {
        for extent in stride(from: CGFloat(0), through: 1, by: 0.025) {
            for separation: CGFloat in [0, 0.5, 1] {
                let geometry = VoiceGeometry(barWidth: 100, extent: extent, separation: separation)
                let path = geometry.profile(centerY: 266).path(centerX: 195)
                let box = path.boundingRect
                XCTAssertLessThanOrEqual(box.height / box.width, 2.02)
                let contour = geometry.contours(width: 390, height: 340, centerY: 266)[0]
                XCTAssertEqual(box.minY, contour.map(\.y).min()!, accuracy: 0.001)
                XCTAssertEqual(box.maxY, contour.map(\.y).max()!, accuracy: 0.001)
                XCTAssertEqual(box.width, contour.map(\.x).max()! - contour.map(\.x).min()!, accuracy: 0.06)
                // Interior/exterior sampling also checks the curved shoulder and rounded foot.
                for point in contour.dropFirst().dropLast() where abs(point.x - 195) > 1 {
                    let inward: CGFloat = point.x > 195 ? -0.15 : 0.15
                    guard path.cgPath.contains(CGPoint(x: point.x + inward, y: point.y)),
                          !path.cgPath.contains(CGPoint(x: point.x - inward, y: point.y)) else {
                        XCTFail("profile mismatch extent=\(extent), separation=\(separation), point=\(point), bounds=\(box)")
                        return
                    }
                }
            }
        }
    }

    func testReleaseStartsAtActualShapeAndEndsAtDockWithNoJump() {
        for extent: CGFloat in [0.79, 0.83, 0.95] {
            for separation: CGFloat in [0, 0.3, 1] {
                let source = VoiceGeometry(barWidth: 100, extent: extent, separation: separation).profile(centerY: 266)
                XCTAssertEqual(VoiceReturnPose(progress: 0).profile(from: source, dockY: 266), source)
                let rest = VoiceReturnPose(progress: 1).profile(from: source, dockY: 266)
                XCTAssertEqual(rest.centerY, 266, accuracy: 0.001)
                XCTAssertEqual(rest.radiusY, 31, accuracy: 0.001)
                XCTAssertEqual(rest.radiusX, 31, accuracy: 0.001)
                var previous = source.path(centerX: 195).boundingRect
                for frame in 1...120 {
                    let pose = VoiceReturnPose(progress: CGFloat(frame) / 120)
                    let current = pose.profile(from: source, dockY: 266).path(centerX: 195).boundingRect
                    XCTAssertLessThan(abs(current.midY - previous.midY), 3)
                    XCTAssertLessThan(abs(current.width - previous.width), 3)
                    XCTAssertLessThan(abs(current.height - previous.height), 3)
                    previous = current
                }
            }
        }
        XCTAssertEqual(VoiceReturnPose(progress: 0).retainedDisplacement, 1)
        XCTAssertEqual(VoiceReturnPose(progress: 1).retainedDisplacement, 0)
    }

    func testDirectionalStrainConservesAreaAndDiagonalPullTiltsBothWays() {
        for x: CGFloat in [-160, -65, -1, 0, 1, 65, 160] {
            for y: CGFloat in [-120, -55, 0, 35, 90] {
                let vector = CGSize(width: x, height: y)
                let extent = VoiceGesture.extent(forTranslation: vector)
                let pose = VoiceDragDeformation(translation: vector, extent: extent)
                let t = pose.transform
                XCTAssertEqual(t.a * t.d - t.b * t.c, 1, accuracy: 0.00001)
                let mirror = VoiceDragDeformation(translation: CGSize(width: -x, height: y), extent: extent)
                XCTAssertEqual(pose.angle, -mirror.angle, accuracy: 0.00001)
                if y < -24 && x != 0 { XCTAssertGreaterThan(pose.angle * x, 0) }
                let settled = VoiceDragDeformation(translation: vector, extent: extent, recovery: 0)
                XCTAssertEqual(settled.transform.a, 1, accuracy: 0.00001)
                XCTAssertEqual(settled.transform.d, 1, accuracy: 0.00001)
            }
        }
        let side = VoiceDragDeformation(translation: CGSize(width: 80, height: 0), extent: 0)
        XCTAssertGreaterThan(side.strain.a, 1.2)
        XCTAssertLessThan(side.strain.d, 0.85)
    }

    func testDiagonalReleaseHasContinuousPositionAndFinishesWithin360Milliseconds() {
        XCTAssertLessThanOrEqual(VoiceReturnPose.duration, 0.36)
        for x: CGFloat in [-100, 100] {
            let vector = CGSize(width: x, height: -90)
            let extent = VoiceGesture.extent(forTranslation: vector)
            let source = VoiceGeometry(barWidth: 100, extent: extent, separation: 1).profile(centerY: 266)
            let offset = VoiceDragResponse.offset(for: vector)
            var previous: CGPoint?
            for frame in 0...120 {
                let release = VoiceReturnPose(progress: CGFloat(frame) / 120)
                let deformation = VoiceDragDeformation(translation: vector, extent: extent, recovery: release.retainedDisplacement)
                let center = deformation.center(profile: release.profile(from: source, dockY: 266),
                    dock: CGPoint(x: 195, y: 266), offset: CGSize(width: offset.width * release.retainedDisplacement, height: 0))
                if let previous { XCTAssertLessThan(hypot(center.x - previous.x, center.y - previous.y), 6) }
                if frame == 0 { XCTAssertGreaterThan((center.x - 195) * x, 0) }
                if frame == 120 { XCTAssertEqual(center, CGPoint(x: 195, y: 266)) }
                previous = center
            }
        }
    }

    func testLowerQuadrantTravelPreservesFingerDirectionWithRadialResistance() {
        for degrees in stride(from: 1.0, through: 179, by: 2) {
            let radians: CGFloat = CGFloat(degrees) * .pi / 180
            for distance: CGFloat in [5, 20, 80, 250] {
                let vector = CGSize(width: cos(radians) * distance, height: sin(radians) * distance)
                for reduced in [false, true] {
                    let offset = VoiceDragResponse.offset(for: vector, reducedMotion: reduced)
                    XCTAssertEqual(offset.width * vector.height - offset.height * vector.width, 0, accuracy: 0.00001)
                    XCTAssertLessThanOrEqual(abs(offset.width), reduced ? 12 : 36)
                    XCTAssertLessThanOrEqual(offset.height, reduced ? 5 : 14)
                }
            }
        }
    }

    func testLowerQuadrantStrainAxisPointsTowardFingerIncludingOffCentreContact() {
        for x: CGFloat in [-120, -60, -15, 0, 15, 60, 120] {
            for y: CGFloat in [25, 50, 90] {
                for contact in [CGSize.zero, CGSize(width: -20, height: 24), CGSize(width: 18, height: -16)] {
                    let pose = VoiceDragDeformation(translation: CGSize(width: x, height: y), extent: 0, contact: contact)
                    let v = pose.pullVector
                    let stretched = CGPoint(x: v.width, y: v.height).applying(pose.strain)
                    // The long axis is parallel to the actual pull, with no horizontal bias.
                    XCTAssertEqual(stretched.x * v.height - stretched.y * v.width, 0, accuracy: 0.00001)
                    XCTAssertGreaterThan(hypot(stretched.x, stretched.y), hypot(v.width, v.height))
                    let t = pose.strain
                    XCTAssertEqual(t.a * t.d - t.b * t.c, 1, accuracy: 0.00001)
                }
            }
        }
        // Sweeping across horizontal does not switch coordinate models abruptly.
        for x: CGFloat in [-80, 80] {
            var previous: CGAffineTransform?
            for step in -100...300 {
                let pose = VoiceDragDeformation(translation: CGSize(width: x, height: CGFloat(step) / 10),
                    extent: 0, contact: CGSize(width: 10, height: 24))
                if let previous {
                    XCTAssertLessThan(abs(pose.transform.b - previous.b), 0.01)
                    XCTAssertLessThan(abs(pose.transform.a - previous.a), 0.01)
                }
                previous = pose.transform
            }
        }
    }

    func testGeometryConstructionComparison() {
        let count = 2_000
        var checksum: CGFloat = 0
        let start = ProcessInfo.processInfo.systemUptime
        for i in 0..<count {
            let geometry = VoiceGeometry(barWidth: 100, extent: CGFloat(i % 100) / 100)
            let path = Path { p in
                for points in geometry.contours(width: 390, height: 340, centerY: 266) {
                    p.addLines(points); p.closeSubpath()
                }
            }
            checksum += path.boundingRect.width
        }
        let reference = ProcessInfo.processInfo.systemUptime - start
        let optimizedStart = ProcessInfo.processInfo.systemUptime
        for i in 0..<count {
            let geometry = VoiceGeometry(barWidth: 100, extent: CGFloat(i % 100) / 100)
            checksum += geometry.profile(centerY: 266).path(centerX: 195).boundingRect.width
        }
        let optimized = ProcessInfo.processInfo.systemUptime - optimizedStart
        XCTAssertGreaterThan(checksum, 0)
        print("ORB_GEOMETRY synthetic \(count) frames: reference_ms=\(reference * 1_000) curves_ms=\(optimized * 1_000)")
    }
}
