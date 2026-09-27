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
    let onOpenChat: () -> Void
    let onSend: (String) -> Void

    @Environment(OrbDock.self) private var dock
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = MotionTilt()
    @State private var dictation = LiveDictation()
    @State private var holdTask: Task<Void, Never>?
    @State private var pressing = false
    @State private var cancelling = false
    /// Resets by itself when the system takes the touch away (an alert, a call), unlike `onEnded`.
    @GestureState private var touching = false
    /// When the last fall or gather started; the pose is computed from the time since.
    @State private var moveStart = Date.distantPast
    @State private var moving = false
    @State private var landed = 0
    /// How far a finger is pulling the ball (rubber-banded); it springs back with a wobble on release.
    @State private var pull: CGSize = .zero
    @State private var dragging = false
    /// 0…1, slowly back and forth: the ball is never quite still.
    @State private var breath: CGFloat = 0

    static let ballSize: CGFloat = 64
    /// Ball centre above the bottom edge of the screen.
    static let ballLift: CGFloat = 74
    static let areaHeight: CGFloat = 170

    var body: some View {
        ZStack(alignment: .bottom) {
            if dock.listening { listeningOverlay.transition(.opacity) }
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack {
                    TimelineView(.animation(paused: !moving)) { context in
                        let elapsed = context.date.timeIntervalSince(moveStart)
                        OrbStage(pose: reduceMotion ? OrbPose.rest(spread: dock.spread) : OrbPose.at(elapsed, spreading: dock.spread),
                                 width: width, height: Self.areaHeight,
                                 ballScale: dock.listening ? 1.3 : (pressing && !dragging ? 0.92 : 1),
                                 pull: pull, breath: breath,
                                 active: working || dock.listening, tilt: reduceMotion ? .zero : motion.tilt)
                    }
                    .allowsHitTesting(false)
                    // Touch targets: the ball while floating, the raised water while spread.
                    if dock.spread {
                        PuddleShape(inset: 0, side: OrbPose.restSide, peak: OrbPose.restPeak)
                            .fill(Color.white.opacity(0.001))
                            .onTapGesture { gather() }
                            .accessibilityElement()
                            .accessibilityLabel("管家")
                            .accessibilityHint("聚回成球")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { gather() }
                    } else {
                        Circle().fill(Color.white.opacity(0.001))
                            .frame(width: Self.ballSize + 12, height: Self.ballSize + 12)
                            .position(x: width / 2, y: Self.areaHeight - Self.ballLift)
                            .gesture(pressGesture)
                            .accessibilityElement()
                            .accessibilityLabel("管家")
                            .accessibilityHint("点一下和管家对话，按住直接说话")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { onOpenChat() }
                    }
                }
            }
            .frame(height: Self.areaHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(edges: .bottom)
        .ignoresSafeArea(.keyboard)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: dock.listening)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressing)
        .sensoryFeedback(.impact(weight: .medium), trigger: dock.listening) { _, new in new }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.45), trigger: landed)
        .onChange(of: dock.spread) { _, spread in
            let start = Date.now
            moveStart = start
            moving = true
            Task {
                // A soft tap when the drop lands, or when the ball pops back up.
                try? await Task.sleep(for: .milliseconds(spread ? 320 : 300))
                if moveStart == start { landed += 1 }
                try? await Task.sleep(for: .milliseconds(1400))
                if moveStart == start { moving = false }
            }
        }
        .onChange(of: touching) { _, now in
            // The touch was taken away without ending normally: drop whatever was being said.
            guard !now, pressing else { return }
            holdTask?.cancel()
            pressing = false
            cancelling = false
            if dock.listening { finishListening(cancel: true) }
        }
        .onAppear {
            guard !reduceMotion else { return }
            motion.start()
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breath = 1 }
        }
        .onDisappear { motion.stop() }
    }

    private func gather() {
        dock.spread = false
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                if !pressing {
                    pressing = true
                    holdTask = Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled, pressing, !dragging else { return }
                        dock.listening = true
                        await dictation.start(after: "")
                    }
                }
                let moved = hypot(value.translation.width, value.translation.height)
                if dock.listening {
                    cancelling = value.translation.height < -60
                } else if dragging || moved > 10 {
                    // Playing with it: the ball stretches after the finger like a drop of water.
                    if !dragging { dragging = true; holdTask?.cancel() }
                    withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.8)) {
                        pull = Self.rubberBand(value.translation)
                    }
                }
            }
            .onEnded { value in
                holdTask?.cancel()
                pressing = false
                if dock.listening {
                    finishListening(cancel: value.translation.height < -60)
                } else if dragging {
                    // Let go: it snaps back, overshoots and wobbles still.
                    withAnimation(.interpolatingSpring(stiffness: 190, damping: 7)) { pull = .zero }
                } else {
                    onOpenChat()
                }
                dragging = false
                cancelling = false
            }
    }

    /// The further the finger goes, the harder it pulls back; the ball never leaves about 44 points of home.
    static func rubberBand(_ translation: CGSize) -> CGSize {
        let distance = hypot(translation.width, translation.height)
        guard distance > 0 else { return .zero }
        let eased = 44 * (1 - exp(-distance / 130))
        return CGSize(width: translation.width / distance * eased, height: translation.height / distance * eased)
    }

    private func finishListening(cancel: Bool) {
        dock.listening = false
        if cancel {
            dictation.cancel()
            return
        }
        Task {
            let text = await dictation.stop().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { onSend(text) }
        }
    }

    private var listeningOverlay: some View {
        ZStack(alignment: .bottom) {
            Color(.systemBackground).opacity(0.55)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 10) {
                Text(transcript)
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(dictation.text.isEmpty ? .secondary : .primary)
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                Text(cancelling ? "松开取消" : "松开就发给管家 · 上滑取消")
                    .font(.footnote)
                    .foregroundStyle(cancelling ? Color.red : .secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, Self.areaHeight - 10)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var transcript: String {
        if let error = dictation.error { return error }
        if dictation.preparing { return "正在准备语音…" }
        return dictation.text.isEmpty ? "正在听…" : dictation.text
    }
}

// MARK: - Ball ↔ water

/// Where everything is at one moment of the fall or the gather. Times are in seconds.
struct OrbPose {
    /// How far below its resting place the ball is.
    var ballY: CGFloat = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var ballOpacity: CGFloat = 1
    var waterOpacity: CGFloat = 0
    /// 0: the water covers the whole bottom edge. 1: it is drawn together to the width of the ball.
    var gathered: CGFloat = 1
    /// Water thickness at the screen corners, and at the middle.
    var side: CGFloat = 0
    var peak: CGFloat = 0

    static let restSide: CGFloat = 28
    static let restPeak: CGFloat = 60
    /// From resting height to sitting on the bottom edge.
    static let fall: CGFloat = 50

    static func rest(spread: Bool) -> OrbPose {
        spread ? OrbPose(ballOpacity: 0, waterOpacity: 1, gathered: 0, side: restSide, peak: restPeak) : OrbPose()
    }

    static func at(_ t: Double, spreading: Bool) -> OrbPose {
        if t > 2 { return rest(spread: spreading) }
        return spreading ? falling(t) : gathering(t)
    }

    /// Winds up, falls faster and faster while stretching, lands flat, and the water runs out and wobbles still.
    private static func falling(_ t: Double) -> OrbPose {
        var p = OrbPose()
        if t < 0.1 {
            let k = sin(.pi * t / 0.1)
            p.ballY = -5 * k
            p.scaleX = 1 + 0.06 * k
            p.scaleY = 1 - 0.06 * k
        } else if t < 0.32 {
            let k = (t - 0.1) / 0.22
            p.ballY = fall * k * k
            p.scaleX = 1 - 0.14 * k
            p.scaleY = 1 + 0.26 * k
        } else {
            let k = clamp((t - 0.32) / 0.1)
            p.ballY = fall + 6 * k
            p.scaleX = 0.86 + 0.9 * k
            p.scaleY = 1.26 - 0.86 * k
            p.ballOpacity = 1 - k
        }
        let w = t - 0.3
        p.waterOpacity = clamp(w / 0.08)
        p.gathered = max(0, 1 - spring(w, period: 0.55, damping: 0.55))
        p.side = restSide * clamp(spring(w, period: 0.5, damping: 0.75))
        // The middle starts as tall as the drop and settles with a couple of wobbles.
        p.peak = restPeak + (78 - restPeak) * (1 - spring(w, period: 0.42, damping: 0.32))
        return p
    }

    /// The water draws into the middle and rises; the ball pops out squashed, overshoots and wobbles round.
    private static func gathering(_ t: Double) -> OrbPose {
        var p = OrbPose()
        let g = smooth(clamp(t / 0.3))
        p.gathered = g
        p.side = restSide * (1 - g)
        p.peak = restPeak + 16 * g
        p.waterOpacity = 1 - clamp((t - 0.24) / 0.08)
        let b = t - 0.24
        if b < 0 {
            p.ballOpacity = 0
            p.ballY = fall
        } else {
            p.ballOpacity = clamp(b / 0.06)
            p.ballY = fall * (1 - spring(b, period: 0.62, damping: 0.42))
            let wobble = spring(b, period: 0.34, damping: 0.3)
            p.scaleX = 1.45 + (1 - 1.45) * wobble
            p.scaleY = 0.55 + (1 - 0.55) * wobble
        }
        return p
    }

    /// Step response of a damped spring: 0 at t = 0, settling at 1, overshooting when underdamped.
    static func spring(_ t: Double, period: Double, damping: Double) -> CGFloat {
        guard t > 0 else { return 0 }
        let omega = 2 * .pi / period
        let damped = omega * sqrt(1 - damping * damping)
        return 1 - exp(-damping * omega * t) * (cos(damped * t) + damping * omega / damped * sin(damped * t))
    }

    private static func clamp(_ x: Double) -> CGFloat { max(0, min(1, x)) }
    private static func smooth(_ x: CGFloat) -> CGFloat { x * x * (3 - 2 * x) }
}

/// Draws a pose. `ballScale` (pressing, listening) animates on its own spring.
private struct OrbStage: View, Animatable {
    let pose: OrbPose
    let width: CGFloat
    let height: CGFloat
    var ballScale: CGFloat
    var pull: CGSize
    var breath: CGFloat
    let active: Bool
    let tilt: CGSize

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(ballScale, breath), AnimatablePair(pull.width, pull.height)) }
        set {
            ballScale = newValue.first.first
            breath = newValue.first.second
            pull = CGSize(width: newValue.second.first, height: newValue.second.second)
        }
    }

    var body: some View {
        let size = OrbDockView.ballSize * ballScale
        ZStack {
            if pose.waterOpacity > 0 {
                Water(inset: pose.gathered * (width / 2 - 48), side: pose.side, peak: pose.peak, tilt: tilt)
                    .opacity(pose.waterOpacity)
            }
            if pose.ballOpacity > 0 {
                // Pulled: stretched along the pull and leaning after it. Resting: a slow, slight breath.
                let reach = hypot(pull.width, pull.height)
                let stretch = reach / 44 * 0.34
                let angle = Angle(radians: reach > 0 ? atan2(pull.height, pull.width) : 0)
                let wobble = (breath - 0.5) * 0.024
                let shape = BallDeformation(scaleX: pose.scaleX * (1 + wobble), scaleY: pose.scaleY * (1 - wobble),
                                            stretch: stretch, angle: angle)
                GlassBall(size: size, deformation: shape, active: active, tilt: tilt)
                    .offset(x: pull.width * 0.55, y: pull.height * 0.55)
                    .position(x: width / 2, y: height - OrbDockView.ballLift + pose.ballY)
                    .opacity(pose.ballOpacity)
            }
        }
        .frame(width: width, height: height)
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

/// The glass outline of the ball, already bent. Liquid Glass follows a shape it is given,
/// but not transforms applied to it afterwards, so the bend lives in the shape.
private struct BentCircle: Shape {
    let radius: CGFloat
    let deformation: BallDeformation

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        return circle.applying(deformation.transform(center: center, radius: radius))
    }
}

/// The ball: real Liquid Glass underneath bends whatever scrolls behind it; the drawn orb adds the light.
/// Both are bent the same way, so they always stay one ball.
private struct GlassBall: View {
    let size: CGFloat
    var deformation = BallDeformation()
    let active: Bool
    let tilt: CGSize

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
            Color.clear
                .frame(width: room, height: room)
                .glassEffect(.clear, in: BentCircle(radius: radius, deformation: deformation))
            ButlerOrb(size: size, active: active, drift: true, tilt: tilt)
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

/// Glass spread along the whole bottom edge: one rounded arc from corner to corner, thickest in the middle.
private struct Water: View {
    let inset: CGFloat
    let side: CGFloat
    let peak: CGFloat
    let tilt: CGSize
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = PuddleShape(inset: inset, side: side, peak: peak)
        let palette = colorScheme == .dark ? OrbPalette.night : OrbPalette.day
        let glow = max(14, peak * 0.32)
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Color.clear.glassEffect(.clear, in: shape)
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
                .clipShape(shape)
                shape.rimPath(in: CGRect(origin: .zero, size: size))
                    .stroke(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.95), .white.opacity(0.45)],
                                           startPoint: .leading, endPoint: .trailing), lineWidth: 1.2)
            }
            .shadow(color: .black.opacity(0.08), radius: 6, y: -2)
        }
    }
}

/// Flat along the bottom; the top is a single smooth arc, `side` high at the ends and `peak` high in the middle.
/// `inset` draws both ends in towards the centre.
struct PuddleShape: Shape {
    var inset: CGFloat
    var side: CGFloat
    var peak: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
        addArc(to: &path, in: rect, moving: false)
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    func rimPath(in rect: CGRect) -> Path {
        var path = Path()
        addArc(to: &path, in: rect, moving: true)
        return path
    }

    private func addArc(to path: inout Path, in rect: CGRect, moving: Bool) {
        let start = CGPoint(x: rect.minX + inset, y: rect.maxY - side)
        let end = CGPoint(x: rect.maxX - inset, y: rect.maxY - side)
        // A quadratic curve reaches half-way to its control point, so the control sits twice as high.
        let mid = CGPoint(x: rect.midX, y: rect.maxY - peak)
        let span = (end.x - start.x) / 2
        if moving { path.move(to: start) } else { path.addLine(to: start) }
        // Leaves each corner nearly level for a short way, then one broad round crown.
        path.addCurve(to: mid, control1: CGPoint(x: start.x + span * 0.2, y: start.y),
                      control2: CGPoint(x: mid.x - span * 0.46, y: mid.y))
        path.addCurve(to: end, control1: CGPoint(x: mid.x + span * 0.46, y: mid.y),
                      control2: CGPoint(x: end.x - span * 0.2, y: end.y))
    }
}
