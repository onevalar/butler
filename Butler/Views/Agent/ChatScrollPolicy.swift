import Foundation
import Observation

/// Intent is changed by a native user scroll, never by content or keyboard layout alone.
@Observable final class ChatScrollPolicy {
    // No actor-bound cleanup; avoid an executor hop when a chat session releases its policy.
    nonisolated deinit {}

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
    @ObservationIgnored private var active = false
    @ObservationIgnored private var phase = Phase.idle
    @ObservationIgnored private var geometry: Geometry?
    @ObservationIgnored private var bottomVisible = false

    private(set) var showsReturnToLatest = false

    private func updateLatestVisibility() {
        let show = active && !bottomVisible && !followingBottom && (geometry?.distanceFromBottom ?? 0) > 24
        if showsReturnToLatest != show { showsReturnToLatest = show }
    }

    func bottomVisibilityChanged(_ visible: Bool) {
        bottomVisible = visible
        updateLatestVisibility()
    }

    private var userIsScrolling: Bool {
        phase == .tracking || phase == .interacting || phase == .decelerating
    }

    func appear(validTurnIDs: Set<UUID> = []) {
        defer { updateLatestVisibility() }
        active = true
        phase = .idle
        geometry = nil
        bottomVisible = false
        cancelPending()
        if !followingBottom, let visibleTurnID, validTurnIDs.contains(visibleTurnID) {
            // The scroll-position binding restores this message without a bottom jump.
            return
        }
        sendToLatest(animated: false)
    }

    func disappear() {
        defer { updateLatestVisibility() }
        active = false
        phase = .idle
        geometry = nil
        bottomVisible = false
        if followingBottom { visibleTurnID = nil }
        cancelPending()
    }

    func positionChanged(to id: UUID?) {
        // Footer/picker layouts may have no message target. Keep the last known
        // message rather than erasing a bookmark with a transient nil callback.
        guard active, let id else { return }
        if visibleTurnID != id { visibleTurnID = id }
    }

    func reconcileHistory(_ validTurnIDs: Set<UUID>) {
        if validTurnIDs.isEmpty || visibleTurnID.map({ !validTurnIDs.contains($0) }) == true {
            sendToLatest(animated: false)
        }
    }

    func sendToLatest(animated: Bool = true) {
        defer { updateLatestVisibility() }
        followingBottom = true
        visibleTurnID = nil
        // An explicit button/send action supersedes momentum from the old drag.
        // A subsequent new touch still cancels this request in phaseChanged.
        phase = .idle
        enqueue(animated ? .animated : .immediate)
    }

    func phaseChanged(to newPhase: Phase) {
        defer { updateLatestVisibility() }
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

    func geometryChanged(to new: Geometry) {
        defer { updateLatestVisibility() }
        guard active else { return }
        let old = geometry
        geometry = new

        if let old, (phase == .interacting || phase == .decelerating),
           new.hasSameLayout(as: old), abs(new.offset - old.offset) > 0.5 {
            // Ignore simultaneous content/viewport changes (including interactive keyboard
            // dismissal). Programmatic animation and idle offset corrections aren't intent.
            let follows = new.distanceFromBottom <= 24
            if followingBottom != follows { followingBottom = follows }
        }

        guard followingBottom, !userIsScrolling, new.distanceFromBottom > 1 else { return }
        if let old {
            // Native size-change anchoring owns keyboard / detent resizing. Do not
            // race it with another bottom jump against a transient lazy content size.
            guard new.containerHeight == old.containerHeight,
                  new.containerWidth == old.containerWidth,
                  new.topInset == old.topInset, new.bottomInset == old.bottomInset,
                  new.contentHeight != old.contentHeight else { return }
        }
        // Streaming and keyboard/composer geometry follow without restarting an
        // animation on every update. Only an explicit jump requests animation.
        enqueue(.immediate)
    }

    /// Consumed after one executor yield, so related state/layout notifications share a scroll.
    func takeScroll() -> Scroll? {
        guard active, followingBottom, !userIsScrolling else { return nil }
        defer { pending = nil }
        return pending
    }

    private func enqueue(_ scroll: Scroll) {
        guard active else { return }
        // Keyboard/composer layout must not acquire a second, custom animation.
        pending = pending == .immediate || scroll == .immediate ? .immediate : .animated
        revision += 1
    }

    private func cancelPending() {
        guard pending != nil else { return }
        pending = nil
        revision += 1
    }
}
