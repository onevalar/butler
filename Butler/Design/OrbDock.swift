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
    @State private var separation: CGFloat = 0
    @State private var contact = CGSize.zero
    @State private var returnProgress: CGFloat = 1
    @State private var returning = false
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
                           separation: separation, contact: contact, returnProgress: returnProgress, returning: returning,
                           level: recorder.dictation.audioLevel, recording: interaction.phase == .recording,
                           cancelling: interaction.cancelling, active: working || recorder.dictation.listening,
                           tilt: motionEnabled ? motion.tilt : .zero)
                    .animation(motionEnabled ? .easeOut(duration: 0.12) : nil, value: recorder.dictation.audioLevel)
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
                }, onContact: { point in
                    contact = CGSize(width: max(-16, min(16, point.x - 48)), height: max(-16, min(16, point.y - 48)))
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
                        returning = false
                        separation = 0
                        cancelExtent = 0
                        voiceWidth = VoiceGeometry.barWidth
                    }
                    try await Task.sleep(for: .seconds(1))
                    withAnimation(.linear(duration: 1.6)) { cancelExtent = 0.76 }
                    try await Task.sleep(for: .seconds(2.2))
                    withAnimation(.linear(duration: 0.25)) { cancelExtent = 0.9 }
                    try await Task.sleep(for: .seconds(0.25))
                    withAnimation(.easeOut(duration: 0.18)) { separation = 1 }
                    try await Task.sleep(for: .seconds(1))
                    hideVoiceGlass(animated: !reduceMotion)
                }
            } catch { }
        }
        #endif
        .onChange(of: interaction.cancelling) { _, cancelling in
            guard interaction.held else { return }
            withAnimation(motionEnabled ? .easeOut(duration: 0.18) : nil) { separation = cancelling ? 1 : 0 }
        }
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
        visualSession = UUID()
        returning = false
        returnProgress = 1
        withAnimation(motionEnabled ? .easeInOut(duration: 0.32) : nil) {
            cancelExtent = 0
            separation = 0
            voiceWidth = VoiceGeometry.barWidth
        }
    }

    private func hideVoiceGlass(animated: Bool) {
        let token = UUID(); visualSession = token
        if animated && cancelExtent > 0.78 {
            // Release is a fall, contact, then one local compression — not the pull animation reversed.
            returning = true
            returnProgress = 0
            withAnimation(.linear(duration: 0.62), completionCriteria: .logicallyComplete) {
                returnProgress = 1
            } completion: {
                guard visualSession == token, !interaction.held else { return }
                returning = false
                voiceWidth = VoiceGeometry.ballWidth
                cancelExtent = 0
                separation = 0
            }
        } else {
            returning = false
            withAnimation(animated ? .spring(duration: 0.42, bounce: 0.12) : nil) {
                voiceWidth = VoiceGeometry.ballWidth
                cancelExtent = 0
                separation = 0
            }
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
    var audio: CGFloat = 0
    var pressure: CGFloat = 0
    var contact = CGSize.zero
    var freezeLighting = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var phaseBase = 0.0
    @State private var phaseStarted = ProcessInfo.processInfo.systemUptime

    var body: some View {
        TimelineView(.animation(minimumInterval: active ? 1.0 / 60 : 1.0 / 30,
                                paused: reduceMotion || freezeLighting || scenePhase != .active)) { _ in
            let elapsed = ProcessInfo.processInfo.systemUptime - phaseStarted
            lighting(phase: reduceMotion || freezeLighting ? 0 : phaseBase + elapsed * (active ? 1 : 0.35))
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
                .opacity(0.72 + audio * 0.28)
                .blur(radius: 1.3 - audio * 0.35)
                .scaleEffect(x: bounds.width / diameter, y: 1)
                .position(x: center.x + tilt.width * 2.5, y: center.y + tilt.height * 2.5)
            Rectangle().fill(.white)
                .colorEffect(ShaderLibrary.orbContactSurface(.boundingRect, .float(Float(pressure)),
                    .float2(Float(contact.width), Float(contact.height))))
                .frame(width: bounds.width, height: bounds.height)
                .position(center)
            topReflection.fill(LinearGradient(colors: [.white.opacity(palette.spec), .white.opacity(0)],
                                              startPoint: .top, endPoint: .bottom))
                .opacity(1 - pressure * 0.72)
                .blur(radius: 1.8)
                .offset(x: -tilt.width * 2, y: -tilt.height * 1.4)
            Ellipse().fill(.white.opacity(0.9 * (1 - pressure * 0.85)))
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

/// Pressure and the measured voice level deform the same glass. Pulling up empties the dock.
private struct VoiceGlass: View, Animatable {
    let width: CGFloat
    let height: CGFloat
    var barWidth: CGFloat
    var extent: CGFloat
    var separation: CGFloat
    let contact: CGSize
    var returnProgress: CGFloat
    let returning: Bool
    var level: CGFloat
    let recording: Bool
    let cancelling: Bool
    let active: Bool
    let tilt: CGSize
    var freezeLighting = false
    @Environment(\.colorScheme) private var colorScheme

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get { AnimatablePair(AnimatablePair(barWidth, extent), AnimatablePair(level, AnimatablePair(separation, returnProgress))) }
        set { barWidth = newValue.first.first; extent = newValue.first.second
            level = newValue.second.first; separation = newValue.second.second.first; returnProgress = newValue.second.second.second }
    }

    private func outline(_ geometry: VoiceGeometry, centerY: CGFloat) -> Path {
        return Path { path in
            for contour in geometry.contours(width: width, height: height, centerY: centerY) {
                path.addLines(contour)
                path.closeSubpath()
            }
        }
    }

    var body: some View {
        let release = VoiceReturnPose(progress: returnProgress)
        let impact = returning ? release.impact : 0
        let centerY = returning ? release.centerY(dockY: height - OrbPose.ballLift) : height - OrbPose.ballLift
        let audio = recording && !cancelling ? max(0, min(1, level)) : 0
        let geometry = VoiceGeometry(barWidth: returning ? 62 + 38 * impact : barWidth + 1.4 * audio,
            extent: returning ? 0 : extent, separation: returning ? 0 : separation)
        let shape = outline(geometry, centerY: centerY)
        let dark = colorScheme == .dark
        let grow = returning ? release.cancelOpacity : VoiceGeometry.smooth(extent)
        let cancelEmphasis = cancelling || returning
        ZStack {
            Color.clear.glassEffect(.clear, in: shape)
            VoiceOrbLight(shape: shape,
                          bounds: shape.boundingRect,
                          active: active, tilt: tilt, audio: audio, pressure: geometry.contactDepth, contact: contact, freezeLighting: freezeLighting)
            // The cancel zone is the same glass turning red, brightest at its far end.
            LinearGradient(stops: [.init(color: Color(red: 1, green: 0.23, blue: 0.19).opacity(cancelEmphasis ? 0.30 : 0.18), location: 0),
                                   .init(color: Color(red: 1, green: 0.27, blue: 0.23).opacity(cancelEmphasis ? 0.12 : 0.08), location: 0.55),
                                   .init(color: Color(red: 1, green: 0.32, blue: 0.27).opacity(0), location: 1)],
                           startPoint: UnitPoint(x: 0.5, y: max(0, (centerY - geometry.topReach) / height)),
                           endPoint: UnitPoint(x: 0.5, y: (centerY - 4) / height))
                .opacity(grow)
                .clipShape(shape)
            shape.stroke(LinearGradient(colors: [.white.opacity(dark ? 0.3 : 0.9), .white.opacity(dark ? 0.1 : 0.35)],
                                        startPoint: .top, endPoint: .bottom), lineWidth: 1)
            Image(systemName: "xmark")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color(red: 0.82, green: 0.16, blue: 0.12))
                .opacity((returning ? release.cancelOpacity : max(0, min(1, (extent - 0.65) / 0.15))) * (cancelEmphasis ? 1 : 0.8))
                // A returning sphere has no raised head: its mark shares the falling centre.
                .position(x: width / 2, y: returning ? centerY : centerY - geometry.zoneOffset)
                .clipShape(shape)
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(dark ? 0.35 : 0.14), radius: 14, y: 8)
        .accessibilityHidden(true)
    }

}

#if DEBUG
/// Isolated visual catalogue. No microphone, model, permissions or durable stores.
struct OrbStoryboardPreview: View {
    @State private var began = Date.now
    private let durations: [Double] = [4, 3, 5, 4, 8, 7, 8, 4]
    private let titles = ["待机与倾斜反光", "短按与恢复", "长按与音量外观对照", "松开发送与等待", "上滑取消与下落归位", "未取消时滑回继续", "进入取消后滑回继续", "减少动态效果"]
    private let notes = ["稳定球体，内部流光与倾斜反光", "仅展示球体反馈；正式短按会打开对话", "音量参数依次为 0 / 0.35 / 0.7 / 1；不是现场录音", "收回受压形态，整理期间保留内部流光", "叉号与球体同一轨迹，红色和叉号在球内淡出", "未越过取消边界，上提与回拖连续可逆", "越过边界后再拖回，恢复录音形态", "静态分段切换，关闭流光与弹性回落"]
    private var dark: Bool { ProcessInfo.processInfo.arguments.contains("--orb-dark") }

    var body: some View {
        TimelineView(.animation) { timeline in
            catalogueFrame(at: timeline.date)
        }
        .preferredColorScheme(dark ? .dark : .light)
    }

    private func catalogueFrame(at date: Date) -> some View {
        let total = durations.reduce(0, +)
        let time = date.timeIntervalSince(began).truncatingRemainder(dividingBy: total)
        let index = scene(at: time)
        let t = time - durations.prefix(index).reduce(0, +)
        let current = pose(scene: index, t: t)
        return ZStack {
            LinearGradient(colors: [Color(.systemBackground), Color(.systemGray5)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 12) {
                Text(titles[index]).font(.headline).padding(.top, 60)
                Text(notes[index]).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
                Spacer()
                glass(current, scene: index, time: t)
                    .scaleEffect(1.5).frame(height: 450)
                Spacer()
            }
        }
    }

    private func glass(_ current: Pose, scene: Int, time: Double) -> some View {
        let tilt = scene == 0 ? CGSize(width: sin(time * 1.5) * 0.7, height: cos(time * 1.5) * 0.4) : CGSize.zero
        return VoiceGlass(width: 220, height: 330, barWidth: 62 + 38 * current.pressure,
            extent: current.extent, separation: current.separation, contact: CGSize(width: 3, height: -5),
            returnProgress: current.returnProgress, returning: current.returning,
            level: current.level, recording: scene == 2, cancelling: current.cancelling,
            active: scene != 0, tilt: tilt, freezeLighting: scene == 7)
    }

    private func scene(at time: Double) -> Int {
        var end = 0.0
        for (index, duration) in durations.enumerated() { end += duration; if time < end { return index } }
        return durations.count - 1
    }

    private struct Pose {
        var pressure: CGFloat = 0
        var extent: CGFloat = 0
        var separation: CGFloat = 0
        var returnProgress: CGFloat = 1
        var returning = false
        var cancelling = false
        var level: CGFloat = 0
    }

    private func pose(scene: Int, t: Double) -> Pose {
        func ramp(_ start: Double, _ duration: Double) -> CGFloat { VoiceGeometry.smooth(CGFloat((t - start) / duration)) }
        // Normal release is a short damped spring; this catalogue samples its envelope.
        func recovery(_ start: Double) -> CGFloat {
            let x = max(0, t - start)
            return x >= 0.65 ? 0 : CGFloat(exp(-11 * x) * cos(13 * x))
        }
        var p = Pose()
        switch scene {
        case 0: break
        case 1:
            p.pressure = t < 0.55 ? ramp(0.35, 0.32) : ramp(0.35, 0.32) * recovery(0.55)
        case 2:
            p.pressure = ramp(0.25, 0.32)
            p.level = t < 1.5 ? 0 : t < 2.5 ? 0.35 : t < 3.5 ? 0.7 : 1
        case 3:
            p.pressure = t < 1 ? 1 : recovery(1)
        case 4:
            p.pressure = ramp(0.2, 0.32)
            p.extent = 0.9 * ramp(1, 2)
            p.separation = ramp(2.8, 0.18)
            p.cancelling = t >= 2.8 && t < 5
            if t >= 5 && t < 5.62 { p.returning = true; p.returnProgress = CGFloat((t - 5) / 0.62) }
            if t >= 5.62 { p = Pose() }
        case 5:
            p.pressure = ramp(0.2, 0.32)
            p.extent = 0.74 * ramp(1, 1.5) * (1 - ramp(2.7, 1.5))
            if t >= 5 { p.pressure = recovery(5) }
        case 6:
            p.pressure = ramp(0.2, 0.32)
            p.extent = 0.9 * ramp(1, 1.5) * (1 - ramp(3.5, 1.5))
            p.separation = ramp(2.3, 0.18) * (1 - ramp(3.9, 0.18))
            p.cancelling = t >= 2.3 && t < 3.9
            if t >= 6 { p.pressure = recovery(6) }
        default:
            if t >= 1 && t < 3 { p.pressure = 1 }
            if t >= 2 && t < 3 { p.extent = 0.9; p.separation = 1; p.cancelling = true }
        }
        return p
    }
}
#endif
