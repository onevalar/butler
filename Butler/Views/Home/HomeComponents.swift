import SwiftUI

extension AgendaEntry {
    var timelineItem: TimelineItem {
        TimelineItem(id: id, title: title, subtitle: subtitle, startDate: start ?? day,
                     endDate: end ?? day, isAllDay: isAllDay, color: kind.color, isCompleted: isCompleted)
    }
}

// MARK: - Pieces shared by home and the day view

/// White card with the concentric Liquid Glass-era radius.
struct GroupCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.vertical, 4)
            .glassCard()
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.title3.bold()).foregroundStyle(.primary)
            .padding(.horizontal, 6).padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

struct KindBar: View {
    let color: Color
    var height: CGFloat = 36
    var width: CGFloat = 6
    var body: some View {
        RoundedRectangle(cornerRadius: width / 2).fill(color).frame(width: width, height: height)
    }
}

struct RowDivider: View {
    let inset: CGFloat
    var body: some View {
        Divider().padding(.leading, inset).padding(.trailing, inset > 0 ? 16 : 0)
    }
}

struct CapsuleLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }
}

struct AgendaRow: View {
    enum Accessory { case none, action(String) }
    enum Leading { case bar, day(AgendaEntry), time(AgendaEntry) }

    let entry: AgendaEntry
    var accessory: Accessory = .none
    var leading: Leading = .bar
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if case .day(let entry) = leading {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.day.relativeDayName).font(.caption).foregroundStyle(.secondary)
                        Text(entry.timeLabel).font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                    .frame(width: 44, alignment: .leading)
                }
                if case .time(let entry) = leading {
                    Text(entry.timeLabel)
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .frame(width: 44, alignment: .leading)
                }
                if entry.isCompleted {
                    Image(systemName: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                } else { KindBar(color: entry.kind.color) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(.body)
                        .strikethrough(entry.isCompleted)
                        .foregroundStyle(entry.isCompleted ? .secondary : .primary).lineLimit(1)
                    if let subtitle = entry.subtitle {
                        Text(subtitle).font(.subheadline)
                            .foregroundStyle(entry.kind == .expired ? Color.red : .secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if case .action(let title) = accessory { CapsuleLabel(title) }
            }
            .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 10)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Seven days from today. Today is red; the selected day is a filled capsule.
struct WeekStrip: View {
    let agenda: HomeAgenda
    @Binding var selected: Date
    /// Defaults to the agenda's first seven days (home); the day view passes the week it shows.
    var days: [Date]? = nil
    @Environment(\.butlerAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days ?? Array(agenda.days.prefix(7)), id: \.self) { day in
                let isSelected = day == selected
                let isToday = day == agenda.today
                let fill: Color = isSelected ? accent.fill : .clear
                Button {
                    withAnimation(reduceMotion ? nil : .snappy) { selected = day }
                } label: {
                    VStack(spacing: 3) {
                        Text(day.formatted(.dateTime.weekday(.narrow).locale(Locale(identifier: "zh_CN"))))
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                        Text(day.formatted(.dateTime.day()))
                            .font(.title3.weight(isSelected || isToday ? .semibold : .regular))
                            .monospacedDigit()
                        HStack(spacing: 3) {
                            ForEach(agenda.dots(on: day), id: \.self) { kind in
                                Circle().fill(isSelected ? accent.onFill : kind.color).frame(width: 5, height: 5)
                            }
                        }
                        .frame(height: 5)
                    }
                    .foregroundStyle(isSelected ? accent.onFill : (isToday ? .red : .primary))
                    .frame(width: 46)
                    .padding(.vertical, 8)
                    .background(fill, in: Capsule())
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(day.relativeDayName) \(day.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN"))))")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
    }
}

/// A 40pt glass circle that stays inside a 52pt capsule (the system glass button styles add padding).
struct GlassCircleButton: View {
    let systemImage: String
    var tint: Color? = nil
    var glyph: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint == nil ? Color.primary : glyph)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(tint.map { Glass.regular.tint($0).interactive() } ?? Glass.regular.interactive(), in: .circle)
    }
}
