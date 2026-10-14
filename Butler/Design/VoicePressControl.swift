import SwiftUI
import UIKit

/// A standard UIControl tracks contact immediately, without a gesture recognizer's threshold.
/// Shared by the production dock and isolated trial page.
struct VoicePressControl: UIViewRepresentable {
    var label = "试用语音输入"
    var hint = "双击开始，再次双击结束；也可以使用取消操作"
    var onDown: () -> Bool
    var onMove: (CGSize) -> Void
    var onUp: () -> Void
    var onCancel: () -> Void
    var onActivate: () -> Void
    var onVoiceActivate: (() -> Void)? = nil
    var onContact: ((CGPoint) -> Void)? = nil

    func makeUIView(context: Context) -> ContactControl { ContactControl() }
    func updateUIView(_ control: ContactControl, context: Context) {
        control.onContact = onContact
        control.onDown = onDown
        control.onMove = onMove
        control.onUp = onUp
        control.onCancel = onCancel
        control.onActivate = onActivate
        control.onVoiceActivate = onVoiceActivate
        control.accessibilityLabel = label
        control.accessibilityHint = hint
        control.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "取消", target: control, selector: #selector(ContactControl.accessibilityCancel))]
        if onVoiceActivate != nil {
            control.accessibilityCustomActions?.append(UIAccessibilityCustomAction(name: "开始或结束语音", target: control, selector: #selector(ContactControl.accessibilityVoice)))
        }
    }
    static func dismantleUIView(_ control: ContactControl, coordinator: ()) { control.cancelContact() }

    final class ContactControl: UIControl {
        var onContact: ((CGPoint) -> Void)?
        var onDown: (() -> Bool)?
        var onMove: ((CGSize) -> Void)?
        var onUp: (() -> Void)?
        var onCancel: (() -> Void)?
        var onActivate: (() -> Void)?
        var onVoiceActivate: (() -> Void)?
        private var origin: CGPoint?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isMultipleTouchEnabled = false
            isAccessibilityElement = true
            accessibilityLabel = "试用语音输入"
            accessibilityHint = "双击开始，再次双击结束；也可以使用取消操作"
            accessibilityTraits = .button
            accessibilityCustomActions = [UIAccessibilityCustomAction(name: "取消", target: self, selector: #selector(accessibilityCancel))]
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            let received = ProcessInfo.processInfo.systemUptime
            // Synchronous feedback is the first action; UI updates and microphone work follow it.
            guard onDown?() == true else { return false }
            onContact?(touch.location(in: self))
            origin = touch.location(in: window)
            let finished = ProcessInfo.processInfo.systemUptime
            ChatDiagnostics.log("voice trial: touch dispatch \(String(format: "%.1f", (received - touch.timestamp) * 1000))ms, handler \(String(format: "%.1f", (finished - received) * 1000))ms")
            return true
        }
        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            guard let origin else { return false }
            let point = touch.location(in: window)
            onMove?(CGSize(width: point.x - origin.x, height: point.y - origin.y))
            return true
        }
        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            guard let origin else { return }
            if let touch {
                let point = touch.location(in: window)
                onMove?(CGSize(width: point.x - origin.x, height: point.y - origin.y))
            }
            self.origin = nil
            onUp?()
        }
        override func cancelTracking(with event: UIEvent?) { cancelContact() }
        func cancelContact() {
            guard origin != nil else { return }
            origin = nil
            onCancel?()
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { cancelContact() }
        }
        override func accessibilityActivate() -> Bool { onActivate?(); return true }
        @objc func accessibilityCancel() -> Bool {
            if origin != nil { cancelContact() } else { onCancel?() }
            return true
        }
        @objc func accessibilityVoice() -> Bool { onVoiceActivate?(); return true }
        nonisolated deinit {}
    }
}
