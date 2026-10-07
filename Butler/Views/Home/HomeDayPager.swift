import SwiftUI

enum HomeDayNavigationStyle: Equatable { case slide, fade }

/// Three locally rendered days share one drag position. There is no removal/insertion transition
/// whose direction could be inherited from the preceding swipe.
struct HomeDayPager<Content: View>: View {
    @Binding var day: Date
    let interaction: HomeDayInteraction
    let isActive: Bool
    let navigationStyle: HomeDayNavigationStyle
    @ViewBuilder let content: (Date) -> Content

    @State private var displayedDay: Date
    @State private var width: CGFloat = 0
    @State private var heights: [Date: CGFloat] = [:]
    @State private var destination: Date?
    @State private var settlementStyle: HomeDayNavigationStyle = .slide
    @State private var fadeProgress: CGFloat = 0
    @State private var revision = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let calendar = Calendar.current

    init(day: Binding<Date>, interaction: HomeDayInteraction, isActive: Bool,
         navigationStyle: HomeDayNavigationStyle, @ViewBuilder content: @escaping (Date) -> Content) {
        _day = day; self.interaction = interaction; self.isActive = isActive
        self.navigationStyle = navigationStyle; self.content = content
        _displayedDay = State(initialValue: day.wrappedValue)
    }

    private var pages: [Date] {
        if let destination { return [displayedDay, destination] }
        // A month-calendar jump may be outside the three cached days. Measure its content
        // as soon as the binding changes, before the selection's onChange starts settling.
        if day != displayedDay { return [displayedDay, day] }
        return [-1, 0, 1].compactMap { calendar.date(byAdding: .day, value: $0, to: displayedDay) }
    }

    private var pageHeight: CGFloat {
        let current = heights[displayedDay] ?? 110
        if let destination {
            let progress = settlementStyle == .fade ? fadeProgress : min(1, abs(interaction.offset) / max(1, width))
            return current + ((heights[destination] ?? current) - current) * progress
        }
        guard !reduceMotion, width > 0, interaction.offset != 0,
              let adjacent = calendar.date(byAdding: .day, value: interaction.offset < 0 ? 1 : -1, to: displayedDay) else {
            return current
        }
        let progress = min(1, abs(interaction.offset) / width)
        return current + ((heights[adjacent] ?? current) - current) * progress
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(pages, id: \.self) { date in
                content(date)
                    // Leave room for the existing glass shadow inside the clipped paging viewport.
                    .padding(.vertical, 6)
                    .frame(width: width > 0 ? width : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        guard abs((heights[date] ?? 0) - height) > 0.5 else { return }
                        if interaction.isSettling {
                            withAnimation(.smooth(duration: 0.18)) { heights[date] = height }
                        } else {
                            heights[date] = height
                        }
                    }
                    .offset(x: pageOffset(date))
                    .opacity(pageOpacity(date))
                    .allowsHitTesting(date == displayedDay && !interaction.isSettling)
                    .accessibilityHidden(date != displayedDay)
            }
        }
        .frame(height: pageHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { value in
            if abs(width - value) > 0.5 {
                // Rotation or a split view cannot leave a half-finished page using the old width.
                reset()
                width = value
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .gesture(HomeDaySwipe(interaction: interaction, day: displayedDay, width: width,
                              isEnabled: isActive, onEnd: finishSwipe))
        .allowsHitTesting(isActive)
        .onChange(of: day) { _, newDay in
            guard newDay != displayedDay else { return }
            settle(to: newDay, style: navigationStyle)
        }
        .onChange(of: isActive) { if !isActive { reset() } }
        .onDisappear { reset() }
    }

    private func pageOffset(_ date: Date) -> CGFloat {
        if reduceMotion || (destination != nil && settlementStyle == .fade) { return 0 }
        let resting: CGFloat
        if let destination {
            resting = date == displayedDay ? 0 : (destination > displayedDay ? width : -width)
        } else {
            resting = CGFloat(calendar.dateComponents([.day], from: displayedDay, to: date).day ?? 0) * width
        }
        return resting + interaction.offset
    }

    private func pageOpacity(_ date: Date) -> Double {
        if destination != nil && settlementStyle == .fade {
            return Double(date == displayedDay ? 1 - fadeProgress : fadeProgress)
        }
        if reduceMotion { return date == displayedDay ? 1 : 0 }
        return 1
    }

    private func finishSwipe(_ target: Date?) {
        guard !interaction.isSettling else { return }
        guard target != nil || interaction.offset != 0 else { return }
        settle(to: target, style: .slide)
    }

    private func settle(to target: Date?, style: HomeDayNavigationStyle) {
        guard isActive else { reset(); return }
        revision += 1
        let currentRevision = revision
        destination = target
        settlementStyle = reduceMotion ? .fade : style
        fadeProgress = 0
        interaction.beginSettlement()
        let endOffset: CGFloat = target.map { $0 > displayedDay ? -width : width } ?? 0
        withAnimation(.smooth(duration: settlementStyle == .fade ? 0.18 : 0.24), completionCriteria: .removed) {
            if settlementStyle == .fade {
                interaction.settle(at: 0)
                fadeProgress = target == nil ? 0 : 1
            } else {
                interaction.settle(at: endOffset)
            }
        } completion: {
            guard revision == currentRevision, isActive else { return }
            // Recenter the same dates together, without animating another jump at the page boundary.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if let target {
                    displayedDay = target
                    day = target
                }
                destination = nil
                fadeProgress = 0
                interaction.completeSettlement()
                heights = heights.filter { pages.contains($0.key) }
            }
        }
    }

    private func reset() {
        revision += 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayedDay = day
            destination = nil
            fadeProgress = 0
            interaction.cancel()
        }
    }
}
