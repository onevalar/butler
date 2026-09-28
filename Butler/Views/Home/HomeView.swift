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
    let onOpenOverview: () -> Void
    let onOpenButler: () -> Void
    var onOpenTasks: (() -> Void)? = nil
    let brief: DailyBrief

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BriefCard(brief: brief)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                WeekStrip(agenda: agenda, selected: $selectedDay)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
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
        .orbScrollTracking()
        .background { ButlerBackground() }
        .toolbar(.hidden, for: .navigationBar)
        // Date and the three entries share one pinned row; content scrolls under it.
        .safeAreaBar(edge: .top) { header }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            title
            Spacer(minLength: 8)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 0) {
                    if let onOpenTasks {
                        Button(action: onOpenTasks) { Image(systemName: "checklist").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44) }
                            .accessibilityLabel("任务与历史")
                    }
                    Button(action: onOpenOverview) {
                        Image(systemName: "calendar").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("日程总览")
                    Button(action: onOpenInventory) {
                        Image(systemName: "cabinet").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("家里")
                    Button(action: onOpenButler) {
                        Image(systemName: "gearshape").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("管家与设置")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 3)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private var isEmpty: Bool {
        agenda.needsAttention.isEmpty && agenda.missingInfoCount == 0 && agenda.days.allSatisfy { agenda.entries(on: $0).isEmpty }
    }

    // MARK: Title

    private var title: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "zh_CN"))))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(Date.now.monthDay)
                .font(.title.bold())
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
        let calendar = Calendar.current
        let now = Date.now
        let isToday = calendar.isDateInToday(selectedDay)
        let completed = agenda.completed(on: selectedDay)
        let pending = isToday ? agenda.pending(on: selectedDay, at: now) : []
        let items = dayEntries.filter { !$0.isCompleted && (!isToday || !$0.isPending(at: now)) }.map(\.timelineItem)
        // Only what is still ahead earns an hour grid; an empty grid just takes space.
        let ahead = dayEntries.filter { entry in
            guard !entry.isAllDay, !entry.isCompleted, !isToday || !entry.isPending(at: now) else { return false }
            return !isToday || (entry.end ?? entry.start ?? now) > now
        }
        let anchor: Int? = ahead.first?.start.map { start in
            let next = calendar.component(.hour, from: start)
            let hour = calendar.component(.hour, from: now)
            // Keep the now line when the next thing is close; otherwise start at the next thing.
            return isToday && next - hour <= 2 ? hour : next
        }
        let window = CompactTimelineView.window(items: items, day: selectedDay, visibleHours: 3, anchorHour: anchor)
        let later = ahead.filter { ($0.start.map { calendar.component(.hour, from: $0) } ?? 0) > window.upperBound }
        let allDay = items.filter(\.isAllDay)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionTitle("\(selectedDay.relativeDayName)的安排")
                Spacer()
                Button("全天") { onOpenDay(selectedDay) }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .padding(.bottom, 8)
            }
            GroupCard {
                if !pending.isEmpty {
                    Text("已到时间 · 待完成")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.top, 12)
                    ForEach(pending) { entry in
                        AgendaRow(entry: entry, accessory: .action("查看"),
                                  leading: entry.isAllDay ? .bar : .time(entry)) { onOpen(entry.target) }
                    }
                    if !allDay.isEmpty || !ahead.isEmpty { RowDivider(inset: 0) }
                }
                if !allDay.isEmpty {
                    TimelineAllDaySection(items: allDay, onTap: tap)
                        .padding(.top, 16).padding(.trailing, 16).padding(.leading, 8)
                        .padding(.bottom, ahead.isEmpty ? 14 : 4)
                    if !ahead.isEmpty { RowDivider(inset: 0) }
                }
                if !ahead.isEmpty {
                    CompactTimelineView(items: items, day: selectedDay, visibleHours: 3, anchorHour: anchor, onTap: tap)
                        .padding(.top, 20).padding(.leading, 8).padding(.trailing, 12).padding(.bottom, later.isEmpty ? 8 : 0)
                } else if allDay.isEmpty && pending.isEmpty && completed.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                        Text(isToday ? "今天接下来没有定时安排" : "这天没有安排")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                }
                if !completed.isEmpty {
                    if !pending.isEmpty || !allDay.isEmpty || !ahead.isEmpty { RowDivider(inset: 0) }
                    Text("已完成 · \(completed.count) 件")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.top, 12)
                    ForEach(completed) { entry in
                        AgendaRow(entry: entry, leading: .time(entry)) { onOpen(entry.target) }
                    }
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
        .glassCard()
    }
}

/// The butler's few sentences about today, with what they're based on.
struct BriefCard: View {
    var onOpenTasks: (() -> Void)? = nil
    let brief: DailyBrief

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(brief.greeting).font(.headline)
                Spacer()
                Text(brief.isEvening ? "晚间简报" : "今日简报").font(.caption).foregroundStyle(.secondary)
            }
            Text(brief.text).font(.body).fixedSize(horizontal: false, vertical: true)
            Text(brief.basis).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .combine)
    }
}

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
                        Text(entry.start?.clockTime ?? "全天").font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                    .frame(width: 44, alignment: .leading)
                }
                if case .time(let entry) = leading {
                    Text(entry.start?.clockTime ?? "全天")
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
