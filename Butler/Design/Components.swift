import SwiftUI

// MARK: - Seal

enum SealStyle {
    /// `paper` is the quiet seal placed on a tinted surface (it takes the page color instead).
    case urgent, solid, outline, quiet, missing, paper

    init(tier: UrgencyTier) {
        switch tier {
        case .overdue, .today: self = .urgent
        case .soon: self = .solid
        case .week: self = .outline
        case .calm: self = .quiet
        case .undated: self = .missing
        }
    }
}

/// A single serif character stamped in a rounded square: the identity of an item.
struct SealView: View {
    let glyph: Character
    var style: SealStyle = .quiet
    var size: CGFloat = 44
    var tilt: Double = 0

    var body: some View {
        let radius = size * 0.24
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Text(String(glyph))
            .font(Theme.display(size * 0.46))
            .foregroundStyle(glyphColor)
            .frame(width: size, height: size)
            .background(shape.fill(fill))
            .overlay {
                switch style {
                case .outline: shape.strokeBorder(Theme.cobalt, lineWidth: max(1.5, size / 30))
                case .missing: shape.strokeBorder(Theme.cobalt, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                default: EmptyView()
                }
            }
            .rotationEffect(.degrees(tilt))
            .accessibilityHidden(true)
    }

    private var fill: Color {
        switch style {
        case .urgent: Theme.vermilionFill
        case .solid: Theme.cobaltFill
        case .quiet: Theme.surface
        case .outline, .missing, .paper: Theme.ground
        }
    }

    private var glyphColor: Color {
        switch style {
        case .urgent, .solid: .white
        default: Theme.cobalt
        }
    }
}

// MARK: - Text helpers

/// Small letter-spaced section label.
struct Eyebrow: View {
    let text: String
    var color: Color = Theme.ink

    init(_ text: String, color: Color = Theme.ink) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(Theme.eyebrow)
            .tracking(Theme.eyebrowTracking)
            .foregroundStyle(color)
    }
}

/// Values Butler inferred get a dashed cobalt underline: "点一下可改".
struct InferredText: View {
    let text: String
    var inferred: Bool
    var font: Font = Theme.body(13)

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(inferred ? Theme.cobalt : Theme.ink)
            .padding(.bottom, inferred ? 2 : 0)
            .overlay(alignment: .bottom) {
                if inferred {
                    Line()
                        .stroke(Theme.cobalt, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .frame(height: 1.5)
                }
            }
    }
}

struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

// MARK: - Buttons

struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, capsule, outlineDanger, quiet }
    var kind: Kind = .primary
    var height: CGFloat = 56
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.display(17, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .foregroundStyle(foreground)
            .background(Capsule().fill(background))
            .overlay {
                if kind == .outlineDanger {
                    Capsule().strokeBorder(Theme.vermilion.opacity(0.35), lineWidth: 1.5)
                }
            }
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .capsule: Theme.ground
        case .outlineDanger: Theme.vermilion
        case .quiet: Theme.ink
        }
    }

    private var background: Color {
        switch kind {
        case .primary: Theme.cobaltFill
        case .capsule: Theme.capsule
        case .outlineDanger: .clear
        case .quiet: Theme.surface
        }
    }
}

struct ChoiceChip: View {
    let title: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.body(13, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.cobalt : Theme.inkSoft)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .overlay(Capsule().strokeBorder(selected ? Theme.cobalt : Theme.dashed, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dock

/// The always-present bottom bar: shelf on the left, "说给管家听" capsule on the right.
struct Dock: View {
    var onShelf: (() -> Void)?
    let onSpeak: () -> Void
    var onCapture: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let onShelf {
                Button(action: onShelf) {
                    Image(systemName: "refrigerator")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Theme.surface))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("家里的东西")
            }
            Button(action: onSpeak) {
                HStack(spacing: 10) {
                    Text("说给管家听…")
                        .font(Theme.display(16, weight: .regular))
                        .foregroundStyle(Theme.capsuleText)
                    Spacer(minLength: 0)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Theme.cobaltFill))
                }
                .padding(.leading, 20)
                .padding(.trailing, 6)
                .frame(height: 56)
                .background(Capsule().fill(Theme.capsule))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("和管家聊聊")
            if let onCapture {
                Button(action: onCapture) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Theme.surface))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("拍照或快速记一笔")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 8)
        .background(alignment: .top) {
            LinearGradient(colors: [Theme.ground.opacity(0), Theme.ground], startPoint: .top, endPoint: .init(x: 0.5, y: 0.4))
                .ignoresSafeArea()
        }
    }
}
