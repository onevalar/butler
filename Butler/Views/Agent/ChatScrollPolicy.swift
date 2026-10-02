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

    }

    enum Phase { case idle, tracking, interacting, decelerating, animating }
    enum Scroll { case immediate, animated }

    private(set) var followingBottom = true
    private(set) var revision = 0
    private(set) var pending: Scroll?
    /// Session-local message anchor, not a pixel offset or synced reading receipt.
    private(set) var visibleTurnID: UUID?
    private var active = false
    private var phase = Phase.idle
    private var geometry: Geometry?

    var showsReturnToLatest: Bool { active && !followingBottom }

    private var userIsScrolling: Bool {
        phase == .tracking || phase == .interacting || phase == .decelerating
    }

    mutating func appear(validTurnIDs: Set<UUID> = []) {
        active = true
        phase = .idle
        geometry = nil
        cancelPending()
        if !followingBottom, let visibleTurnID, validTurnIDs.contains(visibleTurnID) {
            // The scroll-position binding restores this message without a bottom jump.
            return
        }
        sendToLatest(animated: false)
    }

    mutating func disappear() {
        active = false
        phase = .idle
        geometry = nil
        if followingBottom { visibleTurnID = nil }
        cancelPending()
    }

    mutating func positionChanged(to id: UUID?) {
        // Footer/picker layouts may have no message target. Keep the last known
        // message rather than erasing a bookmark with a transient nil callback.
        guard active, let id else { return }
        visibleTurnID = id
    }

    mutating func reconcileHistory(_ validTurnIDs: Set<UUID>) {
        if validTurnIDs.isEmpty || visibleTurnID.map({ !validTurnIDs.contains($0) }) == true {
            sendToLatest(animated: false)
        }
    }

    mutating func sendToLatest(animated: Bool = true) {
        followingBottom = true
        visibleTurnID = nil
        // An explicit button/send action supersedes momentum from the old drag.
        // A subsequent new touch still cancels this request in phaseChanged.
        phase = .idle
        enqueue(animated ? .animated : .immediate)
    }

    mutating func phaseChanged(to newPhase: Phase) {
        guard active else { return }
        let wasUserScrolling = userIsScrolling
        phase = newPhase
        // A real drag pauses following even if streamed text changes the layout
        // in the very same frame. Merely touching the view does not change intent.
        if newPhase == .interacting { followingBottom = false }
        if userIsScrolling {
            // A touch interrupts any queued automatic correction, even before it moves.
            cancelPending()
        } else if wasUserScrolling, newPhase == .idle, followingBottom,
                  let geometry, geometry.distanceFromBottom > 1 {
            enqueue(.immediate)
        }
    }

    mutating func geometryChanged(to new: Geometry) {
        guard active else { return }
        let old = geometry
        geometry = new

        if let old, (phase == .interacting || phase == .decelerating),
           new.hasSameLayout(as: old), abs(new.offset - old.offset) > 0.5 {
            // Ignore simultaneous content/viewport changes (including interactive keyboard
            // dismissal). Programmatic animation and idle offset corrections aren't intent.
            followingBottom = new.distanceFromBottom <= 24
        }

        guard followingBottom, !userIsScrolling, new.distanceFromBottom > 1 else { return }
        if let old {
            guard !new.hasSameLayout(as: old) else { return }
        }
        // Streaming and keyboard/composer geometry follow without restarting an
        // animation on every update. Only an explicit jump requests animation.
        enqueue(.immediate)
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
