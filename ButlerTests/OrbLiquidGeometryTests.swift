import Foundation
import XCTest
@testable import Butler

final class OrbLiquidGeometryTests: XCTestCase {
    func testRestingBallAndWaterKeepTheirExpectedBounds() {
        let ball = OrbLiquidGeometry(pose: .at(0))
        XCTAssertEqual(ball.distance(x: 0, y: 64.96, width: 390, height: 170), 0, accuracy: 0.001)
        XCTAssertEqual(ball.distance(x: 31.04, y: 96, width: 390, height: 170), 0, accuracy: 0.001)
        XCTAssertGreaterThan(ball.distance(x: 0, y: 150, width: 390, height: 170), 0)
        for width: CGFloat in [320, 393, 430, 768] {
            let water = OrbLiquidGeometry(pose: .at(1))
            XCTAssertEqual(water.distance(x: 0, y: 110, width: width, height: 170), 0, accuracy: 0.001)
            XCTAssertEqual(water.distance(x: width / 2, y: 142, width: width, height: 170), 0, accuracy: 0.001)
            XCTAssertLessThan(water.distance(x: width / 2, y: 160, width: width, height: 170), 0)
        }
    }

    func testDropAndSmallPoolJoinThroughANeckInsteadOfCrossfading() {
        func visible(_ p: CGFloat) -> [[CGPoint]] {
            OrbLiquidGeometry(pose: .at(p)).contours(width: 390, height: 170)
                .filter { $0.contains { $0.y < 170 } }
        }
        XCTAssertEqual(visible(0.30).count, 2, "Drop and small pool are still separate before contact")
        let joined = visible(0.35)
        XCTAssertEqual(joined.count, 1, "The neck joins the two surfaces")
        let points = joined.flatMap { $0 }
        let belly = points.filter { $0.y == 125 }.map { abs($0.x - 195) }.max() ?? 0
        let neck = points.filter { $0.y == 156 }.map { abs($0.x - 195) }.max() ?? 0
        XCTAssertGreaterThan(neck, 0)
        XCTAssertLessThan(neck, belly * 0.8, "A narrower neck, not just a scaled ellipse")
    }

    func testSpreadingFrontMeetsFloorWithoutAnUprightCap() {
        // Isolate a 48-point-radius pool with the ball fully below the screen.
        let pose = OrbPose(ballY: 200, scaleX: 1, scaleY: 1, water: 1, spread: 0, side: 0, peak: 42)
        let pool = OrbLiquidGeometry(pose: pose)
        XCTAssertLessThan(pool.distance(x: 47, y: 170, width: 390, height: 170), 0)
        XCTAssertEqual(pool.distance(x: 48, y: 170, width: 390, height: 170), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(pool.distance(x: 48, y: 169, width: 390, height: 170), 0)
        XCTAssertLessThan(abs(pool.distance(x: 47.9, y: 170, width: 390, height: 170)), 0.001,
                          "The surface becomes tangent to the floor at its moving front")
    }

    func testSampledOutlineStaysOnTheSurfaceWithoutInteriorClosingEdges() {
        for width: CGFloat in [320, 393, 768] {
            for frame in 0...120 {
                let g = OrbLiquidGeometry(pose: .at(CGFloat(frame) / 120))
                let contours = g.contours(width: width, height: 170)
                XCTAssertFalse(contours.isEmpty)
                for contour in contours {
                    for point in contour where point.x > 0 && point.x < width && point.y < 170 {
                        XCTAssertTrue(point.x.isFinite && point.y.isFinite)
                        XCTAssertEqual(g.distance(x: point.x - width / 2, y: point.y, width: width, height: 170),
                                       0, accuracy: 0.06, "frame \(frame), width \(width)")
                    }
                    // Closing edges must either join a tip or lie below the screen.
                    if let first = contour.first, let last = contour.last, first.y < 170 {
                        XCTAssertEqual(first, last)
                    }
                }
            }
        }
    }

    func testCrownDoesNotCollapseThenGrowBackDuringTheHandoff() {
        var previousTop: CGFloat = 64.96
        for frame in 0...120 {
            let points = OrbLiquidGeometry(pose: .at(CGFloat(frame) / 120))
                .contours(width: 393, height: 170).flatMap { $0 }
            let top = points.map(\.y).min() ?? 170
            XCTAssertLessThan(abs(top - previousTop), 4, "No frame-sized jump at the handoff")
            XCTAssertLessThan(top, 113, "No deep collapse followed by an expanding hump")
            previousTop = top
        }
    }
}
