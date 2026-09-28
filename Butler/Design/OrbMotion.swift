import Foundation
import CoreGraphics

/// The displayed pose is sampled once for drawing, touch geometry and contact feedback.
/// Reversing preserves the current position and scales the remaining travel time.
struct OrbMotion: Hashable, Sendable {
    private(set) var from: CGFloat = 0
    private(set) var target: CGFloat = 0
    private(set) var startedAt: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    func progress(at time: TimeInterval) -> CGFloat {
        guard duration > 0 else { return target }
        let fraction = max(0, min(1, (time - startedAt) / duration))
        return from + (target - from) * fraction
    }

    mutating func move(to spread: Bool, at time: TimeInterval, animated: Bool) {
        from = progress(at: time)
        target = spread ? 1 : 0
        startedAt = time
        duration = animated ? OrbPose.duration * abs(target - from) : 0
    }
}

/// Touch cancellation and ordinary release share the same reset, including the
/// offset. Keeping these values together prevents an interrupted drag sticking.
struct OrbInteraction: Sendable {
    private(set) var pressing = false
    private(set) var dragging = false
    private(set) var startedOnBall = false
    private(set) var pull: CGSize = .zero

    mutating func begin(onBall: Bool) {
        pressing = true
        startedOnBall = onBall
    }

    mutating func drag(_ translation: CGSize) {
        guard startedOnBall, dragging || hypot(translation.width, translation.height) > 10 else { return }
        dragging = true
        pull = Self.rubberBand(translation)
    }

    mutating func reset() { self = Self() }

    static func rubberBand(_ translation: CGSize) -> CGSize {
        let distance = hypot(translation.width, translation.height)
        guard distance > 0 else { return .zero }
        let eased = 44 * (1 - exp(-distance / 130))
        return CGSize(width: translation.width / distance * eased, height: translation.height / distance * eased)
    }

    /// Velocity along the return direction, in multiples of the remaining distance
    /// per second. Differentiate the rubber band, rather than using finger speed
    /// directly after the position has already been compressed.
    static func returnVelocity(translation: CGSize, velocity: CGSize) -> Double {
        let distance = hypot(translation.width, translation.height)
        guard distance > 0 else { return 0 }
        let radialSpeed = (translation.width * velocity.width + translation.height * velocity.height) / distance
        let decay = exp(-distance / 130)
        let displacement = 44 * (1 - decay)
        return -44 / 130 * decay * radialSpeed / displacement
    }
}
