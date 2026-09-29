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

    static let duration: Double = 0.75
    static let ballLift: CGFloat = 74

    static func at(_ progress: CGFloat, safeBottom: CGFloat = 34) -> OrbPose {
        let p = max(0, min(1, progress))
        let drop = min(1, p / 0.38)
        let impact = smooth((p - 0.38) / 0.36)
        // Preserve the downward velocity at contact instead of clamping the
        // fall and starting a second ease-in from rest.
        let sink = max(0, min(1, (p - 0.38) / 0.42))
        let tangent = (2 * 43 / 0.38) * 0.42
        let sinkingY = 43 + tangent * (sink * sink * sink - 2 * sink * sink + sink)
            + 64 * (-2 * sink * sink * sink + 3 * sink * sink)
        let water = smooth((p - 0.24) / 0.42)
        // The front moves first; the corners only fill once it reaches them.
        let spread = 1 - pow(1 - smooth((p - 0.22) / 0.78), 2)
        let floor = -18 + 18 * smooth((p - 0.18) / 0.16)
        let inset = max(0, min(34, safeBottom))
        let restSide = max(6, inset * 0.65)
        let restPeak = max(18, inset + 10)
        // Keep the contact neck, then settle into a thinner pool as the front spreads.
        let settle = smooth((p - 0.55) / 0.45)
        return OrbPose(
            ballY: p < 0.38 ? 43 * drop * drop : sinkingY,
            scaleX: 1 - 0.12 * smooth(drop) + 1.1 * impact,
            scaleY: 1 + 0.2 * smooth(drop) - 0.88 * impact,
            water: water, spread: spread,
            side: floor + restSide * smooth((p - 0.68) / 0.32),
            peak: floor + 60 * smooth((p - 0.25) / 0.30) - (60 - restPeak) * settle)
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
        SymmetricContour.trace(width: width, height: height) { x, y in
            distance(x: x, y: y, width: width, height: height)
        }
    }
}

/// Outline of any shape that is symmetric about the vertical centre line and whose horizontal slices are
/// intervals around it. `distance` takes x measured from the centre line.
enum SymmetricContour {
    static func trace(width: CGFloat, height: CGFloat, distance: (CGFloat, CGFloat) -> CGFloat) -> [[CGPoint]] {
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
            let inside = distance(0, y) <= 0
            if inside != previousInside {
                // Resolve the tip between scanlines, rather than closing with a
                // horizontal one-point-wide slice at the top/bottom of the shape.
                var lo = previousY
                var hi = y
                for _ in 0..<12 {
                    let mid = (lo + hi) / 2
                    if (distance(0, mid) <= 0) == previousInside { lo = mid } else { hi = mid }
                }
                right.append(CGPoint(x: width / 2, y: (lo + hi) / 2))
                if !inside { finish() }
            }
            if inside {
                var lo: CGFloat = 0
                var hi = limit
                for _ in 0..<14 {
                    let mid = (lo + hi) / 2
                    if distance(mid, y) <= 0 { lo = mid } else { hi = mid }
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

/// The glass while the owner is speaking: the ball drawn out into a bar with round ends, and, while the finger
/// slides up, a cancel zone that grows out of the same glass on a smooth neck. One surface, never two pieces.
struct VoiceGeometry: Sendable, Equatable {
    /// Width of the bar; `ballWidth` is the ball itself.
    var barWidth: CGFloat
    var barHeight: CGFloat = 62
    static let ballWidth: CGFloat = 62
    static let bulgeWidth: CGFloat = 96
    /// Wide enough that both hands of bars show either side of a fingertip.
    static let barWidth: CGFloat = 176
    /// 0...1: how far the cancel zone has grown.
    var extent: CGFloat = 0
    /// Distance from the bar's centre to the zone's centre when fully grown.
    static let reach: CGFloat = 100
    static let zoneWidth: CGFloat = 96
    static let zoneHeight: CGFloat = 58
    /// The neck is the bar being drawn upward: a column that eases in slightly and ends in the zone.
    static let neckBase: CGFloat = 19
    static let neckTip: CGFloat = 16

    /// How far the top of the glass is above the bar's centre.
    var topReach: CGFloat {
        guard extent > 0.001 else { return barHeight / 2 }
        let grow = Self.smooth(extent)
        // The highest of the zone and the neck's rounded tip (the neck is wider than a small zone at first).
        let tip = Self.neckTip + 3 * grow
        return max(barHeight / 2, zoneOffset + max(8, Self.zoneHeight / 2 * grow, tip))
    }

    /// Centre of the zone above the bar's centre.
    var zoneOffset: CGFloat { barHeight / 2 + (Self.reach - barHeight / 2) * extent }

    /// Signed distance to the fused shape: inside is negative. `x` is from the centre line, `y` is downward,
    /// `centerY` is the bar's centre in the same space.
    func distance(x: CGFloat, y: CGFloat, centerY: CGFloat) -> CGFloat {
        let bar = Self.pill(x: x, y: y - centerY, halfWidth: barWidth / 2, halfHeight: barHeight / 2)
        guard extent > 0.001 else { return bar }
        let grow = Self.smooth(extent)
        let zoneY = centerY - zoneOffset
        let zone = Self.pill(x: x, y: y - zoneY, halfWidth: max(8, Self.zoneWidth / 2 * grow), halfHeight: max(8, Self.zoneHeight / 2 * grow))
        // The neck: a cone from the bar's middle up to the zone, thinning as it stretches.
        let tip = Self.neckTip + 3 * grow
        let neck = Self.cone(x: x, y: centerY - y, r1: Self.neckBase, r2: tip, height: max(zoneOffset, Self.neckBase - tip + 1))
        return Self.smoothMin(Self.smoothMin(bar, neck, 16), zone, 18)
    }

    func contours(width: CGFloat, height: CGFloat, centerY: CGFloat) -> [[CGPoint]] {
        SymmetricContour.trace(width: width, height: height) { x, y in distance(x: x, y: y, centerY: centerY) }
    }

    private static func pill(x: CGFloat, y: CGFloat, halfWidth: CGFloat, halfHeight: CGFloat) -> CGFloat {
        let radius = min(halfWidth, halfHeight)
        let dx = max(abs(x) - (halfWidth - radius), 0)
        let dy = max(abs(y) - (halfHeight - radius), 0)
        return hypot(dx, dy) - radius
    }

    /// Signed distance to two circles of different radius joined by their tangents; the second is `height` above the first.
    private static func cone(x: CGFloat, y: CGFloat, r1: CGFloat, r2: CGFloat, height h: CGFloat) -> CGFloat {
        let px = abs(x), py = y
        let b = (r1 - r2) / h
        let a = sqrt(max(0, 1 - b * b))
        let k = px * -b + py * a
        if k < 0 { return hypot(px, py) - r1 }
        if k > a * h { return hypot(px, py - h) - r2 }
        return px * a + py * b - r1
    }

    private static func smoothMin(_ a: CGFloat, _ b: CGFloat, _ k: CGFloat) -> CGFloat {
        let h = max(0, k - abs(a - b)) / k
        return min(a, b) - h * h * k / 4
    }

    private static func smooth(_ value: CGFloat) -> CGFloat {
        let x = max(0, min(1, value))
        return x * x * (3 - 2 * x)
    }
}
