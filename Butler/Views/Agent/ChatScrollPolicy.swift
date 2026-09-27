import Foundation

/// Intent is changed by a native user scroll, never by content or keyboard layout alone.
struct ChatScrollPolicy {
    struct Geometry: Equatable, Sendable {
        var offset: CGFloat
        var contentHeight: CGFloat
        var containerHeight: CGFloat
        var containerWidth: CGFloat
        var topInset: CGFloat
        var bottomInset: CGFloat

        var distanceFromBottom: CGFloat {
            max(0, contentHeight + bottomInset - containerHeight - offset)
        }

        func hasSameLayout(as other: Self) -> Bool {
            contentHeight == other.contentHeight && containerHeight == other.containerHeight
                && containerWidth == other.containerWidth && topInset == other.topInset
                && bottomInset == other.bottomInset
        }

        func hasSameViewport(as other: Self) -> Bool {
            containerHeight == other.containerHeight && containerWidth == other.containerWidth
                && topInset == other.topInset && bottomInset == other.bottomInset
        }
    }

    enum Phase { case idle, tracking, interacting, decelerating, animating }
    enum Scroll { case immediate, animated }

    private(set) var followingBottom = true
    private(set) var revision = 0
    private(set) var pending: Scroll?
    private var active = false
    private var phase = Phase.idle
    private var geometry: Geometry?

    private var userIsScrolling: Bool {
        phase == .tracking || phase == .interacting || phase == .decelerating
    }

    mutating func appear() {
        active = true
        phase = .idle
        geometry = nil
        followingBottom = true
        enqueue(.immediate)
    }

    mutating func disappear() {
        active = false
        cancelPending()
    }

    mutating func sendToLatest() {
        followingBottom = true
        enqueue(.animated)
    }

    mutating func phaseChanged(to newPhase: Phase) {
        let wasUserScrolling = userIsScrolling
        phase = newPhase
        if userIsScrolling {
            // A touch interrupts any queued automatic correction, even before it moves.
            cancelPending()
        } else if wasUserScrolling, newPhase == .idle, followingBottom,
                  let geometry, geometry.distanceFromBottom > 1 {
            enqueue(.immediate)
        }
    }

    mutating func geometryChanged(to new: Geometry) {
        let old = geometry
        geometry = new
        guard active else { return }

        if let old, (phase == .interacting || phase == .decelerating),
           new.hasSameLayout(as: old), abs(new.offset - old.offset) > 0.5 {
            // Ignore simultaneous content/viewport changes (including interactive keyboard
            // dismissal). Programmatic animation and idle offset corrections aren't intent.
            followingBottom = new.distanceFromBottom <= 24
        }

        guard followingBottom, !userIsScrolling, new.distanceFromBottom > 1 else { return }
        if let old {
            guard !new.hasSameLayout(as: old) else { return }
            enqueue(new.hasSameViewport(as: old) ? .animated : .immediate)
        } else {
            enqueue(.immediate)
        }
    }

    /// Consumed after one executor yield, so related state/layout notifications share a scroll.
    mutating func takeScroll() -> Scroll? {
        guard active, followingBottom, !userIsScrolling else { return nil }
        defer { pending = nil }
        return pending
    }

    private mutating func enqueue(_ scroll: Scroll) {
        guard active else { return }
        // Keyboard/composer layout must not acquire a second, custom animation.
        pending = pending == .immediate || scroll == .immediate ? .immediate : .animated
        revision += 1
    }

    private mutating func cancelPending() {
        pending = nil
        revision += 1
    }
}
