import SwiftUI

/// Light, dark, or follow the system.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: Self { self }

    var title: String {
        switch self {
        case .light: "浅色"
        case .dark: "深色"
        case .system: "跟随系统"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }
}

/// The one colour the owner may pick. "玻璃" (the default) uses no colour at all: brand elements
/// take the label colour, black in light mode and white in dark mode.
enum AccentChoice: String, CaseIterable, Identifiable {
    case glass, celadon, ocean, amber, berry, dusk
    var id: Self { self }

    var title: String {
        switch self {
        case .glass: "玻璃"
        case .celadon: "青瓷"
        case .ocean: "海蓝"
        case .amber: "暖橘"
        case .berry: "莓红"
        case .dusk: "暮紫"
        }
    }

    var accent: ButlerAccent {
        switch self {
        case .glass: ButlerAccent(fill: .primary, onFill: Color(.systemBackground))
        case .celadon: ButlerAccent(fill: Color(light: 0x0F766E, dark: 0x2BA89C), onFill: .white)
        case .ocean: ButlerAccent(fill: Color(light: 0x1D6FE0, dark: 0x4C94FF), onFill: .white)
        case .amber: ButlerAccent(fill: Color(light: 0xD9711A, dark: 0xF08A34), onFill: .white)
        case .berry: ButlerAccent(fill: Color(light: 0xD6336C, dark: 0xF0527F), onFill: .white)
        case .dusk: ButlerAccent(fill: Color(light: 0x6E56CF, dark: 0x9580F0), onFill: .white)
        }
    }

    static let storageKey = "accentChoice"
    static let modeKey = "appearanceMode"
    static let glowKey = "ambientGlow"
}

/// Brand colour for send, mic, confirm, the selected day and the selected tab.
/// Meaning colours (expired red, expiring orange, reminder blue) never change with it.
struct ButlerAccent {
    var fill: Color
    var onFill: Color
}

extension EnvironmentValues {
    @Entry var butlerAccent = AccentChoice.glass.accent
}

extension View {
    /// Applies the owner's appearance choices to everything below. Used once at the root.
    func butlerAppearance(mode: AppearanceMode, accent: AccentChoice) -> some View {
        environment(\.butlerAccent, accent.accent)
            .tint(accent.accent.fill)
            .preferredColorScheme(mode.colorScheme)
    }
}

// MARK: - Glass surfaces

/// The page ground: system grey with, if the owner keeps it on, a few soft lights behind the glass
/// in the orb's colours, so cards have something to show through.
struct ButlerBackground: View {
    @AppStorage(AccentChoice.glowKey) private var glow = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        ZStack {
            Color(light: 0xF2F2F6, dark: 0x0B0B0F)
            if glow {
                GeometryReader { proxy in
                    let size = proxy.size
                    let reach = max(size.width, size.height)
                    ZStack {
                        light(Color(red: 0.62, green: 0.56, blue: 1), dark ? 0.20 : 0.18, at: UnitPoint(x: 0.12, y: 0.08), reach * 0.45)
                        light(Color(red: 0.45, green: 0.78, blue: 1), dark ? 0.12 : 0.16, at: UnitPoint(x: 0.95, y: 0.30), reach * 0.40)
                        light(Color(red: 1, green: 0.55, blue: 0.78), dark ? 0.06 : 0.08, at: UnitPoint(x: 0.30, y: 0.68), reach * 0.38)
                        light(Color(red: 1, green: 0.72, blue: 0.55), dark ? 0.10 : 0.14, at: UnitPoint(x: 0.80, y: 0.96), reach * 0.45)
                    }
                    .frame(width: size.width, height: size.height)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func light(_ color: Color, _ opacity: Double, at point: UnitPoint, _ radius: CGFloat) -> some View {
        RadialGradient(colors: [color.opacity(opacity), color.opacity(0)], center: point, startRadius: 0, endRadius: radius)
    }
}

extension View {
    /// A frosted card: translucent white (or smoke in dark mode) with a hairline edge.
    func glassCard(radius: CGFloat = 26) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(ButlerSurface.card, in: shape)
            .overlay(shape.strokeBorder(ButlerSurface.cardEdge, lineWidth: 0.5))
            .shadow(color: ButlerSurface.shadow, radius: 12, y: 4)
    }
}

enum ButlerSurface {
    static let card = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.17, green: 0.17, blue: 0.20, alpha: 0.62) : UIColor(white: 1, alpha: 0.72)
    })
    static let cardEdge = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 1, alpha: 0.9)
    })
    static let shadow = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.25) : UIColor(red: 0.12, green: 0.12, blue: 0.24, alpha: 0.05)
    })
}

/// A filled capsule button in the brand colour (send / confirm style).
struct AccentButtonStyle: ButtonStyle {
    var height: CGFloat = 44
    @Environment(\.butlerAccent) private var accent
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(accent.onFill)
            .frame(maxWidth: .infinity, minHeight: height)
            .padding(.horizontal, 16)
            .background(accent.fill, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// A quiet capsule button on a grey fill (cancel / secondary).
struct QuietButtonStyle: ButtonStyle {
    var height: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: height)
            .padding(.horizontal, 16)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
