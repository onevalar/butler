import CoreMotion
import SwiftUI

/// A stable entry point across screens. Scrolling never changes its shape or location.
@Observable
final class OrbDock {
    var listening = false
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

/// One stable control: short press opens typing; a committed hold records speech.
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
    @State private var recorder: LiveVoicePressRecorder
    @State private var feedback: ContinuousPressFeedback
    @State private var interaction: VoicePressInteraction
    @State private var handsFree = false
    @State private var press = OrbPress()
    @State private var voiceShown = false
    @State private var voiceWidth: CGFloat = VoiceGeometry.ballWidth
    @State private var cancelExtent: CGFloat = 0
    @State private var visualSession = UUID()

    private var motionEnabled: Bool { !reduceMotion && scenePhase == .active }

    static let ballSize: CGFloat = 64
    static let ballLift: CGFloat = OrbPose.ballLift

    init(working: Bool, safeBottom: CGFloat = 34, onOpenChat: @escaping () -> Void,
         onSend: @escaping (String) -> Void, onBeginVoice: (() -> Void)? = nil) {
        self.working = working
        self.safeBottom = safeBottom
        self.onOpenChat = onOpenChat
        self.onSend = onSend
        self.onBeginVoice = onBeginVoice
        let recorder = LiveVoicePressRecorder()
        let feedback = ContinuousPressFeedback()
        _recorder = State(initialValue: recorder)
        _feedback = State(initialValue: feedback)
        _interaction = State(initialValue: VoicePressInteraction(recorder: recorder, feedback: feedback))
    }

    private var presentingVoice: Bool {
        interaction.voiceCommitted && interaction.held || interaction.phase == .finishing || interaction.issue != nil
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if presentingVoice {
                Color(.systemBackground).opacity(0.55)
                    .ignoresSafeArea().allowsHitTesting(false)
                if interaction.phase == .finishing && interaction.issue == nil && recorder.dictation.usesCustomService {
                    // One capsule: what's happening and how to stop it, well clear of the orb so a thumb
                    // resting near the orb can't hit 取消 by accident, and 取消 is a full 44-point target.
                    HStack(spacing: 0) {
                        ProgressView().padding(.leading, 18).padding(.trailing, 10)
                        Text("正在整理语音…").font(.subheadline.weight(.medium))
                        Divider().frame(height: 22).padding(.horizontal, 14)
                        Button { reset() } label: {
                            Text("取消").font(.subheadline.weight(.semibold))
                                .padding(.trailing, 20).padding(.leading, 4)
                                .frame(minHeight: 52)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("取消识别")
                    }
                    .frame(height: 52)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, Self.ballLift + VoiceGeometry(barWidth: voiceWidth, extent: cancelExtent).topReach + 56)
                } else {
                    VStack(spacing: 16) {
                        if !interaction.cancelling || !recorder.dictation.text.isEmpty || interaction.issue != nil {
                            Text(status)
                                .font(recorder.dictation.text.isEmpty ? .subheadline.weight(.medium) : .title3.weight(.medium))
                                .multilineTextAlignment(.center)
                                .lineLimit(5)
                                .foregroundStyle(interaction.cancelling ? Color.secondary : Color.primary)
                                .padding(.horizontal, 18).padding(.vertical, 12)
                                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
                        }
                        if interaction.issue != nil {
                            Button("知道了") { interaction.dismissIssue() }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, Self.ballLift + VoiceGeometry(barWidth: voiceWidth, extent: cancelExtent).topReach
                             + (interaction.issue != nil ? 44 : 16))
                }
            }

            GeometryReader { proxy in
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !motionEnabled)) { _ in
                    let time = ProcessInfo.processInfo.systemUptime
                    OrbStage(progress: 0, width: proxy.size.width, height: 170, safeBottom: safeBottom,
                             pressure: press.depth(at: time) * (reduceMotion ? 0.3 : 1), contact: press.contact,
                             pull: .zero, breath: motionEnabled ? (sin(time * .pi / 2.4) + 1) / 2 : 0.5,
                             active: working || recorder.dictation.listening,
                             tilt: motionEnabled ? motion.tilt : .zero, hidden: voiceShown)
                }
            }
            .frame(height: 170)
            .allowsHitTesting(false)
            if voiceShown {
                GeometryReader { proxy in
                    VoiceGlass(width: proxy.size.width, height: 340, barWidth: voiceWidth, extent: cancelExtent,
                               level: recorder.dictation.audioLevel, recording: interaction.phase == .recording,
                               cancelling: interaction.cancelling, tilt: motionEnabled ? motion.tilt : .zero)
                }
                .frame(height: 340)
                .allowsHitTesting(false)
                .transition(.identity)
            }

            // The control remains mounted and stationary through every glass animation.
            // The visual layer cannot delay feedback or cancel a tracked finger.
            VoicePressControl(label: "管家", hint: "短按打开文字输入，长按说话，松开发送，上滑取消",
                onDown: {
                    if handsFree { interaction.cancel(); handsFree = false }
                    beginPress()
                    return interaction.held
                },
                onMove: { movePress($0) },
                onUp: { interaction.release() },
                onCancel: { reset() },
                onActivate: {
                    reset()
                    onOpenChat()
                },
                onVoiceActivate: {
                    if handsFree { interaction.release(); handsFree = false }
                    else { beginPress(); handsFree = interaction.held }
                })
                .frame(width: 96, height: 96)
                .padding(.bottom, Self.ballLift - 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(edges: .bottom)
        .ignoresSafeArea(.keyboard)
        .onAppear {
            feedback.prepare()
            if !reduceMotion { motion.start() }
        }
        .onDisappear {
            reset()
            feedback.suspend()
            motion.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                feedback.prepare()
                if !reduceMotion { motion.start() }
            } else {
                reset()
                feedback.suspend()
                motion.stop()
            }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { motion.stop() } else if scenePhase == .active { motion.start() }
        }
        .onChange(of: interaction.held) { _, held in
            if held { showVoiceGlass() } else { hideVoiceGlass(animated: motionEnabled) }
        }
        .onChange(of: interaction.voiceCommitted) { _, committed in
            if committed && interaction.held {
                withAnimation(motionEnabled ? .spring(response: 0.22, dampingFraction: 0.72) : nil) {
                    voiceWidth = VoiceGeometry.barWidth
                }
            }
        }
        .onChange(of: interaction.voiceCommitted && interaction.held) { _, listening in
            dock.listening = listening
        }
        .onChange(of: recorder.dictation.error) { _, error in
            if let error, interaction.held { interaction.cancel(message: error) }
        }
    }

    private func beginPress() {
        interaction.begin(onTap: onOpenChat, onVoice: onBeginVoice, onTranscript: onSend)
    }

    private func reset() {
        interaction.cancel()
        handsFree = false
        dock.listening = false
        hideVoiceGlass(animated: false)
    }

    private var status: String {
        if let issue = interaction.issue { return issue }
        if interaction.cancelling { return recorder.dictation.text }
        if interaction.phase == .finishing { return "正在整理语音…" }
        if interaction.phase == .recording {
            return recorder.dictation.text.isEmpty ? "松开发送，上滑取消" : recorder.dictation.text
        }
        return "正在开启麦克风…"
    }

    private func movePress(_ translation: CGSize) {
        interaction.move(translation: translation)
        guard interaction.held else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            cancelExtent = VoiceGesture.extent(forTranslation: translation)
        }
    }

    private func showVoiceGlass() {
        visualSession = UUID()
        press.begin(at: CGPoint(x: 0, y: -1), time: ProcessInfo.processInfo.systemUptime)
        voiceShown = true
        // Continue from the current width if a new press interrupts the return animation.
        cancelExtent = 0
        withAnimation(motionEnabled ? .spring(response: 0.22, dampingFraction: 0.72) : nil) {
            voiceWidth = interaction.voiceCommitted ? VoiceGeometry.barWidth : VoiceGeometry.bulgeWidth
        }
    }

    private func hideVoiceGlass(animated: Bool) {
        let ending = UUID()
        visualSession = ending
        press.release(at: ProcessInfo.processInfo.systemUptime, animated: animated)
        guard voiceShown else { return }
        if animated {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                voiceWidth = VoiceGeometry.ballWidth
                cancelExtent = 0
            } completion: {
                guard visualSession == ending, !interaction.held else { return }
                voiceShown = false
            }
        } else {
            voiceWidth = VoiceGeometry.ballWidth
            cancelExtent = 0
            voiceShown = false
        }
    }
}

// Geometry of the restored flowing cancellation surface.
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
    var pull: CGSize
    let breath: CGFloat
    let active: Bool
    let tilt: CGSize
    /// The voice glass is drawn in its place; the independent control keeps tracking.
    var hidden = false

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
        // Original liquid surface and reflections; this layer never receives touches.
        let surface = LiquidSurface(pose: pose, radius: size * 0.485, contours: contours,
                                    deformation: deformation, pull: pull, pressure: pressure, contact: contact)
            .path(in: CGRect(x: 0, y: 0, width: width, height: height))
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
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
            LinearGradient(stops: [.init(color: Color(red: 1, green: 0.23, blue: 0.19).opacity(cancelling ? 0.95 : 0.78), location: 0),
                                   .init(color: Color(red: 1, green: 0.27, blue: 0.23).opacity(cancelling ? 0.7 : 0.5), location: 0.55),
                                   .init(color: Color(red: 1, green: 0.32, blue: 0.27).opacity(0), location: 1)],
                           startPoint: UnitPoint(x: 0.5, y: max(0, (centerY - geometry.topReach) / height)),
                           endPoint: UnitPoint(x: 0.5, y: (centerY - 4) / height))
                .opacity(grow)
                .clipShape(shape)
                .animation(.easeOut(duration: 0.15), value: cancelling)
            shape.stroke(LinearGradient(colors: [.white.opacity(dark ? 0.3 : 0.9), .white.opacity(dark ? 0.1 : 0.35)],
                                        startPoint: .top, endPoint: .bottom), lineWidth: 1)
            bars(centerY: centerY)
            Text(cancelling ? "松开取消" : "✕ 取消")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .opacity(max(0, min(1, (extent - 0.45) / 0.35)) * (cancelling ? 1 : 0.8))
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
