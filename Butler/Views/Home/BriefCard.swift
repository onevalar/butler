import SwiftUI

/// Only direct actions belong on the card; the orb handles replies and corrections.
struct BriefCard: View {
    let brief: ButlerBrief
    let busy: Bool
    let onAction: (BriefAction, BriefTarget) -> Void
    let onInteraction: () -> Void
    @Environment(\.butlerAccent) private var accent

    /// The first button is solid in the brand colour; the rest are clear glass.
    @ViewBuilder
    private func briefButtonLabel(_ label: String, primary: Bool) -> some View {
        let text = Text(label).font(.system(size: 15, weight: .semibold)).padding(.horizontal, 15).frame(height: 34)
        if primary {
            text.foregroundStyle(accent.onFill).background(accent.fill, in: Capsule())
        } else {
            text.foregroundStyle(Color.primary).glassEffect(.regular.interactive(), in: .capsule)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                WeatherGreeting(greeting: brief.greeting, brief: brief)
                Spacer(minLength: 8)
                if busy {
                    Text("正在更新…").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel("小当家正在更新提醒")
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            Text(brief.text)
                .font(.system(size: 17, weight: .medium))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let target = brief.target, !brief.quickActions.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { actionButtons(for: target) }.fixedSize(horizontal: true, vertical: false)
                    VStack(spacing: 8) { actionButtons(for: target) }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in onInteraction() })
        .animation(.easeInOut(duration: 0.25), value: brief.text)
    }

    private func actionButtons(for target: BriefTarget) -> some View {
        ForEach(Array(brief.quickActions.enumerated()), id: \.element.id) { index, action in
            Button { onAction(action, target) } label: {
                briefButtonLabel(action.label, primary: index == 0)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
