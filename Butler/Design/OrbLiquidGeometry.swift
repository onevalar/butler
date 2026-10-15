import Foundation
import SwiftUI

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

    /// Analytic form of the same rounded profile used by the reference contour.
    /// Its area is pi * radiusX * radiusY: the asymmetric term integrates to zero.
    func profile(centerY: CGFloat) -> VoiceProfile {
        let halfHeight = (topReach + bottom) / 2
        return VoiceProfile(centerY: centerY + (bottom - topReach) / 2,
                            radiusY: halfHeight, area: area,
                            bias: 0.44 * transfer * (1 - detachment))
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
    static let duration: Double = 0.36
    var fall: CGFloat { VoiceGeometry.smooth(progress / 0.65) }
    var offset: CGFloat { VoiceGeometry.reach * retainedDisplacement }
    var impact: CGFloat {
        let t = max(0, min(1, (progress - 0.60) / 0.40))
        return 0.34 * pow(sin(.pi * t), 2)
    }
    var cancelOpacity: CGFloat { 1 - VoiceGeometry.smooth(progress / 0.60) }
    func centerY(dockY: CGFloat) -> CGFloat { dockY - offset }
}

/// Sixteen tangent-continuous cubic segments replace 482 short straight edges.
/// Top/bottom retain horizontal tangents, including the rounded foot of the drop.
struct VoiceProfile: Equatable {
    var centerY: CGFloat
    var radiusY: CGFloat
    var area: CGFloat
    var bias: CGFloat
    var radiusX: CGFloat { area / (.pi * radiusY) }

    private static let samples: [(sin: CGFloat, cos: CGFloat)] = (0...16).map {
        let angle = CGFloat($0) * .pi / 8
        return (sin(angle), cos(angle))
    }

    func path(centerX: CGFloat) -> Path {
        let a = radiusX, h = radiusY, b = bias
        let tangentScale = CGFloat.pi / 24
        func point(_ t: (sin: CGFloat, cos: CGFloat)) -> CGPoint {
            CGPoint(x: centerX + a * t.sin * (1 + b * t.cos), y: centerY - h * t.cos)
        }
        func tangent(_ t: (sin: CGFloat, cos: CGFloat)) -> CGSize {
            CGSize(width: a * (t.cos + b * (t.cos * t.cos - t.sin * t.sin)) * tangentScale,
                   height: h * t.sin * tangentScale)
        }
        return Path { path in
            path.move(to: point(Self.samples[0]))
            for index in 1..<Self.samples.count {
                let p0 = point(Self.samples[index - 1]), p1 = point(Self.samples[index])
                let d0 = tangent(Self.samples[index - 1]), d1 = tangent(Self.samples[index])
                path.addCurve(to: p1, control1: CGPoint(x: p0.x + d0.width, y: p0.y + d0.height),
                              control2: CGPoint(x: p1.x - d1.width, y: p1.y - d1.height))
            }
            path.closeSubpath()
        }
    }
}

extension VoiceReturnPose {
    var retainedDisplacement: CGFloat { 1 - fall }
    var rounding: CGFloat { VoiceGeometry.smooth(progress / 0.28) }

    /// Begin at the actual released silhouette, even if separation is incomplete.
    /// Previously release immediately replaced it with a sphere at a fixed height.
    func profile(from source: VoiceProfile, dockY: CGFloat) -> VoiceProfile {
        let resting = VoiceGeometry(barWidth: 62 + 38 * impact).profile(centerY: dockY)
        return VoiceProfile(centerY: dockY + (source.centerY - dockY) * retainedDisplacement,
                            radiusY: source.radiusY + (resting.radiusY - source.radiusY) * rounding,
                            area: source.area + (resting.area - source.area) * rounding,
                            bias: source.bias * (1 - rounding))
    }
}

/// Every direction has immediate visual feedback. Cancellation remains vertical;
/// lateral/downward movement only displaces the held body against a soft tether.
enum VoiceDragResponse {
    static func offset(for translation: CGSize, reducedMotion: Bool = false) -> CGSize {
        // A single radial resistance preserves a diagonal's direction. Separate
        // tanh curves with different axis limits flattened lower-quadrant motion.
        let x = translation.width, y = max(0, translation.height)
        let xLimit: CGFloat = reducedMotion ? 12 : 36
        let yLimit: CGFloat = reducedMotion ? 5 : 14
        let distance = hypot(x / xLimit, y / yLimit)
        guard distance > 0 else { return .zero }
        let resistance = tanh(distance * 0.65) / distance
        return CGSize(width: max(-xLimit, min(xLimit, x * resistance)),
                      height: min(yLimit, y * resistance))
    }
}

/// A single area-preserving strain and rotation shared by the glass, light and mark.
/// Direction uses the real finger vector, not the saturated visual displacement.
struct VoiceDragDeformation {
    let translation: CGSize
    let extent: CGFloat
    var recovery: CGFloat = 1
    var contact = CGSize.zero

    /// Strain follows the tether from the moved glass to the current finger,
    /// including an off-centre initial press. Fade that offset in with movement
    /// so pressing near the rim alone does not suddenly stretch the whole ball.
    var pullVector: CGSize {
        let offset = VoiceDragResponse.offset(for: translation)
        let contactWeight = VoiceGeometry.smooth(hypot(translation.width, translation.height) / 20)
        return CGSize(width: translation.width - offset.width + contact.width * contactWeight,
                      height: translation.height - offset.height + contact.height * contactWeight)
    }

    var liftWeight: CGFloat { VoiceGeometry.smooth(extent / 0.65) }
    var angle: CGFloat {
        let up = max(0, -translation.height)
        let direction = atan2(translation.width, max(1, up))
        return max(-1.05, min(1.05, direction)) * VoiceGeometry.smooth(up / 24) * recovery
    }
    var strain: CGAffineTransform {
        // Preserve the approved upper-quadrant pull; below the dock the strain
        // axis is the current finger-to-glass direction, not just gesture origin.
        let lowerWeight = VoiceGeometry.smooth(translation.height / 20)
        let x = translation.width + (pullVector.width - translation.width) * lowerWeight
        let down = max(0, translation.height)
        let y = down + (pullVector.height - down) * lowerWeight
        let length = hypot(x, y)
        guard length > 0 else { return .identity }
        let u = x / length, v = y / length
        let movement = hypot(translation.width, max(0, translation.height))
        let stretch = 1 + 0.28 * tanh(movement / 65) * (1 - liftWeight) * recovery
        let inverse = 1 / stretch
        return CGAffineTransform(a: stretch * u * u + inverse * v * v,
                                 b: (stretch - inverse) * u * v,
                                 c: (stretch - inverse) * u * v,
                                 d: stretch * v * v + inverse * u * u, tx: 0, ty: 0)
    }
    var transform: CGAffineTransform { strain.concatenating(CGAffineTransform(rotationAngle: angle)) }
    func centeredTransform(in bounds: CGRect) -> CGAffineTransform {
        var t = transform
        t.tx = bounds.midX - t.a * bounds.midX - t.c * bounds.midY
        t.ty = bounds.midY - t.b * bounds.midX - t.d * bounds.midY
        return t
    }
    func center(profile: VoiceProfile, dock: CGPoint, offset: CGSize) -> CGPoint {
        let lift = dock.y - profile.centerY
        return CGPoint(x: dock.x + sin(angle) * lift + offset.width * (1 - liftWeight),
                       y: dock.y - cos(angle) * lift + offset.height)
    }
}
