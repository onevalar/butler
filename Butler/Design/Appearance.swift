import CoreImage.CIFilterBuiltins
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
        case .glass: ButlerAccent(fill: Color(uiColor: .label), onFill: Color(uiColor: .systemBackground))
        case .celadon: ButlerAccent(fill: Color(light: 0x0F766E, dark: 0x2BA89C), onFill: .white)
        case .ocean: ButlerAccent(fill: Color(light: 0x1D6FE0, dark: 0x4C94FF), onFill: .white)
        case .amber: ButlerAccent(fill: Color(light: 0xD9711A, dark: 0xF08A34), onFill: .white)
        case .berry: ButlerAccent(fill: Color(light: 0xD6336C, dark: 0xF0527F), onFill: .white)
        case .dusk: ButlerAccent(fill: Color(light: 0x6E56CF, dark: 0x9580F0), onFill: .white)
        }
    }

    /// A concrete track colour: semantic `.primary` is a foreground style, and
    /// becomes white in dark mode while the native switch thumb is also white.
    var switchTint: Color {
        self == .glass ? Color(light: 0x48484A, dark: 0x636366) : accent.fill
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
            .toggleStyle(SwitchToggleStyle(tint: accent.switchTint))
            .preferredColorScheme(mode.colorScheme)
    }
}

// MARK: - Glass surfaces

// MARK: - Theme (the page ground)

/// What sits behind the glass: 雾面 (default), 窗边的光 or 素净. Chosen in 设置 › 外观.
enum AppTheme: String, CaseIterable, Identifiable {
    case mist, window, plain
    var id: Self { self }

    var title: String {
        switch self {
        case .mist: "雾面"
        case .window: "窗边的光"
        case .plain: "素净"
        }
    }

    var caption: String {
        switch self {
        case .mist: "默认 · 安静"
        case .window: "斜斜的光影"
        case .plain: "什么都不加"
        }
    }

    static let storageKey = "appTheme"

    /// The choice stored on this device. Older installs had a 背景光 switch: off meant no light at all.
    static func stored(in defaults: UserDefaults = .standard) -> AppTheme {
        if let raw = defaults.string(forKey: storageKey), let theme = AppTheme(rawValue: raw) { return theme }
        if defaults.object(forKey: AccentChoice.glowKey) as? Bool == false { return .plain }
        return .mist
    }

    /// Writes the migrated choice once, so the old switch stops mattering.
    static func migrateLegacyGlow(in defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: storageKey) == nil else { return }
        defaults.set(stored(in: defaults).rawValue, forKey: storageKey)
    }
}

/// The page ground: the chosen theme's light, with a very fine grain so it reads as material, not a flat gradient.
struct ButlerBackground: View {
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .mist
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ThemeBackdrop(theme: theme, dark: colorScheme == .dark)
            .ignoresSafeArea()
    }
}

/// One theme drawn at any size (the full screen, or a small preview in 外观).
struct ThemeBackdrop: View {
    let theme: AppTheme
    let dark: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                switch theme {
                case .plain: Color(light: 0xF2F2F6, dark: 0x0B0B0F)
                case .mist: mist(size)
                case .window: window(size)
                }
                if theme != .plain {
                    Image(uiImage: GrainTexture.image)
                        .resizable(resizingMode: .tile)
                        .blendMode(.overlay)
                        .opacity(dark ? 0.10 : 0.07)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    // Shapes are placed in a 390 × 844 design space and scaled to whatever size is asked for.

    private func mist(_ size: CGSize) -> some View {
        let sx = size.width / 390, sy = size.height / 844
        return ZStack {
            LinearGradient(stops: dark
                ? [.init(color: Color(hex: 0x17181C), location: 0), .init(color: Color(hex: 0x0C0C0F), location: 1)]
                : [.init(color: Color(hex: 0xF1F2F4), location: 0), .init(color: Color(hex: 0xE9EBEE), location: 0.6), .init(color: Color(hex: 0xE2E4E8), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            Ellipse().fill(dark ? Color.white.opacity(0.06) : Color.white.opacity(0.85))
                .frame(width: 520 * sx, height: (dark ? 320 : 340) * sy)
                .blur(radius: dark ? 55 : 50)
                .position(x: 200 * sx, y: (dark ? 150 : 170) * sy)
            if !dark {
                Ellipse().fill(Color(hex: 0xC9CED8).opacity(0.30))
                    .frame(width: 440 * sx, height: 220 * sy)
                    .blur(radius: 50)
                    .position(x: 120 * sx, y: 720 * sy)
            }
        }
        .drawingGroup()
    }

    private func window(_ size: CGSize) -> some View {
        let sx = size.width / 390, sy = size.height / 844
        func beam(_ x: CGFloat, _ width: CGFloat, leaning: CGFloat) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: x * sx, y: -40 * sy))
            path.addLine(to: CGPoint(x: (x + width) * sx, y: -40 * sy))
            path.addLine(to: CGPoint(x: (x + width + leaning) * sx, y: 884 * sy))
            path.addLine(to: CGPoint(x: (x + leaning) * sx, y: 884 * sy))
            path.closeSubpath()
            return path
        }
        return ZStack {
            LinearGradient(colors: dark ? [Color(hex: 0x15161B), Color(hex: 0x0B0B0E)] : [Color(hex: 0xF4F2EE), Color(hex: 0xE9E7E3)],
                           startPoint: .top, endPoint: .bottom)
            if dark {
                ForEach(Array([(520.0, 70.0, 0.10), (410.0, 36.0, 0.07), (330.0, 80.0, 0.09)].enumerated()), id: \.offset) { _, b in
                    beam(b.0, b.1, leaning: -520).fill(Color(hex: 0xB9C8FF).opacity(b.2)).blur(radius: 26)
                }
            } else {
                RadialGradient(colors: [Color(hex: 0xFFE9CF).opacity(0.55), Color(hex: 0xFFE9CF).opacity(0)],
                               center: UnitPoint(x: 0.05, y: 0.02), startRadius: 0, endRadius: size.height * 0.62)
                beam(-60, 30, leaning: 520).fill(Color(hex: 0xB8B2A8).opacity(0.10)).blur(radius: 22)
                ForEach(Array([(-160.0, 70.0, 0.75), (-40.0, 38.0, 0.6), (40.0, 90.0, 0.7), (190.0, 30.0, 0.45)].enumerated()), id: \.offset) { _, b in
                    beam(b.0, b.1, leaning: 520).fill(Color.white.opacity(b.2)).blur(radius: 22)
                }
            }
        }
        .drawingGroup()
    }
}

/// A small tile of fine noise, made once.
enum GrainTexture {
    static let image: UIImage = {
        let noise = CIFilter.randomGenerator().outputImage ?? CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
        let gray = noise.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.1])
            .cropped(to: CGRect(x: 0, y: 0, width: 160, height: 160))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = context.createCGImage(gray, from: gray.extent) else { return UIImage() }
        return UIImage(cgImage: cg)
    }()
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Glass cards

extension View {
    /// Thin, clear glass: the page's light shows through it; a bright edge along the top keeps it readable.
    func glassCard(radius: CGFloat = 26) -> some View {
        modifier(GlassCardStyle(radius: radius))
    }
}

private struct GlassCardStyle: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = scheme == .dark
        content
            .background(ButlerSurface.card, in: shape)
            .overlay(shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(dark ? 0.20 : 0.95), .white.opacity(dark ? 0.06 : 0.30)],
                               startPoint: .top, endPoint: .bottom), lineWidth: 0.6))
            .shadow(color: ButlerSurface.shadow, radius: 14, y: 6)
    }
}

enum ButlerSurface {
    static let card = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.06) : UIColor(white: 1, alpha: 0.34)
    })
    static let cardEdge = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.16) : UIColor(white: 1, alpha: 0.75)
    })
    static let shadow = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.25) : UIColor(red: 0.16, green: 0.14, blue: 0.36, alpha: 0.06)
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

extension View {
    /// List rows drawn as the same thin glass as the cards, so settings pages match the rest of the app.
    func glassRows() -> some View { listRowBackground(ButlerSurface.card) }

    /// A system list or form on the page's own ground instead of opaque grey and white.
    func glassList() -> some View {
        scrollContentBackground(.hidden).background { ButlerBackground() }
    }
}
