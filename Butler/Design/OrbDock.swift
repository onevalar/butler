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
    @State private var voiceWidth: CGFloat = VoiceGeometry.ballWidth
    @State private var cancelExtent: CGFloat = 0

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
            Group {
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
            }
            .animation(motionEnabled ? .easeOut(duration: 0.18) : nil, value: presentingVoice)

            // One mounted glass surface owns the complete ball → bar → ball morph.
            // Width also drives reflections, so lighting never jumps ahead of the outline.
            GeometryReader { proxy in
                VoiceGlass(width: proxy.size.width, height: 340, barWidth: voiceWidth, extent: cancelExtent,
                           level: recorder.dictation.audioLevel, recording: interaction.phase == .recording,
                           cancelling: interaction.cancelling, active: working || recorder.dictation.listening,
                           tilt: motionEnabled ? motion.tilt : .zero)
            }
            .frame(height: 340)
            .allowsHitTesting(false)

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
        #if DEBUG
        .task {
            // Reproducible visual QA without opening a microphone or sending speech.
            guard ProcessInfo.processInfo.arguments.contains("--preview-orb-morph") else { return }
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    // Preview must animate even if another simulator window has focus.
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.42)) {
                        cancelExtent = 0
                        voiceWidth = VoiceGeometry.barWidth
                    }
                    try await Task.sleep(for: .seconds(1))
                    withAnimation(.smooth(duration: 0.4)) { cancelExtent = 1 }
                    try await Task.sleep(for: .seconds(1))
                    hideVoiceGlass(animated: !reduceMotion)
                }
            } catch { }
        }
        #endif
        .onChange(of: interaction.held) { _, held in
            if held { showVoiceGlass() } else { hideVoiceGlass(animated: motionEnabled) }
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
        // A single continuous expansion crosses the hold threshold without stopping at a bulge.
        // Interruptions retarget SwiftUI's current presentation value, including a quick re-press.
        withAnimation(motionEnabled ? .smooth(duration: 0.42) : nil) {
            cancelExtent = 0
            voiceWidth = VoiceGeometry.barWidth
        }
    }

    private func hideVoiceGlass(animated: Bool) {
        withAnimation(animated ? .smooth(duration: 0.32) : nil) {
            voiceWidth = VoiceGeometry.ballWidth
            cancelExtent = 0
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

/// Surface light follows the *same* outline as the glass. There is no separate
/// round orb underneath the bar and no cross-fade between two physical objects.
private struct VoiceOrbLight: View {
    let shape: Path
    let bounds: CGRect
    let active: Bool
    let tilt: CGSize
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var phaseBase = 0.0
    @State private var phaseStarted = ProcessInfo.processInfo.systemUptime

    var body: some View {
        TimelineView(.animation(minimumInterval: active ? 1.0 / 60 : 1.0 / 30,
                                paused: reduceMotion || scenePhase != .active)) { _ in
            let elapsed = ProcessInfo.processInfo.systemUptime - phaseStarted
            lighting(phase: reduceMotion ? 0 : phaseBase + elapsed * (active ? 1 : 0.35))
        }
        .onChange(of: active) { old, _ in
            let now = ProcessInfo.processInfo.systemUptime
            phaseBase += (now - phaseStarted) * (old ? 1 : 0.35)
            phaseStarted = now
        }
    }

    private func lighting(phase: Double) -> some View {
        let palette = scheme == .dark ? OrbPalette.night : .day
        let diameter = bounds.height
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let innerShape = shape.applying(CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(scaleX: 0.96, y: 0.96))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
        return ZStack {
            // The depth gradient, shader light and reflections stretch with the
            // physical surface, all the way from the resting sphere to the bar.
            Rectangle().fill(RadialGradient(stops: [
                .init(color: .white.opacity(palette.body), location: 0),
                .init(color: .white.opacity(palette.body * 0.3), location: 0.62),
                .init(color: palette.edge.opacity(palette.edgeOpacity * 0.45), location: 0.86),
                .init(color: palette.edge.opacity(palette.edgeOpacity), location: 1),
            ], center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: diameter * 0.60))
                .frame(width: diameter, height: diameter)
                .scaleEffect(x: bounds.width / diameter, y: 1)
                .position(center)
            Ellipse().fill(palette.edge.opacity(palette.edgeOpacity * 0.35))
                .frame(width: bounds.width * 0.81, height: diameter * 0.46)
                .position(x: center.x, y: bounds.minY + diameter * 0.28)
                .blur(radius: diameter * 0.087)
            Rectangle()
                .colorEffect(ShaderLibrary.orbGlowFlow(
                    .boundingRect, .float(Float(phase)),
                    .color(palette.glow[0].0), .color(palette.glow[1].0), .color(palette.glow[2].0),
                    .float(Float(palette.glow[0].1)), .float(Float(palette.glow[1].1)), .float(Float(palette.glow[2].1))))
                .frame(width: diameter / 0.86, height: diameter / 0.86)
                .blur(radius: 1.3)
                .scaleEffect(x: bounds.width / diameter, y: 1)
                .position(x: center.x + tilt.width * 2.5, y: center.y + tilt.height * 2.5)
            topReflection.fill(LinearGradient(colors: [.white.opacity(palette.spec), .white.opacity(0)],
                                              startPoint: .top, endPoint: .bottom))
                .blur(radius: 1.8)
                .offset(x: -tilt.width * 2, y: -tilt.height * 1.4)
            Ellipse().fill(.white.opacity(0.9))
                .frame(width: bounds.width * 0.14, height: diameter * 0.07)
                .rotationEffect(.degrees(-25))
                .position(x: bounds.minX + bounds.width * 0.30 - tilt.width * 2,
                          y: bounds.minY + diameter * 0.26 - tilt.height * 1.4)
                .blur(radius: 0.45)
            Ellipse().fill(palette.core.opacity(0.25))
                .frame(width: bounds.width * 0.30, height: diameter * 0.08)
                .position(x: center.x, y: bounds.maxY - diameter * 0.14)
                .blur(radius: diameter * 0.035)
            innerShape.stroke(palette.edge.opacity(palette.edgeOpacity * 0.55), lineWidth: 0.7)
                .blur(radius: 0.35)
            innerShape.stroke(LinearGradient(colors: [.clear, .white.opacity(palette.caustic)],
                                             startPoint: .center, endPoint: .bottom), lineWidth: 1.5)
                .blur(radius: 0.9)
        }
        .clipShape(shape)
    }

    private var topReflection: Path {
        let x = bounds.minX, y = bounds.minY, w = bounds.width, h = bounds.height
        return Path { path in
            path.move(to: CGPoint(x: x + w * 0.16, y: y + h * 0.35))
            path.addQuadCurve(to: CGPoint(x: x + w * 0.84, y: y + h * 0.35),
                              control: CGPoint(x: x + w * 0.5, y: y - h * 0.08))
            path.addQuadCurve(to: CGPoint(x: x + w * 0.16, y: y + h * 0.35),
                              control: CGPoint(x: x + w * 0.5, y: y + h * 0.22))
        }
    }
}

/// The glass while talking: the ball as a bar with round ends, voice bars on both sides of the finger,
/// and a red cancel zone that grows out of the same glass when the finger slides up.
private struct VoiceGlass: View, Animatable {
    let width: CGFloat
    let height: CGFloat
    var barWidth: CGFloat
    var extent: CGFloat
    let level: CGFloat
    let recording: Bool
    let cancelling: Bool
    let active: Bool
    let tilt: CGSize
    @Environment(\.colorScheme) private var colorScheme

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(barWidth, extent) }
        set { barWidth = newValue.first; extent = newValue.second }
    }

    private func outline(_ geometry: VoiceGeometry, centerY: CGFloat) -> Path {
        if extent <= 0.001 {
            return Path(roundedRect: CGRect(x: (width - barWidth) / 2, y: centerY - 31,
                                            width: barWidth, height: 62), cornerRadius: 31)
        }
        return Path { path in
            for contour in geometry.contours(width: width, height: height, centerY: centerY) {
                path.addLines(contour)
                path.closeSubpath()
            }
        }
    }

    var body: some View {
        let centerY = height - OrbPose.ballLift
        let geometry = VoiceGeometry(barWidth: barWidth, extent: extent)
        let shape = outline(geometry, centerY: centerY)
        let dark = colorScheme == .dark
        let grow = extent * extent * (3 - 2 * extent)
        ZStack {
            Color.clear.glassEffect(.clear, in: shape)
            VoiceOrbLight(shape: shape,
                          bounds: CGRect(x: (width - barWidth) / 2, y: centerY - 31, width: barWidth, height: 62),
                          active: active, tilt: tilt)
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
        let show = max(0, min(1, (barWidth - 148) / 28))
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
