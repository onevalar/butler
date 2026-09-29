import UIKit

/// System feedback only. Haptics never start, stop, or share the microphone's audio engine.
@MainActor
final class VoiceHaptics {
    static let preparationTimeout: TimeInterval = 5
    private let contact = UIImpactFeedbackGenerator(style: .light)
    private let ready = UIImpactFeedbackGenerator(style: .rigid)
    private let selection = UISelectionFeedbackGenerator()
    private let result = UINotificationFeedbackGenerator()
    private(set) var preparing = false

    nonisolated deinit {}

    func prepare() { contact.prepare(); ready.prepare(); selection.prepare(); result.prepare() }
    func touchDown() { contact.impactOccurred(intensity: 1); preparing = true; ready.prepare() }
    func stopPreparing() { preparing = false }
    func suspend() { stopPreparing() }
    func recordingReady() {
        guard preparing else { return }
        stopPreparing()
        ready.impactOccurred(intensity: 0.8)
        selection.prepare(); result.prepare()
    }
    func cancelBoundary() { selection.selectionChanged(); selection.prepare() }
    func cancelled() { stopPreparing(); contact.impactOccurred(intensity: 0.5); contact.prepare() }
    func sent() { stopPreparing(); result.notificationOccurred(.success); contact.prepare() }
    func failed() { stopPreparing(); result.notificationOccurred(.warning); contact.prepare() }
}
