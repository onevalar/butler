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

    private var motionEnabled: Bool { !reduceMotion && scenePhase == .active }

    static let ballSize: CGFloat = 64
    /// Ball centre above the bottom edge of the screen.
    static let ballLift: CGFloat = OrbPose.ballLift
    static let areaHeight: CGFloat = 170

    var body: some View {
        ZStack(alignment: .bottom) {
            if dock.listening || finishingVoice || voiceMessage != nil { listeningOverlay.transition(.opacity) }
            GeometryReader { proxy in
                let width = proxy.size.width
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !motionEnabled || (!moving && dock.spread))) { _ in
                    let time = ProcessInfo.processInfo.systemUptime
                    OrbStage(progress: travel.progress(at: time),
                             width: width, height: Self.areaHeight,
                             safeBottom: safeBottom,
                             pressure: press.depth(at: time) * (reduceMotion ? 0.3 : 1),
                             contact: press.contact,
                             audioLevel: reduceMotion || cancelling ? 0 : dictation.audioLevel,
                             cancelling: cancelling,
                             pull: interaction.pull,
                             breath: motionEnabled ? (sin(time * .pi / 2.4) + 1) / 2 : 0.5,
                             active: working || dictation.listening, tilt: motionEnabled ? motion.tilt : .zero,
                             feedbackEnabled: motionEnabled && moving,
                             hint: dock.spread ? "聚回成球" : moving ? "再次轻点可反向" : "点一下和管家对话，按住直接说话",
                             onChange: { dragChanged($0, width: width) }, onEnd: dragEnded,
                             onCancel: { cancelInteraction(animated: motionEnabled) },
                             onActivate: activate)
                }
            }
            .frame(height: Self.areaHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(edges: .bottom)
        .ignoresSafeArea(.keyboard)
        .animation(.easeOut(duration: 0.15), value: dock.listening)
        .sensoryFeedback(.impact(weight: .light), trigger: dock.listening) { _, new in new }
        .sensoryFeedback(.selection, trigger: cancelling)
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
                holdTask = Task {
                    do { try await Task.sleep(for: .seconds(OrbPress.holdDuration)) } catch { return }
                    guard !Task.isCancelled, interaction.pressing, !interaction.dragging else { return }
                    onBeginVoice?()
                    dock.listening = true
                    await dictation.start(after: "")
                }
            }
        }
        if dock.listening {
            cancelling = value.translation.height < -60
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                press.move(to: contact)
                interaction.drag(value.translation)
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
                holdTask?.cancel()
                if press.held { press.release(at: time, animated: motionEnabled) }
            }
        }
    }

    private func dragEnded(_ value: DragGesture.Value) {
        guard interaction.pressing else { return }
        if !dock.listening || dictation.preparing { holdTask?.cancel() }
        let wasDragging = interaction.dragging
        let wasListening = dock.listening
        let wasBall = interaction.startedOnBall
        if wasListening { finishListening(cancel: value.translation.height < -60) }
        press.release(at: ProcessInfo.processInfo.systemUptime, animated: motionEnabled)
        let velocity = OrbInteraction.returnVelocity(translation: value.translation, velocity: value.velocity)
        withAnimation(motionEnabled && wasDragging ? .interpolatingSpring(stiffness: 190, damping: 12, initialVelocity: velocity) : nil) {
            interaction.reset()
        }
        cancelling = false
        if !wasDragging && !wasListening {
            if wasBall { onOpenChat() } else { dock.spread.toggle() }
        }
    }

    private func cancelInteraction(animated: Bool) {
        holdTask?.cancel()
        holdTask = nil
        guard interaction.pressing || interaction.dragging || dock.listening else { return }
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
        ZStack(alignment: .bottom) {
            Color(.systemBackground).opacity(0.25)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 10) {
                Text(transcript)
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(dictation.text.isEmpty ? .secondary : .primary)
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                if voiceMessage != nil {
                    Button("知道了") { voiceMessage = nil }
                        .buttonStyle(.bordered)
                } else if !finishingVoice {
                    Text(cancelling ? "松开取消" : "松开就发给管家 · 上滑取消")
                        .font(.footnote)
                        .foregroundStyle(cancelling ? Color.red : .secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, Self.areaHeight - 10)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var transcript: String {
        if let voiceMessage { return voiceMessage }
        if finishingVoice { return "正在整理语音…" }
        if let error = dictation.error { return error }
        if !dictation.listening { return "正在准备语音…" }
        return dictation.text.isEmpty ? "正在听…" : dictation.text
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
        let deformation = BallDeformation(scaleX: pose.scaleX * (1 + wobble), scaleY: pose.scaleY * (1 - wobble),
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
            Color.clear.glassEffect(.clear, in: surface)
            WaterLight(peak: pose.peak, tilt: tilt)
                .opacity(pose.water)
                .clipShape(surface)
            surface.stroke(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.95), .white.opacity(0.45)],
                                           startPoint: .leading, endPoint: .trailing), lineWidth: 1.2)
                .opacity(pose.water)
            if pose.water < 1 {
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
                Circle()
                    .fill(RadialGradient(colors: [cancelling ? Color.orange : Color.cyan, .clear],
                                         center: .center, startRadius: 0, endRadius: 26))
                    .frame(width: 52, height: 52)
                    .position(x: width / 2 + pull.width * 0.55,
                              y: height - OrbDockView.ballLift + pull.height * 0.55)
                    .opacity((cancelling ? 0.25 : audioLevel * 0.3) * (1 - pose.water))
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
            if active {
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 1, green: 0.6, blue: 0.8).opacity(0.35),
                                                  Color(red: 0.5, green: 0.75, blue: 1).opacity(0.22), .clear],
                                         center: .center, startRadius: 0, endRadius: size))
                    .frame(width: size * 2, height: size * 2)
            }
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
