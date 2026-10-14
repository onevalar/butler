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

/// A local surface indentation pushes glass radially outward. During a pull the
/// full body shifts upward into one rounded taper, without a second bulb or a thin filament.
struct VoiceGeometry: Sendable, Equatable {
    // Retain the input range for callers; it now controls pressure, never an ellipse width.
    var barWidth: CGFloat
    static let ballWidth: CGFloat = 62
    static let barWidth: CGFloat = 100
    var extent: CGFloat = 0
    var separation: CGFloat = 0
    static let reach: CGFloat = 100
    var pressure: CGFloat { max(0, min(1, (barWidth - 62) / 38)) }
    var transfer: CGFloat { Self.smooth(extent / 0.79) }
    /// The first response is the depression; peripheral displacement follows it.
    var spread: CGFloat { Self.smooth((pressure - 0.18) / 0.82) }
    var contactDepth: CGFloat { Self.smooth(pressure / 0.65) * (1 - transfer) }
    var area: CGFloat { .pi * 31 * 31 * (1 + 0.38 * spread * (1 - transfer)) }
    // Reconnecting during a fast downward drag must restore the body even if the
    // short separation animation has not caught up with the pointer yet.
    private var detachment: CGFloat { separation * Self.smooth(extent / 0.65) }
    var rootRadius: CGFloat { max(0.8 * transfer, 31 * sqrt(1 + 0.38 * spread) * pow(1 - transfer, 1.3)) * (1 - detachment) }
    var dropRadius: CGFloat { 31 * sqrt(transfer) }
    var zoneOffset: CGFloat { Self.reach * transfer + (1 - transfer) * (31 * sqrt(1 + 0.38 * spread) - dropRadius) }
    var rootY: CGFloat { -zoneOffset * detachment }
    var topReach: CGFloat { max(rootRadius - rootY, zoneOffset + dropRadius) }
    private var unboundedBottom: CGFloat { max(rootY + rootRadius, -zoneOffset + dropRadius) }
    /// Once the reference droplet is reached, further travel lifts the whole body.
    /// Fixed area plus unlimited height was making even a smooth curve look like a needle.
    var maximumSpan: CGFloat { 2 * sqrt(area / .pi) * 1.42 }
    var bottom: CGFloat {
        let naturalSpan = topReach + unboundedBottom
        let blend: CGFloat = 6
        let overlap = max(0, blend - abs(naturalSpan - maximumSpan))
        let boundedSpan = min(naturalSpan, maximumSpan) - overlap * overlap / (4 * blend)
        return boundedSpan - topReach
    }

    func contours(width: CGFloat, height: CGFloat, centerY: CGFloat) -> [[CGPoint]] {
        let count = 240
        let span = topReach + bottom
        let dy = span / CGFloat(count)
        // One rounded profile, instead of merging a small upper circle into a lower ball.
        // The latter creates the visible nipple/second bulb at the start of a pull.
        // A bounded bias shifts volume upward while preserving round end tangents;
        // there is no polynomial neck that can flatten into a long needle at the foot.
        let bias = 0.44 * transfer * (1 - detachment)
        let radii: [CGFloat] = (0...count).map { index in
            let v = 2 * CGFloat(index) / CGFloat(count) - 1
            return sqrt(max(0, 1 - v * v)) * (1 - bias * v)
        }
        let integral = dy * (radii.reduce(0, +) - (radii[0] + radii[count]) / 2) * 2
        let scale = area / max(0.001, integral)
        let right = radii.enumerated().map { index, radius in
            CGPoint(x: width / 2 + radius * scale, y: centerY - topReach + CGFloat(index) * dy)
        }
        return [right + right.reversed().map { CGPoint(x: width - $0.x, y: $0.y) }]
    }

    static func smooth(_ value: CGFloat) -> CGFloat {
        let x = max(0, min(1, value))
        return x * x * (3 - 2 * x)
    }
}

/// Shared trajectory for the released glass and its embedded cancellation mark.
struct VoiceReturnPose {
    var progress: CGFloat
    var fall: CGFloat { min(1, max(0, progress / 0.70)) }
    var offset: CGFloat { VoiceGeometry.reach * (1 - fall * fall) }
    var impact: CGFloat { 0.62 * exp(-pow((progress - 0.77) / 0.085, 2)) }
    var cancelOpacity: CGFloat { 1 - VoiceGeometry.smooth(progress / 0.60) }
    func centerY(dockY: CGFloat) -> CGFloat { dockY - offset }
}
