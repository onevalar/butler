import SwiftUI

extension AgendaEntry.Kind {
    var color: Color {
        switch self {
        case .expired: .red
        case .expiring: .orange
        case .lowStock: .gray
        case .reminder: .blue
        case .calendar: .green
        }
    }
}

extension Date {
    /// "今天", "明天", "周三".
    var relativeDayName: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "今天" }
        if calendar.isDateInTomorrow(self) { return "明天" }
        return formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "zh_CN")))
    }

    var clockTime: String {
        formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
}

/// Home: what needs handling now, the selected day's schedule on a timeline, and the rest of the week.
struct HomeView: View {
    let agenda: HomeAgenda
    @Binding var selectedDay: Date
    let onOpen: (AgendaEntry.Target) -> Void
    let onOpenDay: (Date) -> Void
    let onOpenInventory: () -> Void
    let onSettings: () -> Void
    let onChat: (ChatStart) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                title
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                WeekStrip(agenda: agenda, selected: $selectedDay)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                if isEmpty {
                    emptyState.padding(.horizontal, 16)
                } else {
                    if !agenda.needsAttention.isEmpty || agenda.missingInfoCount > 0 {
                        attention.padding(.horizontal, 16).padding(.bottom, 24)
                    }
                    schedule.padding(.horizontal, 16).padding(.bottom, 24)
                    upcoming.padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemGroupedBackground))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: onOpenInventory) { Image(systemName: "refrigerator") }
                    .accessibilityLabel("家里的东西")
                Button(action: onSettings) { Image(systemName: "gearshape") }
                    .accessibilityLabel("设置")
            }
        }
        .safeAreaBar(edge: .bottom) {
            HomeInputBar(onChat: onChat)
        }
    }

    private var isEmpty: Bool {
        agenda.needsAttention.isEmpty && agenda.missingInfoCount == 0 && agenda.days.allSatisfy { agenda.entries(on: $0).isEmpty }
    }

    // MARK: Title

    private var title: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Date.now.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_CN"))))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            Text("今天")
                .font(.largeTitle.bold())
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Needs attention

    private var attention: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle("需要处理")
            GroupCard {
                ForEach(Array(agenda.needsAttention.enumerated()), id: \.element.id) { index, entry in
                    AgendaRow(entry: entry, accessory: .action(entry.kind == .lowStock ? "补货" : "处理")) { onOpen(entry.target) }
                    if index < agenda.needsAttention.count - 1 || agenda.missingInfoCount > 0 {
                        RowDivider(inset: 36)
                    }
                }
                if agenda.missingInfoCount > 0 {
                    Button(action: onOpenInventory) {
                        HStack(spacing: 14) {
                            KindBar(color: .gray)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(agenda.missingInfoCount) 样东西还缺信息").font(.body).foregroundStyle(.primary)
                                Text("补上日期或位置，才能按时提醒").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            CapsuleLabel("补上")
                        }
                        .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 10)
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Selected day on a timeline

    private var dayEntries: [AgendaEntry] { agenda.entries(on: selectedDay) }

    private var schedule: some View {
        let items = dayEntries.map(\.timelineItem)
        let window = CompactTimelineView.window(items: items, day: selectedDay, visibleHours: 4)
        let calendar = Calendar.current
        let timed = dayEntries.filter { !$0.isAllDay }
        let later = timed.filter { ($0.start.map { calendar.component(.hour, from: $0) } ?? 0) > window.upperBound }
        let hasTimeline = Calendar.current.isDateInToday(selectedDay) || !timed.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionTitle("\(selectedDay.relativeDayName)的安排")
                Spacer()
                Button("全天") { onOpenDay(selectedDay) }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .fontWeight(.semibold)
                    .tint(.blue)
                    .padding(.bottom, 8)
            }
            GroupCard {
                let allDay = items.filter(\.isAllDay)
                if !allDay.isEmpty {
                    TimelineAllDaySection(items: allDay, onTap: tap)
                        .padding(.top, 16).padding(.trailing, 16).padding(.leading, 8)
                        .padding(.bottom, hasTimeline ? 4 : 14)
                    if hasTimeline { RowDivider(inset: 0) }
                }
                if hasTimeline {
                    CompactTimelineView(items: items, day: selectedDay, visibleHours: 4, onTap: tap)
                        .padding(.top, 20).padding(.leading, 8).padding(.trailing, 12).padding(.bottom, later.isEmpty ? 8 : 0)
                } else if allDay.isEmpty {
                    Text("这天没有安排")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                if !later.isEmpty {
                    RowDivider(inset: 0)
                    HStack(spacing: 8) {
                        KindBar(color: .blue, height: 16, width: 4)
                        Text("晚些时候 · " + later.map { "\($0.start?.clockTime ?? "") \($0.title)" }.joined(separator: "，"))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.leading, TimelineMetrics.labelWidth + 16).padding(.trailing, 16).padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func tap(_ item: TimelineItem) {
        if let entry = dayEntries.first(where: { $0.id == item.id }) { onOpen(entry.target) }
    }

    // MARK: Rest of the week

    @ViewBuilder
    private var upcoming: some View {
        let rows = agenda.upcoming(after: selectedDay)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle("接下来")
                GroupCard {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                        AgendaRow(entry: entry, accessory: .none, leading: .day(entry)) { onOpen(entry.target) }
                        if index < rows.count - 1 { RowDivider(inset: 92) }
                    }
                }
            }
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("这周还没有要管的事").font(.title3.weight(.semibold))
            Text("买了东西、想被提醒，直接跟管家说。比如“买了两盒草莓，放冷藏”“明天早上 8 点提醒我带伞”。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

extension AgendaEntry {
    var timelineItem: TimelineItem {
        TimelineItem(id: id, title: title, subtitle: subtitle, startDate: start ?? day,
                     endDate: end ?? day, isAllDay: isAllDay, color: kind.color)
    }
}

// MARK: - Pieces shared by home and the day view

/// White card with the concentric Liquid Glass-era radius.
struct GroupCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.vertical, 4)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
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
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.blue)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }
}

struct AgendaRow: View {
    enum Accessory { case none, action(String) }
    enum Leading { case bar, day(AgendaEntry) }

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
                        Text(entry.start?.clockTime ?? "全天").font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                    .frame(width: 44, alignment: .leading)
                }
                KindBar(color: entry.kind.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(.body).foregroundStyle(.primary).lineLimit(1)
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

    var body: some View {
        HStack(spacing: 0) {
            ForEach(agenda.days, id: \.self) { day in
                let isSelected = day == selected
                let isToday = day == agenda.today
                let fill: Color = isSelected ? (isToday ? .red : .primary) : .clear
                Button {
                    withAnimation(.snappy) { selected = day }
                } label: {
                    VStack(spacing: 3) {
                        Text(day.formatted(.dateTime.weekday(.narrow).locale(Locale(identifier: "zh_CN"))))
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                        Text(day.formatted(.dateTime.day()))
                            .font(.title3.weight(isSelected || isToday ? .semibold : .regular))
                            .monospacedDigit()
                        HStack(spacing: 3) {
                            ForEach(agenda.dots(on: day), id: \.self) { kind in
                                Circle().fill(isSelected ? Color(.systemBackground) : kind.color).frame(width: 5, height: 5)
                            }
                        }
                        .frame(height: 5)
                    }
                    .foregroundStyle(isSelected ? Color(.systemBackground) : (isToday ? .red : .primary))
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

/// Floating Liquid Glass input: camera island + capsule field with a prominent mic.
struct HomeInputBar: View {
    let onChat: (ChatStart) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button { onChat(.camera) } label: {
                    Image(systemName: "camera")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("拍照告诉管家")

                HStack(spacing: 0) {
                    Button { onChat(.typing) } label: {
                        Text("和管家说…")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .padding(.leading, 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("和管家聊聊")
                    Button { onChat(.voice) } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .tint(.blue)
                    .padding(.trailing, 6)
                    .accessibilityLabel("说给管家听")
                }
                .frame(height: 52)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}
