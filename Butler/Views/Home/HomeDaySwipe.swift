import Observation
import SwiftUI
import UIKit

/// One touch can browse a day or open a row, never both. This survives the pan recognizer's reset
/// because SwiftUI may deliver a Button action after UIKit has already delivered the pan's end.
@MainActor @Observable
final class HomeDayInteraction {
    private(set) var offset: CGFloat = 0
    private(set) var allowsTap = true
    private var startingDay: Date?

    nonisolated deinit {}

    func touchBegan() {
        allowsTap = true
        startingDay = nil
        offset = 0
    }

    func touchMoved(_ movement: CGPoint) {
        if hypot(movement.x, movement.y) >= 10 { allowsTap = false }
    }

    static func isHorizontal(_ velocity: CGPoint) -> Bool {
        abs(velocity.x) > 0 && abs(velocity.x) > abs(velocity.y) * 1.5
    }

    func begin(day: Date) {
        allowsTap = false
        startingDay = day
    }

    func move(_ x: CGFloat) {
        guard startingDay != nil else { return }
        offset = min(64, max(-64, x * 0.4))
    }

    func finish(translation: CGFloat, velocity: CGFloat, calendar: Calendar = .current) -> Date? {
        defer { startingDay = nil; offset = 0 }
        guard let day = startingDay else { return nil }
        let farEnough = abs(translation) >= 56
        let flick = abs(translation) >= 24 && abs(velocity) >= 500 && translation * velocity > 0
        guard farEnough || flick else { return nil }
        return calendar.date(byAdding: .day, value: translation < 0 ? 1 : -1, to: day)
    }

    func cancel() {
        startingDay = nil
        offset = 0
        allowsTap = false
    }
}

/// Reject vertical movement before recognition so scrolling wins; cancel row touches once a
/// horizontal pan wins. The recognizer is attached to the stationary list container, not its
/// translated rows, so movement is measured in stable window coordinates in both directions.
struct HomeDaySwipe: UIGestureRecognizerRepresentable {
    let interaction: HomeDayInteraction
    let day: Date
    let isEnabled: Bool
    let onPick: (Date) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> DayPanRecognizer {
        let pan = DayPanRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        pan.delegate = context.coordinator
        configure(pan)
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: DayPanRecognizer, context: Context) {
        configure(recognizer)
    }

    private func configure(_ recognizer: DayPanRecognizer) {
        recognizer.onTouchBegan = { interaction.touchBegan() }
        recognizer.onTouchMoved = { interaction.touchMoved($0) }
        if recognizer.isEnabled != isEnabled { recognizer.isEnabled = isEnabled }
    }

    func handleUIGestureRecognizerAction(_ recognizer: DayPanRecognizer, context: Context) {
        guard isEnabled else { interaction.cancel(); return }
        let translation = recognizer.translation(in: nil).x
        switch recognizer.state {
        case .began:
            interaction.begin(day: day)
            interaction.move(translation)
        case .changed:
            interaction.move(translation)
        case .ended:
            if let next = interaction.finish(translation: translation, velocity: recognizer.velocity(in: nil).x) {
                ChatDiagnostics.log("home day swipe committed direction=\(next > day ? 1 : -1)")
                onPick(next)
            }
        case .cancelled, .failed:
            interaction.cancel()
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        nonisolated deinit {}
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            return HomeDayInteraction.isHorizontal(pan.velocity(in: nil))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Vertical scrolling waits only until our direction check rejects a vertical pan.
            guard let scroll = otherGestureRecognizer.view as? UIScrollView else { return false }
            return otherGestureRecognizer === scroll.panGestureRecognizer
        }
    }

    final class DayPanRecognizer: UIPanGestureRecognizer {
        var onTouchBegan: () -> Void = {}
        var onTouchMoved: (CGPoint) -> Void = { _ in }
        private var origin: CGPoint?

        nonisolated deinit {}

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if origin == nil, let touch = touches.first {
                origin = touch.location(in: nil)
                onTouchBegan()
            }
            super.touchesBegan(touches, with: event)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            track(touches)
            super.touchesMoved(touches, with: event)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            track(touches)
            super.touchesEnded(touches, with: event)
        }

        private func track(_ touches: Set<UITouch>) {
            guard let origin, let touch = touches.first else { return }
            let location = touch.location(in: nil)
            onTouchMoved(CGPoint(x: location.x - origin.x, y: location.y - origin.y))
        }

        override func reset() {
            origin = nil
            // Do not clear interaction.allowsTap here: the release must not click the next row.
            super.reset()
        }
    }
}
