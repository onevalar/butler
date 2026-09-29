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

/// Home: the butler's one sentence, the day's list, and two quiet lines.
struct HomeView: View {
    let agenda: HomeAgenda
    let facts: [LotFacts]
    @Binding var selectedDay: Date
    let now: Date
    let brief: ButlerBrief
    let briefBusy: Bool
    let pendingTaskCount: Int
    let onOpen: (AgendaEntry.Target) -> Void
    let onOpenInventory: () -> Void
    let onOpenOverview: () -> Void
    let onOpenUpcoming: () -> Void
    let onOpenButler: () -> Void
    let onOpenTasks: () -> Void
    let onBriefAction: (BriefAction, BriefTarget) -> Void
    let onBriefOther: (BriefTarget) -> Void

    @State private var showingPicker = false
    @State private var expanded = false
    @State private var completedShown = false
    @State private var slideForward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var calendar: Calendar { .current }
    private var isToday: Bool { selectedDay == agenda.today }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !brief.text.isEmpty {
                    BriefCard(brief: brief, busy: briefBusy, onAction: onBriefAction, onOther: onBriefOther)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
                dayList
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                quietLinks
                    .padding(.horizontal, 20)
            }
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .orbScrollTracking()
        .background { ButlerBackground() }
        .toolbar(.hidden, for: .navigationBar)
        // The date and the entries share one pinned row; content scrolls under it.
        .safeAreaBar(edge: .top) { header }
        .overlay(alignment: .topLeading) {
            if showingPicker {
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.14).ignoresSafeArea()
                        .onTapGesture { closePicker() }
                    DayPickerPanel(agenda: agenda, selected: selectedDay, pendingTaskCount: pendingTaskCount,
                                   onPick: { day in
                                       selectedDay = day
                                       expanded = false
                                       closePicker()
                                   },
                                   onOverview: { closePicker(); onOpenOverview() },
                                   onTasks: { closePicker(); onOpenTasks() })
                        .padding(.leading, 16).padding(.top, 62)
                        .transition(.scale(scale: 0.9, anchor: .topLeading).combined(with: .opacity))
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82), value: showingPicker)
        .sensoryFeedback(.selection, trigger: selectedDay)
    }

    private func closePicker() { showingPicker = false }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            dateCapsule
            Spacer(minLength: 8)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 0) {
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
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    /// "今天 · 9月28日 周一 ⌄": tap to pick another day; on another day it reads "9月30日 周三 ×" and × comes back.
    private var dateCapsule: some View {
        HStack(spacing: 6) {
            Button { showingPicker.toggle() } label: {
                HStack(spacing: 8) {
                    Text(Self.label(for: selectedDay, today: agenda.today, calendar: calendar))
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    if isToday { Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择日期，现在是\(Self.label(for: selectedDay, today: agenda.today, calendar: calendar))")
            if !isToday {
                Button {
                    slideForward = false
                    withAnimation(reduceMotion ? nil : .snappy) { selectedDay = agenda.today; expanded = false }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("回到今天")
            }
        }
        .padding(.leading, 18).padding(.trailing, isToday ? 16 : 8)
        .frame(height: 44)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    static func label(for day: Date, today: Date, calendar: Calendar = .current) -> String {
        let weekday = day.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "zh_CN")))
        let offset = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        switch offset {
        case 0: return "今天 · \(day.monthDay) \(weekday)"
        case 1: return "明天 · \(day.monthDay) \(weekday)"
        default: return "\(day.monthDay) \(weekday)"
        }
    }

    // MARK: The day's list

    private static let collapsedCount = 4

    private var dayList: some View {
        let list = HomeList.build(day: selectedDay, agenda: agenda, facts: facts,
                                  featured: isToday ? brief.target?.agendaTarget : nil, now: now)
        let visible = expanded ? list.rows : Array(list.rows.prefix(Self.collapsedCount))
        let hidden = list.rows.count - visible.count
        return VStack(spacing: 0) {
            if list.rows.isEmpty && list.completed.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    Text(isToday ? (brief.target == nil ? "今天没有别的安排" : "除了上面这件，今天没有别的安排") : "这天没有安排")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 18).frame(minHeight: 56)
            }
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                if index > 0 { rowDivider }
                HomeRowView(row: row, onOpen: onOpen)
            }
            if hidden > 0 {
                rowDivider
                Button {
                    withAnimation(reduceMotion ? nil : .snappy) { expanded = true }
                } label: {
                    HStack(spacing: 6) {
                        Text("还有 \(hidden) 件，展开").font(.subheadline).foregroundStyle(.secondary)
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 78).padding(.vertical, 13).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !list.completed.isEmpty {
                if !list.rows.isEmpty { rowDivider }
                Button {
                    withAnimation(reduceMotion ? nil : .snappy) { completedShown.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Text("已完成 \(list.completed.count) 件").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: completedShown ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 13).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if completedShown {
                    ForEach(list.completed) { row in
                        rowDivider
                        HomeRowView(row: row, onOpen: onOpen)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .glassCard()
        .id(selectedDay)
        .transition(reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: slideForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: slideForward ? .leading : .trailing).combined(with: .opacity)))
        // Swipe the list sideways for the next or the previous day.
        .simultaneousGesture(DragGesture(minimumDistance: 28).onEnded { value in
            let dx = value.translation.width, dy = value.translation.height
            guard abs(dx) > 70, abs(dx) > abs(dy) * 1.6 else { return }
            step(dx < 0 ? 1 : -1)
        })
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 78).padding(.trailing, 16)
    }

    private func step(_ direction: Int) {
        guard let next = calendar.date(byAdding: .day, value: direction, to: selectedDay), next >= agenda.today,
              let last = agenda.days.last, next <= last else { return }
        slideForward = direction > 0
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.32)) { selectedDay = next; expanded = false }
    }

    // MARK: Two quiet lines

    private var quietLinks: some View {
        VStack(spacing: 0) {
            if let week = HomeList.weekAhead(agenda: agenda) {
                quietRow("这周还有 \(week.count) 件", week.preview, action: onOpenUpcoming)
                Divider().padding(.horizontal, 6)
            }
            quietRow(facts.isEmpty ? "家里还没有东西" : "家里 \(facts.count) 样",
                     facts.isEmpty ? "买了什么，跟管家说一句" : HomeList.places(facts: facts), action: onOpenInventory)
        }
    }

    private func quietRow(_ title: String, _ subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).foregroundStyle(.primary)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One line of the day list.
struct HomeRowView: View {
    let row: HomeListRow
    let onOpen: (AgendaEntry.Target) -> Void

    var body: some View {
        Button { onOpen(row.target) } label: {
            HStack(spacing: 14) {
                Text(row.lead)
                    .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(row.isCompleted ? .secondary : .primary)
                    .frame(width: 48, alignment: .leading)
                if row.isCompleted {
                    Image(systemName: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).frame(width: 6)
                } else {
                    KindBar(color: row.kind.color, height: 34)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).font(.body)
                        .strikethrough(row.isCompleted)
                        .foregroundStyle(row.isCompleted ? Color.secondary : Color.primary).lineLimit(1)
                    if let subtitle = row.subtitle {
                        Text(subtitle).font(.subheadline)
                            .foregroundStyle(row.isAlert ? Color.red : .secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let action = row.action { CapsuleLabel(action) }
            }
            .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 9)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The butler's one sentence. The buttons are what the model judged fit this particular thing; the last one,
/// 其他…, opens a conversation about just this thing, for anything the buttons don't cover.
struct BriefCard: View {
    let brief: ButlerBrief
    let busy: Bool
    let onAction: (BriefAction, BriefTarget) -> Void
    let onOther: (BriefTarget) -> Void
    @Environment(\.butlerAccent) private var accent

    /// The first button is solid in the brand colour; the rest are clear glass.
    @ViewBuilder
    private func briefButtonLabel(_ label: String, primary: Bool) -> some View {
        let text = Text(label).font(.system(size: 15, weight: .semibold)).padding(.horizontal, 16).frame(height: 36)
        if primary {
            text.foregroundStyle(accent.onFill).background(accent.fill, in: Capsule())
        } else {
            text.foregroundStyle(Color.primary).glassEffect(.regular.interactive(), in: .capsule)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(brief.greeting).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                if busy { ProgressView().controlSize(.mini) }
            }
            Text(brief.text)
                .font(.system(size: 22, weight: .semibold))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if let target = brief.target {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(Array(brief.actions.enumerated()), id: \.element.id) { index, action in
                        Button { onAction(action, target) } label: {
                            briefButtonLabel(action.label, primary: index == 0)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                    Button { onOther(target) } label: {
                        HStack(spacing: 5) {
                            Text("其他…").font(.system(size: 15, weight: .semibold))
                            Image(systemName: "mic").font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.horizontal, 14).frame(height: 36).foregroundStyle(Color.primary)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("其他安排，打字或说给管家听")
                }
                .opacity(busy ? 0.45 : 1)
            }
            Text(brief.basis).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .animation(.easeInOut(duration: 0.25), value: brief.text)
    }
}

/// Buttons flow onto the next line instead of squeezing.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
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

/// The panel under the date capsule: a month with dots on days that have something, and two doors to the rest.
struct DayPickerPanel: View {
    let agenda: HomeAgenda
    let selected: Date
    let pendingTaskCount: Int
    let onPick: (Date) -> Void
    let onOverview: () -> Void
    let onTasks: () -> Void

    @State private var monthOffset = 0
    private var calendar: Calendar { .current }

    private var month: Date {
        let start = calendar.dateInterval(of: .month, for: agenda.today)?.start ?? agenda.today
        return calendar.date(byAdding: .month, value: monthOffset, to: start) ?? start
    }

    private var cells: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let leading = (calendar.component(.weekday, from: month) + 5) % 7   // Monday first
        let days = range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
        return Array(repeating: nil, count: leading) + days
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(month.formatted(.dateTime.year().month(.wide).locale(Locale(identifier: "zh_CN")))).font(.headline)
                Spacer()
                HStack(spacing: 6) {
                    Button { monthOffset -= 1 } label: { Image(systemName: "chevron.left").frame(width: 34, height: 34) }
                        .disabled(monthOffset <= 0).accessibilityLabel("上个月")
                    Button { monthOffset += 1 } label: { Image(systemName: "chevron.right").frame(width: 34, height: 34) }
                        .disabled(monthOffset >= 11).accessibilityLabel("下个月")
                }
                .font(.system(size: 15, weight: .semibold)).buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            HStack(spacing: 0) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) {
                    Text($0).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day { cell(day) } else { Color.clear.frame(height: 42) }
                }
            }
            Divider().padding(.top, 2)
            door("日程总览", detail: "月 · 年 · 列表", systemImage: "calendar", action: onOverview)
            door("任务与历史", detail: pendingTaskCount > 0 ? "\(pendingTaskCount) 件待完成" : nil,
                 systemImage: "checklist", action: onTasks)
        }
        .padding(14)
        .frame(width: 330)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 24, y: 12)
    }

    private func cell(_ day: Date) -> some View {
        let isToday = day == agenda.today
        let isPast = day < agenda.today
        let isSelected = calendar.isDate(day, inSameDayAs: selected)
        let dots = isPast ? [] : Array(agenda.dots(on: day).prefix(3))
        return Button { onPick(day) } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 16, weight: isToday || isSelected ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(isSelected ? Color(.systemBackground) : isToday ? Color.red : isPast ? Color(.tertiaryLabel) : Color.primary)
                    .frame(width: 32, height: 32)
                    .background { if isSelected { Circle().fill(Color.primary) } }
                HStack(spacing: 2) {
                    ForEach(dots, id: \.self) { Circle().fill($0.color).frame(width: 4, height: 4) }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPast)
        .accessibilityLabel(day.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_CN")))
                            + (dots.isEmpty ? "" : "，有安排"))
    }

    private func door(_ title: String, detail: String?, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.system(size: 16, weight: .medium)).frame(width: 24)
                Text(title).font(.body)
                Spacer()
                if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
