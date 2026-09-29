import CoreMotion
import SwiftUI

/// The butler's one entry point: a glass ball floating over every screen.
/// Scrolling down lets it fall and spread along the bottom edge like water; tapping the
/// water (or scrolling back to the top) gathers it into a ball again.
@Observable
final class OrbDock {
    var spread = false
    var listening = false

    /// Called by scroll views with their offset from the top.
    func scrolled(from old: CGFloat, to new: CGFloat) {
        if new <= 12 {
            if spread { spread = false }
        } else if new - old > 4, new > 48, !spread {
            spread = true
        }
    }
}

extension View {
    /// Lets the orb spread while this scroll view is read further down, and gather at the top.
    func orbScrollTracking() -> some View { modifier(OrbScrollTracking()) }
}

private struct OrbScrollTracking: ViewModifier {
    @Environment(OrbDock.self) private var dock: OrbDock?

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { old, new in
                dock?.scrolled(from: old, to: new)
            }
            // A newly opened page starts at its top.
            .onAppear { if dock?.spread == true { dock?.spread = false } }
    }
}

/// Phone tilt, smoothed, for the orb's parallax.
@Observable
final class MotionTilt {
    private(set) var tilt: CGSize = .zero
    @ObservationIgnored private let manager = CMMotionManager()

    nonisolated deinit {}

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let gravity = motion?.gravity else { return }
            // Held upright the phone reads about -0.7 on y; treat that as level.
            let target = CGSize(width: max(-1, min(1, gravity.x)), height: max(-1, min(1, gravity.y + 0.7)))
            tilt = CGSize(width: tilt.width * 0.8 + target.width * 0.2, height: tilt.height * 0.8 + target.height * 0.2)
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}

// MARK: - Dock

/// Sits over the whole app. Tap the ball: talk to the butler. Hold it: speak, release to send, slide up to cancel.
/// Tap the spread water: it gathers back into a ball.
struct OrbDockView: View {
    var working: Bool
    var safeBottom: CGFloat = 34
    let onOpenChat: () -> Void
    let onSend: (String) -> Void
    var onBeginVoice: (() -> Void)? = nil

    @Environment(OrbDock.self) private var dock
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var motion = MotionTilt()
    @State private var dictation = LiveDictation()
    @State private var holdTask: Task<Void, Never>?
    @State private var finishTask: Task<Void, Never>?
    @State private var press = OrbPress()
    @State private var finishingVoice = false
    @State private var voiceMessage: String?
    @State private var interaction = OrbInteraction()
    @State private var cancelling = false
    @State private var travel = OrbMotion()
    @State private var moving = false
    /// The voice glass replaces the ball from the moment a finger lands on it: width 64 is the ball, 98 the first bulge, 176 the bar.
    @State private var voiceShown = false
    @State private var voiceWidth: CGFloat = VoiceGeometry.ballWidth
    /// 0...1, how far the cancel zone has grown; follows the finger while it slides up.
    @State private var cancelExtent: CGFloat = 0
    @State private var pressTick = 0
    @State private var releaseTick = 0
    @State private var pressBeganAt: TimeInterval = 0

    private var motionEnabled: Bool { !reduceMotion && scenePhase == .active }

    static let ballSize: CGFloat = 64
    /// Ball centre above the bottom edge of the screen.
    static let ballLift: CGFloat = OrbPose.ballLift
    static let areaHeight: CGFloat = 170
    /// Room above the ball for the cancel zone and everything that floats over it.
    static let voiceAreaHeight: CGFloat = 340

    var body: some View {
        ZStack(alignment: .bottom) {
            if dock.listening || finishingVoice || voiceMessage != nil {
                listeningOverlay.transition(.opacity)
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !motionEnabled || (!moving && dock.spread))) { _ in
                    let time = ProcessInfo.processInfo.systemUptime
                    OrbStage(progress: travel.progress(at: time),
                             width: width, height: Self.areaHeight,
                             safeBottom: safeBottom,
                             pressure: press.depth(at: time) * (reduceMotion ? 0.3 : 1),
                             contact: press.contact,
                             holding: press.held && !interaction.dragging,
                             preparingVoice: dock.listening && !dictation.listening && dictation.error == nil,
                             recording: dock.listening && dictation.listening,
                             audioLevel: reduceMotion || cancelling ? 0 : dictation.audioLevel,
                             cancelling: cancelling,
                             pull: interaction.pull,
                             breath: motionEnabled ? (sin(time * .pi / 2.4) + 1) / 2 : 0.5,
                             active: working || dictation.listening, tilt: motionEnabled ? motion.tilt : .zero,
                             feedbackEnabled: motionEnabled && moving,
                             hint: dock.spread ? "聚回成球" : moving ? "再次轻点可反向" : "点一下和管家对话，按住直接说话",
                             onChange: { dragChanged($0, width: width) }, onEnd: dragEnded,
                             onCancel: { cancelInteraction(animated: motionEnabled) },
                             onActivate: activate,
                             hidden: voiceShown)
                }
            }
            .frame(height: Self.areaHeight)
            if voiceShown {
                GeometryReader { proxy in
                    VoiceGlass(width: proxy.size.width, height: Self.voiceAreaHeight, barWidth: voiceWidth,
                               extent: cancelExtent, level: reduceMotion ? 0 : dictation.audioLevel,
                               recording: dock.listening && dictation.listening, cancelling: cancelling, tilt: motionEnabled ? motion.tilt : .zero)
                }
                .frame(height: Self.voiceAreaHeight)
                .allowsHitTesting(false)
                .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(edges: .bottom)
        .ignoresSafeArea(.keyboard)
        // A finger covers the ball, so the first sign that it heard you is in the hand.
        .sensoryFeedback(.impact(weight: .light), trigger: pressTick)
        .sensoryFeedback(.selection, trigger: cancelling)
        .sensoryFeedback(.impact(weight: .light), trigger: releaseTick)
        .onChange(of: dock.spread) { _, spread in
            cancelInteraction(animated: false)
            travel.move(to: spread, at: ProcessInfo.processInfo.systemUptime, animated: motionEnabled)
            moving = travel.duration > 0
        }
        .task(id: travel) {
            // Only stops the display clock. Feedback comes from the displayed
            // surface connecting/disconnecting, never from a delayed timer.
            do { try await Task.sleep(for: .seconds(travel.duration)) } catch { return }
            guard !Task.isCancelled else { return }
            moving = false
        }
        .onChange(of: motionEnabled) { _, enabled in
            if enabled { motion.start() } else {
                motion.stop()
                cancelInteraction(animated: false)
                travel.move(to: dock.spread, at: ProcessInfo.processInfo.systemUptime, animated: false)
                moving = false
            }
        }
        .onAppear {
            travel.move(to: dock.spread, at: ProcessInfo.processInfo.systemUptime, animated: false)
            moving = false
            if motionEnabled { motion.start() }
        }
        .onDisappear {
            motion.stop()
            cancelInteraction(animated: false)
            finishTask?.cancel()
            dictation.cancel()
            finishingVoice = false
            voiceMessage = nil
        }
    }

    private func activate() {
        guard !finishingVoice, voiceMessage == nil else { return }
        if moving || dock.spread { dock.spread.toggle() } else { onOpenChat() }
    }

    private func dragChanged(_ value: DragGesture.Value, width: CGFloat) {
        guard !finishingVoice, voiceMessage == nil else { return }
        let time = ProcessInfo.processInfo.systemUptime
        let contact = CGPoint(x: (value.location.x - width / 2) / (Self.ballSize / 2),
                              y: (value.location.y - (Self.areaHeight - Self.ballLift)) / (Self.ballSize / 2))
        if !interaction.pressing {
            interaction.begin(onBall: !moving && !dock.spread)
            if interaction.startedOnBall {
                press.begin(at: contact, time: time)
                pressBeganAt = time
                pressTick += 1
                ChatDiagnostics.log("voice: finger landed on the orb")
                showVoiceGlass()
                holdTask = Task {
                    do { try await Task.sleep(for: .seconds(OrbPress.holdDuration)) } catch { return }
                    guard !Task.isCancelled, interaction.pressing, !interaction.dragging else { return }
                    onBeginVoice?()
                    dock.listening = true
                    setVoice(width: VoiceGeometry.barWidth)
                    // The microphone starts at once; the recognizer catches up behind it.
                    await dictation.start(after: "")
                }
            }
        }
        if dock.listening {
            // Sliding up grows the cancel zone out of the glass, and the zone follows the finger.
            // Down and sideways do nothing: the owner keeps talking, and sliding back retracts the zone.
            let extent = VoiceGesture.extent(forTranslation: value.translation)
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                cancelExtent = extent
                cancelling = VoiceGesture.cancels(extent: extent, wasCancelling: cancelling)
            }
        } else {
            // Resistance is spatial, not temporal: no spring trails the finger.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                press.move(to: contact)
                interaction.drag(value.translation)
            }
            if interaction.dragging {
                // Dragged before it was a hold: this is the ball being played with, not talking.
                holdTask?.cancel()
                hideVoiceGlass(animated: false)
                if press.held { press.release(at: time, animated: motionEnabled) }
            }
        }
    }

    private func showVoiceGlass() {
        voiceShown = true
        voiceWidth = VoiceGeometry.ballWidth
        cancelExtent = 0
        setVoice(width: VoiceGeometry.bulgeWidth)
    }

    private func setVoice(width: CGFloat) {
        withAnimation(motionEnabled ? .spring(response: 0.22, dampingFraction: 0.72) : nil) { voiceWidth = width }
    }

    private func hideVoiceGlass(animated: Bool) {
        guard voiceShown else { return }
        if animated && motionEnabled {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                voiceWidth = VoiceGeometry.ballWidth
                cancelExtent = 0
            } completion: {
                if !interaction.pressing && !dock.listening { voiceShown = false }
            }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                voiceWidth = VoiceGeometry.ballWidth
                cancelExtent = 0
                voiceShown = false
            }
        }
    }

    private func dragEnded(_ value: DragGesture.Value) {
        guard interaction.pressing else { return }
        if !dock.listening || dictation.preparing { holdTask?.cancel() }
        let wasDragging = interaction.dragging
        let wasListening = dock.listening
        let wasBall = interaction.startedOnBall
        // A slow tap looks like a short hold. If nothing was said, it was a tap: open the conversation, don't complain.
        let heldFor = ProcessInfo.processInfo.systemUptime - pressBeganAt
        let slowTap = VoiceGesture.isSlowTap(listening: wasListening, cancelling: cancelling, heldFor: heldFor,
                                             heardSomething: !dictation.text.isEmpty)
        if slowTap {
            dock.listening = false
            dictation.cancel()
        } else if wasListening {
            releaseTick += 1
            finishListening(cancel: cancelling)
        }
        hideVoiceGlass(animated: true)
        press.release(at: ProcessInfo.processInfo.systemUptime, animated: motionEnabled)
        let velocity = OrbInteraction.returnVelocity(translation: value.translation, velocity: value.velocity)
        withAnimation(motionEnabled && wasDragging ? .interpolatingSpring(stiffness: 190, damping: 12, initialVelocity: velocity) : nil) {
            interaction.reset()
        }
        cancelling = false
        if slowTap { onOpenChat() }
        else if !wasDragging && !wasListening {
            if wasBall { onOpenChat() } else { dock.spread.toggle() }
        }
    }

    private func cancelInteraction(animated: Bool) {
        holdTask?.cancel()
        holdTask = nil
        guard interaction.pressing || interaction.dragging || dock.listening || voiceShown else { return }
        hideVoiceGlass(animated: false)
        var transaction = Transaction(animation: animated ? .spring(response: 0.25, dampingFraction: 1) : nil)
        transaction.disablesAnimations = !animated
        withTransaction(transaction) {
            if dock.listening { finishListening(cancel: true) }
            interaction.reset()
            press.release(at: ProcessInfo.processInfo.systemUptime, animated: animated)
        }
        cancelling = false
    }

    private func finishListening(cancel: Bool) {
        dock.listening = false
        if cancel || !dictation.listening {
            if !cancel { voiceMessage = dictation.error ?? "语音还没准备好，请再次按住说话。" }
            dictation.cancel()
            return
        }
        finishingVoice = true
        finishTask = Task {
            let text = await dictation.stop().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !Task.isCancelled else { return }
            finishingVoice = false
            if !text.isEmpty { onSend(text) }
            else { voiceMessage = dictation.error ?? "没有听清，请再次按住说话。" }
        }
    }

    private var listeningOverlay: some View {
        let geometry = VoiceGeometry(barWidth: voiceWidth, extent: cancelExtent)
        return ZStack(alignment: .bottom) {
            Color(.systemBackground).opacity(0.55)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 10) {
                bubble
                if voiceMessage != nil {
                    Button("知道了") { voiceMessage = nil }
                        .buttonStyle(.bordered)
                } else if !finishingVoice {
                    Text(hintText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(cancelling ? Color.red : .primary)
                        .padding(.horizontal, 16).frame(height: 30)
                        .glassEffect(.regular, in: .capsule)
                }
            }
            .padding(.horizontal, 24)
            // Always just above the top of the glass, so it grows upward with the cancel zone.
            .padding(.bottom, Self.ballLift + geometry.topReach + 16)
        }
        .ignoresSafeArea(edges: .bottom)
        .animation(nil, value: cancelExtent)
    }

    @ViewBuilder
    private var bubble: some View {
        let waiting = voiceMessage == nil && !finishingVoice && dictation.error == nil && dictation.text.isEmpty
        if waiting {
            // Heard nothing yet: a small pill, not an empty box.
            Text("…")
                .font(.title3.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 22).frame(height: 38)
                .glassEffect(.regular, in: .capsule)
        } else {
            Text(transcript)
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .foregroundStyle(cancelling ? .secondary : .primary)
                .opacity(cancelling ? 0.6 : 1)
                .padding(.horizontal, 18).padding(.vertical, 14)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private var hintText: String {
        if cancelling { return "松开取消" }
        if cancelExtent > 0.05 { return "继续说话 · 再上滑取消" }
        return "松开发送 · 上滑取消"
    }

    private var transcript: String {
        if let voiceMessage { return voiceMessage }
        if finishingVoice { return "正在整理语音…" }
        if let error = dictation.error { return error }
        return dictation.text
    }
}

// MARK: - Ball ↔ water

/// The glass surface stays mounted through the entire morph. Only its lighting
/// changes from the orb's reflections to the softer light inside the water.
private struct OrbStage: View, Animatable {
    let progress: CGFloat
    let width: CGFloat
    let height: CGFloat
    let safeBottom: CGFloat
    let pressure: CGFloat
    let contact: CGPoint
    let holding: Bool
    let preparingVoice: Bool
    let recording: Bool
    let audioLevel: CGFloat
    let cancelling: Bool
    var pull: CGSize
    let breath: CGFloat
    let active: Bool
    let tilt: CGSize
    let feedbackEnabled: Bool
    let hint: String
    let onChange: (DragGesture.Value) -> Void
    let onEnd: (DragGesture.Value) -> Void
    let onCancel: () -> Void
    let onActivate: () -> Void
    /// The voice glass is drawn in its place; the touch keeps flowing through here.
    var hidden = false
    @GestureState private var touching = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(pull.width, pull.height) }
        set {
            pull = CGSize(width: newValue.first, height: newValue.second)
        }
    }

    var body: some View {
        let size = OrbDockView.ballSize
        let pose = OrbPose.at(progress, safeBottom: safeBottom)
        let reach = hypot(pull.width, pull.height)
        let wobble = (breath - 0.5) * 0.024 * (1 - pose.water)
        let compression = pressure * (1 - pose.water)
        let deformation = BallDeformation(scaleX: pose.scaleX * (1 + wobble + compression * 0.10),
                                          scaleY: pose.scaleY * (1 - wobble - compression * 0.13),
                                          stretch: reach / 44 * 0.34,
                                          angle: Angle(radians: reach > 0 ? atan2(pull.height, pull.width) : 0))
        let contours = pose.peak == -18 ? [] : OrbLiquidGeometry(pose: pose, radius: size * 0.485).contours(width: width, height: height)
        // Drawing, hit testing and feedback all use this displayed frame. Extend
        // the outline by 16pt for a forgiving target, including the thin water edge.
        let surface = LiquidSurface(pose: pose, radius: size * 0.485, contours: contours,
                                    deformation: deformation, pull: pull, pressure: pressure, contact: contact)
            .path(in: CGRect(x: 0, y: 0, width: width, height: height))
        let hitArea = Path { path in
            path.addPath(surface)
            path.addPath(surface.strokedPath(StrokeStyle(lineWidth: 32 * (1 - pose.water) + 8 * pose.water)))
            if progress == 1 {
                // A local 44pt target, not an invisible full-width band over content.
                path.addRoundedRect(in: CGRect(x: width / 2 - 30, y: height - 44, width: 60, height: 44),
                                    cornerSize: CGSize(width: 16, height: 16))
            }
        }
        ZStack {
            Color.clear
            if !hidden { Color.clear.glassEffect(.clear, in: surface) }
            if !hidden {
                WaterLight(peak: pose.peak, tilt: tilt)
                    .opacity(pose.water)
                    .clipShape(surface)
                surface.stroke(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.95), .white.opacity(0.45)],
                                               startPoint: .leading, endPoint: .trailing), lineWidth: 1.2)
                    .opacity(pose.water)
            }
            if pose.water < 1 && !hidden {
                BallLight(size: size, deformation: deformation, active: active, tilt: tilt,
                          pressure: pressure, contact: contact)
                    .offset(x: pull.width * 0.55 * (1 - pose.water), y: pull.height * 0.55 * (1 - pose.water))
                    .position(x: width / 2, y: height - OrbDockView.ballLift + pose.ballY)
                    .opacity(1 - pose.water)
                // An indentation into the screen is read through its reflection.
                // Offset it with the same pull as the surface, and clip all light to it.
                Ellipse()
                    .fill(RadialGradient(colors: [.black.opacity(0.12), .clear, .white.opacity(0.6)],
                                         center: .center, startRadius: 0, endRadius: 14))
                    .frame(width: 25 + pressure * 7, height: 18 + pressure * 5)
                    .rotationEffect(Angle(radians: atan2(contact.y, contact.x)))
                    .position(x: width / 2 + contact.x * size * 0.32 + pull.width * 0.55,
                              y: height - OrbDockView.ballLift + contact.y * size * 0.32 + pull.height * 0.55)
                    .opacity(pressure * (1 - pose.water))
                    .clipShape(surface)
            }
        }
        .frame(width: width, height: height)
        .contentShape(.interaction, hitArea)
        .gesture(DragGesture(minimumDistance: 0)
            .updating($touching) { _, state, _ in state = true }
            .onChanged(onChange)
            .onEnded(onEnd))
        .onChange(of: touching) { _, now in if !now { onCancel() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("管家")
        .accessibilityHint(hint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onActivate() }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.45), trigger: contours.count == 1) { _, _ in
            feedbackEnabled
        }
    }
}

/// How the ball is bent at this moment: squashed against the floor (about its bottom point) and
/// stretched along a finger's pull (about its centre).
struct BallDeformation: Equatable {
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var stretch: CGFloat = 0
    var angle: Angle = .zero

    /// The same bend as a transform, for shapes drawn around `center` with the given radius.
    func transform(center c: CGPoint, radius: CGFloat) -> CGAffineTransform {
        let theta = CGFloat(angle.radians)
        let pulled = CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(rotationAngle: -theta))
            .concatenating(CGAffineTransform(scaleX: 1 + stretch, y: 1 - stretch * 0.38))
            .concatenating(CGAffineTransform(rotationAngle: theta))
            .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
        let bottom = CGPoint(x: c.x, y: c.y + radius)
        let squashed = CGAffineTransform(translationX: -bottom.x, y: -bottom.y)
            .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
            .concatenating(CGAffineTransform(translationX: bottom.x, y: bottom.y))
        return pulled.concatenating(squashed)
    }
}

/// Liquid Glass receives the actual fused outline, including the contact neck.
private struct LiquidSurface: Shape {
    var pose: OrbPose
    let radius: CGFloat
    let contours: [[CGPoint]]
    var deformation: BallDeformation? = nil
    var pull: CGSize = .zero
    var pressure: CGFloat = 0
    var contact: CGPoint = .zero

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.maxY - OrbPose.ballLift + pose.ballY)
        var path = Path()
        if pose.peak == -18 {
            if pressure > 0.001 {
                path.addLines(OrbPress.outline(radius: radius, contact: contact, depth: pressure)
                    .map { CGPoint(x: center.x + $0.x, y: center.y + $0.y) })
                path.closeSubpath()
            } else {
                path = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                              width: radius * 2, height: radius * 2))
            }
            let bend = deformation ?? BallDeformation(scaleX: pose.scaleX, scaleY: pose.scaleY)
            path = path.applying(bend.transform(center: center, radius: radius))
        } else {
            for contour in contours {
                path.addLines(contour.map { CGPoint(x: rect.minX + $0.x, y: rect.minY + $0.y) })
                path.closeSubpath()
            }
            if let deformation {
                let bend = BallDeformation(scaleX: deformation.scaleX / pose.scaleX,
                                           scaleY: deformation.scaleY / pose.scaleY,
                                           stretch: deformation.stretch * (1 - pose.water), angle: deformation.angle)
                path = path.applying(bend.transform(center: center, radius: radius))
            }
        }
        return path.applying(CGAffineTransform(translationX: pull.width * 0.55 * (1 - pose.water),
                                               y: pull.height * 0.55 * (1 - pose.water)))
    }
}

/// Reflections only; the glass itself belongs to the continuous surface above.
private struct BallLight: View {
    let size: CGFloat
    var deformation = BallDeformation()
    let active: Bool
    let tilt: CGSize
    let pressure: CGFloat
    let contact: CGPoint

    var body: some View {
        // Room around the ball for it to stretch into.
        let room = size * 1.9
        let radius = size * 0.485
        let bottomAnchor = UnitPoint(x: 0.5, y: 0.5 + radius / room)
        ZStack {
            ButlerOrb(size: size, active: active, drift: true, tilt: tilt, pressure: pressure, contact: contact)
                .rotationEffect(-deformation.angle)
                .scaleEffect(x: 1 + deformation.stretch, y: 1 - deformation.stretch * 0.38)
                .rotationEffect(deformation.angle)
                .frame(width: room, height: room)
                .scaleEffect(x: deformation.scaleX, y: deformation.scaleY, anchor: bottomAnchor)
                .shadow(color: .black.opacity(0.14), radius: 12, y: 8)
        }
        .frame(width: room, height: room)
    }
}

/// A little of the orb's light remains deep in the gathered water.
private struct WaterLight: View {
    let peak: CGFloat
    let tilt: CGSize
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = colorScheme == .dark ? OrbPalette.night : OrbPalette.day
        let glow = max(14, peak * 0.32)
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                // A little of the orb's light, deep in the middle of the water.
                ZStack {
                    Ellipse().fill(palette.glow[0].0.opacity(0.35)).frame(width: glow * 2.6, height: glow * 1.2)
                        .offset(x: -glow * 0.5)
                    Ellipse().fill(palette.glow[1].0.opacity(0.35)).frame(width: glow * 2.4, height: glow * 1.1)
                        .offset(x: glow * 0.5)
                }
                .blur(radius: 10)
                .overlay(Ellipse().fill(palette.core.opacity(0.8)).frame(width: glow * 1.3, height: glow * 0.65).blur(radius: 5))
                .position(x: size.width / 2 + tilt.width * 6, y: size.height - peak * 0.5)
            }
            .shadow(color: .black.opacity(0.08), radius: 6, y: -2)
        }
    }
}


// MARK: - Voice

/// What the finger's slide means while talking.
enum VoiceGesture {
    /// How far the finger has to travel to reach the middle of a fully grown cancel zone.
    static let travel: CGFloat = VoiceGeometry.reach - 6

    /// 0 for anything but upward. Sliding down or sideways changes nothing, and the zone retracts as the finger comes back.
    static func extent(forTranslation translation: CGSize) -> CGFloat {
        let up = -translation.height - 10
        return max(0, min(1, up / travel))
    }

    /// A hold shorter than this, in which nothing was heard, is a tap that happened to be slow.
    static let tapGrace: TimeInterval = 0.4

    static func isSlowTap(listening: Bool, cancelling: Bool, heldFor: TimeInterval, heardSomething: Bool) -> Bool {
        listening && !cancelling && !heardSomething && heldFor < tapGrace
    }

    /// The finger is in the zone. Once in, a little slack keeps it from flickering at the edge.
    static func cancels(extent: CGFloat, wasCancelling: Bool) -> Bool {
        wasCancelling ? extent > 0.72 : extent > 0.82
    }
}

/// The fused outline as a shape, so the glass follows it while the width and the zone animate.
private struct VoiceShape: Shape {
    var barWidth: CGFloat
    var extent: CGFloat
    let centerY: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(barWidth, extent) }
        set { barWidth = newValue.first; extent = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let geometry = VoiceGeometry(barWidth: barWidth, extent: extent)
        var path = Path()
        for contour in geometry.contours(width: rect.width, height: rect.height, centerY: centerY) {
            path.addLines(contour.map { CGPoint(x: rect.minX + $0.x, y: rect.minY + $0.y) })
            path.closeSubpath()
        }
        return path
    }
}

/// The glass while talking: the ball as a bar with round ends, voice bars on both sides of the finger,
/// and a red cancel zone that grows out of the same glass when the finger slides up.
private struct VoiceGlass: View {
    let width: CGFloat
    let height: CGFloat
    let barWidth: CGFloat
    let extent: CGFloat
    let level: CGFloat
    let recording: Bool
    let cancelling: Bool
    let tilt: CGSize
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let centerY = height - OrbPose.ballLift
        let geometry = VoiceGeometry(barWidth: barWidth, extent: extent)
        let shape = VoiceShape(barWidth: barWidth, extent: extent, centerY: centerY)
        let palette = colorScheme == .dark ? OrbPalette.night : OrbPalette.day
        let dark = colorScheme == .dark
        let grow = extent * extent * (3 - 2 * extent)
        ZStack {
            Color.clear.glassEffect(.clear, in: shape)
            // A little of the orb's own light, deep in the middle of the bar.
            ZStack {
                Ellipse().fill(palette.glow[0].0.opacity(0.36)).frame(width: 74, height: 30).offset(x: -16)
                Ellipse().fill(palette.glow[1].0.opacity(0.36)).frame(width: 70, height: 28).offset(x: 16)
                Ellipse().fill(palette.core.opacity(dark ? 0.55 : 0.85)).frame(width: 34, height: 15)
            }
            .blur(radius: 9)
            .position(x: width / 2 + tilt.width * 5, y: centerY)
            .opacity(Double(min(1, max(0.5, (barWidth - 64) / 40 + 0.5))))
            .clipShape(shape)
            // The cancel zone is the same glass turning red, brightest at its far end.
            LinearGradient(colors: [Color(red: 1, green: 0.23, blue: 0.19).opacity(cancelling ? 0.92 : 0.7),
                                    Color(red: 1, green: 0.27, blue: 0.23).opacity(cancelling ? 0.55 : 0.34), .clear],
                           startPoint: UnitPoint(x: 0.5, y: max(0, (centerY - geometry.topReach) / height)),
                           endPoint: UnitPoint(x: 0.5, y: (centerY - geometry.barHeight / 2 + 6) / height))
                .opacity(grow)
                .clipShape(shape)
                .animation(.easeOut(duration: 0.15), value: cancelling)
            shape.stroke(LinearGradient(colors: [.white.opacity(dark ? 0.3 : 0.9), .white.opacity(dark ? 0.1 : 0.35)],
                                        startPoint: .top, endPoint: .bottom), lineWidth: 1)
            bars(centerY: centerY)
            Text("✕ 取消")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .opacity(max(0, min(1, (extent - 0.45) / 0.35)) * (cancelling ? 1 : 0.75))
                .position(x: width / 2, y: centerY - geometry.zoneOffset)
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(dark ? 0.35 : 0.14), radius: 14, y: 8)
        .accessibilityHidden(true)
    }

    /// Bars stand on both sides of the finger and follow the measured microphone level, never a simulated one.
    private func bars(centerY: CGFloat) -> some View {
        let show = max(0, min(1, (barWidth - 110) / 50))
        let weights: [CGFloat] = [0.55, 0.85, 1, 0.7]
        let ink = colorScheme == .dark ? Color.white : Color.black
        return ZStack {
            ForEach(0..<4, id: \.self) { index in
                ForEach([-1, 1], id: \.self) { side in
                    Capsule()
                        .fill(ink.opacity(cancelling ? 0.35 : 0.78))
                        .frame(width: 5, height: recording ? 6 + level * 32 * weights[index] : 5)
                        .position(x: width / 2 + CGFloat(side) * (barWidth / 2 - 24 - CGFloat(index) * 11), y: centerY)
                        .animation(.easeOut(duration: 0.08), value: level)
                }
            }
        }
        .opacity(show)
    }
}
