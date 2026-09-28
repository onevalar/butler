import Foundation
import XCTest
@testable import Butler

final class OrbPressTests: XCTestCase {
    func testPressRespondsBeforeHoldThresholdAndBuildsResistance() {
        var press = OrbPress()
        press.begin(at: CGPoint(x: -0.8, y: -0.3), time: 10)
        XCTAssertEqual(press.depth(at: 10), 0.18, accuracy: 0.00001)
        XCTAssertGreaterThan(press.depth(at: 10.1), 0.6)
        XCTAssertGreaterThan(press.depth(at: 10.35), 0.95)
        XCTAssertLessThan(press.depth(at: 10.35), 1)
        let earlyGain = press.depth(at: 10.1) - press.depth(at: 10)
        let lateGain = press.depth(at: 10.3) - press.depth(at: 10.2)
        XCTAssertGreaterThan(earlyGain, lateGain * 3)
    }

    func testEarlyReleaseAndRepressPreserveCurrentDepth() {
        var press = OrbPress()
        press.begin(at: CGPoint(x: 0.7, y: 0), time: 0)
        let before = press.depth(at: 0.12)
        press.release(at: 0.12)
        XCTAssertEqual(press.depth(at: 0.12), before)
        XCTAssertLessThan(press.depth(at: 0.3), before * 0.1)
        let returning = press.depth(at: 0.15)
        press.begin(at: CGPoint(x: -0.7, y: 0), time: 0.15)
        XCTAssertEqual(press.depth(at: 0.15), returning)
        XCTAssertEqual(press.contact.x, -0.7)
        press.release(at: 0.18, animated: false)
        XCTAssertEqual(press.depth(at: 0.18), 0)
        XCTAssertFalse(press.held)
    }

    func testContactClampsRadiallyWithoutLosingDirection() {
        var press = OrbPress()
        press.move(to: CGPoint(x: 3, y: -4))
        XCTAssertEqual(press.contact.x, 0.6, accuracy: 0.00001)
        XCTAssertEqual(press.contact.y, -0.8, accuracy: 0.00001)
    }

    func testLeftPressDentsLeftAndDisplacesShouldersRatherThanScaling() {
        let outline = OrbPress.outline(radius: 32, contact: CGPoint(x: -1, y: 0), depth: 1)
        XCTAssertGreaterThan(outline[96].x, -26, "Left contact is pressed inward")
        XCTAssertGreaterThan(outline[48].y, 32, "Displaced surface bulges at the shoulder")
        XCTAssertGreaterThan(outline[0].x, 30, "The opposite side must not shrink like a scale effect")
        let mirrored = OrbPress.outline(radius: 32, contact: CGPoint(x: 1, y: 0), depth: 1)
        XCTAssertEqual(outline[96].x, -mirrored[0].x, accuracy: 0.00001)
    }

    func testSurfaceAreaDoesNotInflateDuringPress() {
        for contact in [CGPoint.zero, CGPoint(x: -0.8, y: 0.3), CGPoint(x: 0, y: -1)] {
            for depth: CGFloat in [0, 0.18, 0.6, 1] {
                let points = OrbPress.outline(radius: 32, contact: contact, depth: depth)
                let area = points.indices.reduce(CGFloat.zero) { sum, i in
                    let a = points[i], b = points[(i + 1) % points.count]
                    return sum + (a.x * b.y - b.x * a.y) / 2
                }
                XCTAssertEqual(area, .pi * 32 * 32, accuracy: 0.01)
            }
        }
    }
}
