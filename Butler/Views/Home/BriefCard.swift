import SwiftUI

/// Quick actions apply to their target; the last button “其他” discusses the entire visible reminder.
struct BriefCard: View {
    let brief: ButlerBrief
    let busy: Bool
    let onAction: (BriefAction, BriefTarget) -> Void
    let onOther: (ButlerBrief) -> Void
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
            HStack(spacing: 8) {
                WeatherGreeting(greeting: brief.greeting)
                if busy { Text("小当家正在更新…").font(.caption).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) }
                Spacer(minLength: 8)
            }
            Text(brief.text)
                .font(.system(size: 17, weight: .medium))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            // A quiet day (nothing to raise) has no buttons at all, not even 其他.
            if brief.target != nil || brief.hasSubject == true {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    if let target = brief.target {
                        ForEach(Array(brief.actions.enumerated()), id: \.element.id) { index, action in
                            Button { onAction(action, target) } label: {
                                briefButtonLabel(action.label, primary: index == 0)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // Last in the row, same shape as the rest: none of these fit, talk it through.
                    Button { onOther(brief) } label: {
                        briefButtonLabel("其他", primary: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("其他")
                    .accessibilityHint("讨论当前整张管家提醒，包含其中提到的所有事情")
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in onInteraction() })
        .animation(.easeInOut(duration: 0.25), value: brief.text)
    }
}

/// Buttons flow onto the next line instead of squeezing.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let arranged = arrange(width: width, subviews: subviews)
        // Take the whole width offered, so the text above it isn't squeezed to the width of the buttons.
        return CGSize(width: width.isFinite ? width : arranged.size.width, height: arranged.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arranged = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in arranged.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += lineHeight + lineSpacing; lineHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + lineHeight), origins)
    }
}
