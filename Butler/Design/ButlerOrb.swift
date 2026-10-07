import SwiftUI

/// The butler: a clear glass ball with a little warm light and colour glowing at its centre.
/// Drawn in a 200-point space (the same geometry as the app icon) and scaled to `size`.
/// While `active` (listening or thinking) the light inside drifts slowly.
struct ButlerOrb: View {
    var size: CGFloat = 44
    var active = false
    /// Let the light inside wander slowly even when nothing is happening (the floating orb).
    var drift = false
    /// How far the phone is tilted (-1…1 each way): the light inside and the reflection move against each other.
    var tilt: CGSize = .zero
    var pressure: CGFloat = 0
    var contact: CGPoint = .zero

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var phaseBase: Double = 0
    @State private var phaseStarted = ProcessInfo.processInfo.systemUptime

    var body: some View {
        Group {
            if (active || drift) && !reduceMotion && scenePhase == .active {
                TimelineView(.animation(minimumInterval: active ? nil : 1.0 / 30)) { _ in
                    let elapsed = ProcessInfo.processInfo.systemUptime - phaseStarted
                    ball(phase: phaseBase + elapsed * (active ? 1 : 0.35))
                }
            } else {
                ball(phase: 0)
            }
        }
        .frame(width: size, height: size)
        .onChange(of: active) { old, _ in
            let now = ProcessInfo.processInfo.systemUptime
            phaseBase += (now - phaseStarted) * (old ? 1 : 0.35)
            phaseStarted = now
        }
        .accessibilityHidden(true)
    }

    private func ball(phase: Double) -> some View {
        OrbDrawing(palette: colorScheme == .dark ? .night : .day, phase: phase, active: active,
                   tilt: tilt, pressure: pressure, contact: contact)
            .frame(width: 200, height: 200)
            .scaleEffect(size / 200 * 1.13)
            .frame(width: size, height: size)
    }
}

struct OrbPalette {
    var edge: Color
    var edgeOpacity: Double
    var body: Double
    var rim: Double
    var glow: [(Color, Double)]
    var core: Color
    var coreOpacity: Double
    var caustic: Double
    var spec: Double
    var halo: Double

    static let day = OrbPalette(
        edge: Color(red: 0.29, green: 0.29, blue: 0.37), edgeOpacity: 0.30, body: 0, rim: 0.95,
        glow: [(Color(red: 1, green: 0.48, blue: 0.72), 0.50), (Color(red: 0.38, green: 0.82, blue: 1), 0.50), (Color(red: 0.64, green: 0.55, blue: 1), 0.45)],
        core: Color(red: 1, green: 0.96, blue: 0.90), coreOpacity: 0.95, caustic: 0.55, spec: 0.85, halo: 0)

    static let night = OrbPalette(
        edge: .white, edgeOpacity: 0.16, body: 0.07, rim: 0.85,
        glow: [(Color(red: 1, green: 0.44, blue: 0.69), 0.55), (Color(red: 0.31, green: 0.78, blue: 1), 0.55), (Color(red: 0.56, green: 0.45, blue: 1), 0.50)],
        core: Color(red: 1, green: 0.94, blue: 0.85), coreOpacity: 0.75, caustic: 0.45, spec: 0.45, halo: 0.10)
}

/// The layers of the glass ball, in the 200 × 200 icon space (ball radius 86 around the centre).
private struct OrbDrawing: View {
    let palette: OrbPalette
    let phase: Double
    let active: Bool
    var tilt: CGSize = .zero
    var pressure: CGFloat = 0
    var contact: CGPoint = .zero

    private var ball: Path {
        guard pressure > 0.001 else { return Circle().path(in: CGRect(x: 14, y: 14, width: 172, height: 172)) }
        return Path { path in
            path.addLines(OrbPress.outline(radius: 86, contact: contact, depth: pressure)
                .map { CGPoint(x: 100 + $0.x, y: 100 + $0.y) })
            path.closeSubpath()
        }
    }

    var body: some View {
        let p = palette
        let drift = phase
        let ball = self.ball
        ZStack {
            // A little light escaping the glass (dark only).
            Circle().fill(.white.opacity(p.halo))
                .frame(width: 160, height: 160).position(x: 100, y: 104).blur(radius: 15)

            // The glass itself: clear in the middle, thicker and darker towards the rim.
            ball.fill(RadialGradient(stops: [
                .init(color: .white.opacity(p.body), location: 0),
                .init(color: .white.opacity(p.body * 0.3), location: 0.62),
                .init(color: p.edge.opacity(p.edgeOpacity * 0.45), location: 0.86),
                .init(color: p.edge.opacity(p.edgeOpacity), location: 1),
            ], center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 103))

            ZStack {
                // Glass flips its surroundings: a faint shade in the upper half.
                Ellipse().fill(p.edge.opacity(p.edgeOpacity * 0.35))
                    .frame(width: 140, height: 80).position(x: 100, y: 62).blur(radius: 15)

                // The only colour: a little liquid at the centre, always flowing. It sits deep inside, so it moves with the tilt.
                flowGlow(drift: drift)
                    .offset(x: tilt.width * 7, y: tilt.height * 7)

                // Light gathered at the bottom of the ball.
                Caustic().fill(LinearGradient(colors: [.white.opacity(p.caustic * 0.75), .white.opacity(0)],
                                              startPoint: .bottom, endPoint: .top))
                    .blur(radius: 5)
                Ellipse().fill(p.core.opacity(0.25))
                    .frame(width: 52, height: 14).position(x: 100, y: 162).blur(radius: 6)

                // Reflection of the sky across the top, and one bright point.
                // The reflection is on the surface, so it slides the other way.
                Group {
                    // Soft all the way down: no visible lower edge where the reflection ends.
                    TopReflection().fill(LinearGradient(stops: [
                        .init(color: .white.opacity(p.spec), location: 0),
                        .init(color: .white.opacity(p.spec * 0.35), location: 0.45),
                        .init(color: .white.opacity(0), location: 0.8),
                    ], startPoint: .top, endPoint: .bottom))
                        .blur(radius: 5)
                    Ellipse().fill(.white.opacity(0.9))
                        .frame(width: 24, height: 12).rotationEffect(.degrees(-38)).position(x: 66, y: 60).blur(radius: 0.9)
                }
                .offset(x: -tilt.width * 6 - contact.x * pressure * 8,
                        y: -tilt.height * 4 - contact.y * pressure * 8)

                // Light gathered just inside the bottom edge (no line across the lower half: real glass has none),
                // brightest at the bottom and fading up the sides; then the thickness of the glass.
                Circle()
                    .trim(from: 0.06, to: 0.44)
                    .stroke(LinearGradient(stops: [
                        .init(color: .white.opacity(0), location: 0),
                        .init(color: .white.opacity(0.55), location: 0.5),
                        .init(color: .white.opacity(0), location: 1),
                    ], startPoint: .leading, endPoint: .trailing), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 162, height: 162)
                    .position(x: 100, y: 100)
                    .blur(radius: 2.5)
                ball.stroke(LinearGradient(stops: [
                    .init(color: p.edge.opacity(0), location: 0.6),
                    .init(color: p.edge.opacity(p.edgeOpacity * 1.2), location: 1),
                ], startPoint: UnitPoint(x: 0.2, y: 0), endPoint: UnitPoint(x: 0.8, y: 1)), lineWidth: 3)
                    .scaleEffect(168.0 / 172).blur(radius: 0.9)
            }
            .clipShape(ball)

            ball.stroke(LinearGradient(stops: [
                .init(color: .white.opacity(p.rim), location: 0),
                .init(color: .white.opacity(0.12), location: 0.5),
                .init(color: .white.opacity(p.rim * 0.55), location: 0.85),
                .init(color: .white.opacity(p.rim * 0.5), location: 1),
            ], startPoint: UnitPoint(x: 0.15, y: 0), endPoint: UnitPoint(x: 0.85, y: 1)), lineWidth: 1.2)
                .scaleEffect(171.0 / 172)
        }
        .frame(width: 200, height: 200)
        .compositingGroup()
    }

    /// Three colours carried by a slowly turning, warped flow (Metal shader `orbGlowFlow`), no fixed bright core.
    private func flowGlow(drift: Double) -> some View {
        let g = palette.glow
        return Rectangle()
            .colorEffect(ShaderLibrary.orbGlowFlow(
                .boundingRect, .float(Float(drift)),
                .color(g[0].0), .color(g[1].0), .color(g[2].0),
                .float(Float(g[0].1)), .float(Float(g[1].1)), .float(Float(g[2].1))))
            .frame(width: 200, height: 200)
            .blur(radius: 3.5)
    }
}

private struct Caustic: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 44, y: 150))
        path.addQuadCurve(to: CGPoint(x: 156, y: 150), control: CGPoint(x: 100, y: 216))
        path.addQuadCurve(to: CGPoint(x: 44, y: 150), control: CGPoint(x: 100, y: 176))
        return path
    }
}

private struct TopReflection: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 42, y: 74))
        path.addQuadCurve(to: CGPoint(x: 158, y: 74), control: CGPoint(x: 100, y: 0))
        path.addQuadCurve(to: CGPoint(x: 42, y: 74), control: CGPoint(x: 100, y: 46))
        return path
    }
}

#Preview {
    HStack(spacing: 20) {
        ButlerOrb(size: 120)
        ButlerOrb(size: 64, active: true)
        ButlerOrb(size: 32)
    }
    .padding()
}
