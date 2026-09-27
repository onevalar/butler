import Foundation

/// One reversible path from a suspended drop to the dock. The geometry, not two
/// overlapping glass layers, makes and breaks the neck at the contact point.
struct OrbPose: Sendable {
    var ballY: CGFloat
    var scaleX: CGFloat
    var scaleY: CGFloat
    var water: CGFloat
    var spread: CGFloat
    var side: CGFloat
    var peak: CGFloat

    static let duration: Double = 0.95
    static let restSide: CGFloat = 28
    static let restPeak: CGFloat = 60
    static let ballLift: CGFloat = 74

    static func at(_ progress: CGFloat) -> OrbPose {
        let p = max(0, min(1, progress))
        let drop = min(1, p / 0.38)
        let impact = smooth((p - 0.38) / 0.36)
        let water = smooth((p - 0.24) / 0.42)
        // The front moves first; the corners only fill once it reaches them.
        let spread = 1 - pow(1 - smooth((p - 0.32) / 0.68), 2)
        let floor = -18 + 18 * smooth((p - 0.18) / 0.16)
        return OrbPose(
            ballY: 43 * drop * drop + 64 * impact,
            scaleX: 1 - 0.12 * smooth(drop) + 1.1 * impact,
            scaleY: 1 + 0.2 * smooth(drop) - 0.88 * impact,
            water: water, spread: spread,
            side: floor + restSide * smooth((p - 0.68) / 0.32),
            peak: floor + restPeak * smooth((p - 0.25) / 0.30))
    }

    private static func smooth(_ value: CGFloat) -> CGFloat {
        let x = max(0, min(1, value))
        return x * x * x * (x * (x * 6 - 15) + 10)
    }
}

/// Symmetric liquid cross-section. A smooth union of the drop and a bottom
/// surface forms a neck before contact and lets it pinch off on the way back.
/// The bottom surface extends offscreen: there are no vertical end caps in view.
struct OrbLiquidGeometry: Sendable {
    var pose: OrbPose
    var radius: CGFloat = 64 * 0.485

    func distance(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGFloat {
        let rx = radius * pose.scaleX
        let ry = radius * pose.scaleY
        let centerY = height - OrbPose.ballLift + pose.ballY + radius - ry
        let ball = (hypot(x / rx, (y - centerY) / ry) - 1) * min(rx, ry)
        let reach = 48 + (width / 2 - 48) * pose.spread
        let shoulder = max(0, 1 - pow(x / reach, 2))
        let surface = height - pose.side - (pose.peak - pose.side) * pow(shoulder, 3)
        let pool = surface - y
        // Polynomial smooth minimum: unchanged away from the contact region.
        let neck: CGFloat = 16
        let h = max(0, neck - abs(ball - pool)) / neck
        return min(ball, pool) - h * h * neck / 4
    }

    /// Trace both sides of every connected band. Horizontal slices are monotone
    /// in |x|, so bisection avoids a full 2D marching-squares grid each frame.
    func contours(width: CGFloat, height: CGFloat) -> [[CGPoint]] {
        let limit = width / 2 + 32
        var result: [[CGPoint]] = []
        var right: [CGPoint] = []
        func finish() {
            guard !right.isEmpty else { return }
            result.append(right + right.reversed().map { CGPoint(x: width - $0.x, y: $0.y) })
            right.removeAll(keepingCapacity: true)
        }
        var previousY: CGFloat = -32
        var previousInside = false
        for row in 0...Int(ceil(height + 64)) {
            let y = CGFloat(row) - 32
            let inside = distance(x: 0, y: y, width: width, height: height) <= 0
            if inside != previousInside {
                // Resolve the tip between scanlines, rather than closing with a
                // horizontal one-point-wide slice at the top/bottom of the ball.
                var lo = previousY
                var hi = y
                for _ in 0..<12 {
                    let mid = (lo + hi) / 2
                    if (distance(x: 0, y: mid, width: width, height: height) <= 0) == previousInside {
                        lo = mid
                    } else {
                        hi = mid
                    }
                }
                right.append(CGPoint(x: width / 2, y: (lo + hi) / 2))
                if !inside { finish() }
            }
            if inside {
                var lo: CGFloat = 0
                var hi = limit
                for _ in 0..<14 {
                    let mid = (lo + hi) / 2
                    if distance(x: mid, y: y, width: width, height: height) <= 0 {
                        lo = mid
                    } else {
                        hi = mid
                    }
                }
                right.append(CGPoint(x: width / 2 + (lo + hi) / 2, y: y))
            }
            previousY = y
            previousInside = inside
        }
        finish()
        return result
    }
}
