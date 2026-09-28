import Foundation

/// A time-driven indentation, not pressure sensing. A touch responds immediately;
/// continued contact builds resistance and release relaxes from the current depth.
struct OrbPress: Sendable {
    static let holdDuration: TimeInterval = 0.35
    private(set) var contact: CGPoint = .zero // normalized relative to the ball centre
    private(set) var held = false
    private var changedAt: TimeInterval = 0
    private var initial: CGFloat = 0

    func depth(at time: TimeInterval) -> CGFloat {
        let elapsed = max(0, time - changedAt)
        if held { return 1 - (1 - initial) * exp(-elapsed / 0.12) }
        let t = elapsed / 0.045
        return initial * (1 + t) * exp(-t)
    }

    mutating func begin(at point: CGPoint, time: TimeInterval) {
        initial = max(0.18, depth(at: time))
        changedAt = time
        held = true
        move(to: point)
    }

    mutating func move(to point: CGPoint) {
        let distance = hypot(point.x, point.y)
        let divisor = max(1, distance)
        contact = CGPoint(x: point.x / divisor, y: point.y / divisor)
    }

    mutating func release(at time: TimeInterval, animated: Bool = true) {
        initial = animated ? depth(at: time) : 0
        changedAt = time
        held = false
    }

    /// An angular dent and displaced shoulders. Area normalization prevents a
    /// local press from inflating/deflating the entire orb. Central touches mostly
    /// affect the reflection, since their indentation points into the screen.
    static func outline(radius: CGFloat, contact: CGPoint, depth: CGFloat) -> [CGPoint] {
        let amount = max(0, min(1, depth)) * min(1, hypot(contact.x, contact.y))
        let direction = atan2(contact.y, contact.x)
        let count = 192
        var radii = [CGFloat]()
        for index in 0..<count {
            let angle = CGFloat(index) * 2 * .pi / CGFloat(count)
            let alignment = cos(angle - direction)
            let dent = exp((alignment - 1) * 9)
            let shoulders = exp((alignment - 0.35) * (alignment - 0.35) * -8)
            radii.append(1 + amount * (-0.25 * dent + 0.075 * shoulders))
        }
        let area = radii.indices.reduce(CGFloat.zero) { sum, index in
            sum + radii[index] * radii[(index + 1) % count] * sin(2 * .pi / CGFloat(count)) / 2
        }
        let normalizer = sqrt(.pi / area)
        return radii.enumerated().map { index, r in
            let angle = CGFloat(index) * 2 * .pi / CGFloat(count)
            return CGPoint(x: cos(angle) * radius * r * normalizer,
                           y: sin(angle) * radius * r * normalizer)
        }
    }
}
