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
                    OrbMorph(amount: dock.spread ? 1 : 0, width: width, height: Self.areaHeight,
                             ballScale: dock.listening ? 1.3 : (pressing ? 0.92 : 1),
                             active: working || dock.listening, tilt: reduceMotion ? .zero : motion.tilt)
                        .allowsHitTesting(false)
                    // Touch targets: the ball while floating, the raised water while spread.
                    if dock.spread {
                        PuddleShape(inset: 0, edge: OrbMorph.puddleEdge, bump: OrbMorph.puddleBump)
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
        .animation(.spring(response: 0.55, dampingFraction: 0.68), value: dock.spread)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: dock.listening)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressing)
        .sensoryFeedback(.impact(weight: .medium), trigger: dock.listening) { _, new in new }
        .onChange(of: touching) { _, now in
            // The touch was taken away without ending normally: drop whatever was being said.
            guard !now, pressing else { return }
            holdTask?.cancel()
            pressing = false
            cancelling = false
            if dock.listening { finishListening(cancel: true) }
        }
        .onAppear { if !reduceMotion { motion.start() } }
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
                        guard !Task.isCancelled, pressing else { return }
                        dock.listening = true
                        await dictation.start(after: "")
                    }
                }
                cancelling = dock.listening && value.translation.height < -60
            }
            .onEnded { value in
                holdTask?.cancel()
                pressing = false
                if dock.listening {
                    finishListening(cancel: value.translation.height < -60)
                } else if abs(value.translation.width) < 12, abs(value.translation.height) < 12 {
                    onOpenChat()
                }
                cancelling = false
            }
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

/// One value drives the whole move: 0 is the floating ball, 1 is water spread along the bottom edge.
/// The spring that animates it overshoots a little, which gives the drop its bounce.
private struct OrbMorph: View, Animatable {
    var amount: CGFloat
    let width: CGFloat
    let height: CGFloat
    var ballScale: CGFloat
    let active: Bool
    let tilt: CGSize

    static let puddleEdge: CGFloat = 40
    static let puddleBump: CGFloat = 18

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(amount, ballScale) }
        set { amount = newValue.first; ballScale = newValue.second }
    }

    var body: some View {
        let a = max(0, min(1, amount))
        let size = OrbDockView.ballSize * ballScale
        // The ball falls, stretches as it goes, then flattens on the edge and fades into the water.
        let fall = OrbDockView.ballLift - 26
        let ballOpacity = 1 - smoothstep(0.45, 0.7, a)
        let stretch = sin(a * .pi) // longest halfway down
        let squash = smoothstep(0.5, 1, a)
        let scaleX = 1 - 0.18 * stretch * (1 - squash) + 1.4 * squash
        let scaleY = 1 + 0.25 * stretch * (1 - squash) - 0.6 * squash
        // The water grows out from the middle, then settles to its low arc.
        let waterOpacity = smoothstep(0.35, 0.6, a)
        let inset = (1 - smoothstep(0.35, 1, amount)) * (width / 2 - 40)
        let bump = Self.puddleBump + (1 - smoothstep(0.5, 1, amount)) * 26
        let edge = Self.puddleEdge * smoothstep(0.55, 1, amount)

        ZStack {
            if waterOpacity > 0 {
                Water(inset: inset, edge: edge, bump: bump, tilt: tilt)
                    .opacity(waterOpacity)
            }
            if ballOpacity > 0 {
                GlassBall(size: size, active: active, tilt: tilt)
                    .scaleEffect(x: scaleX, y: scaleY, anchor: .bottom)
                    .position(x: width / 2, y: height - OrbDockView.ballLift + fall * a)
                    .opacity(ballOpacity)
            }
        }
        .frame(width: width, height: height)
    }

    private func smoothstep(_ from: CGFloat, _ to: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = max(0, min(1, (x - from) / (to - from)))
        return t * t * (3 - 2 * t)
    }
}

/// The ball: real Liquid Glass underneath bends whatever scrolls behind it; the drawn orb adds the light.
private struct GlassBall: View {
    let size: CGFloat
    let active: Bool
    let tilt: CGSize

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: size * 0.97, height: size * 0.97)
                .glassEffect(.clear, in: Circle())
            ButlerOrb(size: size, active: active, tilt: tilt)
        }
        .background {
            if active {
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 1, green: 0.6, blue: 0.8).opacity(0.35),
                                                  Color(red: 0.5, green: 0.75, blue: 1).opacity(0.22), .clear],
                                         center: .center, startRadius: 0, endRadius: size))
                    .frame(width: size * 2, height: size * 2)
            }
        }
        .shadow(color: .black.opacity(0.14), radius: 12, y: 8)
    }
}

/// Glass spread along the whole bottom edge: as thick as the home-indicator zone, raised in the middle.
private struct Water: View {
    let inset: CGFloat
    let edge: CGFloat
    let bump: CGFloat
    let tilt: CGSize
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = PuddleShape(inset: inset, edge: edge, bump: bump)
        let palette = colorScheme == .dark ? OrbPalette.night : OrbPalette.day
        GeometryReader { proxy in
            let size = proxy.size
            let peakY = size.height - edge - bump
            ZStack {
                Color.clear.glassEffect(.clear, in: shape)
                // A little of the orb's light, low in the middle of the raised part.
                ZStack {
                    Ellipse().fill(palette.glow[0].0.opacity(0.35)).frame(width: bump * 2.4, height: bump * 1.1)
                        .offset(x: -bump * 0.5)
                    Ellipse().fill(palette.glow[1].0.opacity(0.35)).frame(width: bump * 2.2, height: bump)
                        .offset(x: bump * 0.5)
                }
                .blur(radius: 9)
                .overlay(Ellipse().fill(palette.core.opacity(0.8)).frame(width: bump * 1.2, height: bump * 0.6).blur(radius: 4))
                .position(x: size.width / 2 + tilt.width * 6, y: peakY + bump * 0.75)
                .clipShape(shape)
                shape.rimPath(in: CGRect(origin: .zero, size: size))
                    .stroke(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.95), .white.opacity(0.5)],
                                           startPoint: .leading, endPoint: .trailing), lineWidth: 1.2)
            }
            .shadow(color: .black.opacity(0.08), radius: 6, y: -2)
        }
    }
}

/// Flat along the bottom, `edge` thick at the sides, rising by `bump` in the middle.
/// `inset` pulls both ends towards the centre while the water gathers.
struct PuddleShape: Shape {
    var inset: CGFloat
    var edge: CGFloat
    var bump: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(inset, AnimatablePair(edge, bump)) }
        set { inset = newValue.first; edge = newValue.second.first; bump = newValue.second.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
        addRim(to: &path, in: rect, moving: false)
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    func rimPath(in rect: CGRect) -> Path {
        var path = Path()
        addRim(to: &path, in: rect, moving: true)
        return path
    }

    private func addRim(to path: inout Path, in rect: CGRect, moving: Bool) {
        let a = rect.minX + inset, b = rect.maxX - inset
        let top = rect.maxY - edge, peak = rect.maxY - edge - bump
        let mid = rect.midX, span = (b - a) / 2
        if moving { path.move(to: CGPoint(x: a, y: top)) } else { path.addLine(to: CGPoint(x: a, y: top)) }
        path.addCurve(to: CGPoint(x: mid, y: peak), control1: CGPoint(x: a + span * 0.45, y: top), control2: CGPoint(x: mid - span * 0.45, y: peak))
        path.addCurve(to: CGPoint(x: b, y: top), control1: CGPoint(x: mid + span * 0.45, y: peak), control2: CGPoint(x: b - span * 0.45, y: top))
    }
}
