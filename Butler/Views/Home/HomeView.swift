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
        // No AM/PM marker fits beside the list. Keep the hour unambiguous in every region.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: self)
    }
}

/// Home: the butler's one sentence, the day's list, and two quiet lines.
struct HomeView: View {
    let agenda: HomeAgenda
    let facts: [LotFacts]
    @Binding var listDay: Date
    let isActive: Bool
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
    let onBriefOther: (ButlerBrief) -> Void
    let onBriefInteraction: () -> Void
    let onBrowseMonth: (Date) -> Void

    @State private var showingPicker = false
    @State private var slideForward = true
    @State private var listInteraction = HomeDayInteraction()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var calendar: Calendar { .current }
    private var isToday: Bool { listDay == agenda.today }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !brief.text.isEmpty {
                    BriefCard(brief: brief, busy: briefBusy, onAction: onBriefAction, onOther: onBriefOther, onInteraction: onBriefInteraction)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
                VStack(spacing: 0) {
                    HStack {
                        Text(isToday ? "今天的清单" : Self.label(for: listDay, today: agenda.today))
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        if !isToday {
                            Button("回到今天") {
                                if listInteraction.allowsTap { selectDay(agenda.today) }
                            }
                                .font(.subheadline).buttonStyle(.plain)
                                .accessibilityAction { selectDay(agenda.today) }
                        }
                    }
                    .frame(minHeight: 36)
                    .padding(.horizontal, 22).padding(.bottom, 6)
                    dayList
                        .offset(x: reduceMotion ? 0 : listInteraction.offset)
                        .padding(.horizontal, 16)
                        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: listDay)
                }
                .contentShape(Rectangle())
                .gesture(HomeDaySwipe(interaction: listInteraction, day: listDay, isEnabled: isActive, onPick: selectDay))
                .allowsHitTesting(isActive)
                .accessibilityAction(named: "前一天") { step(-1) }
                .accessibilityAction(named: "后一天") { step(1) }
                .padding(.bottom, 14)
                quietLinks.padding(.horizontal, 20)
            }
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background { ButlerBackground() }
        .toolbar(.hidden, for: .navigationBar)
        // Global navigation stays put while only the schedule list browses dates.
        .safeAreaBar(edge: .top) { header }
        .sheet(isPresented: $showingPicker) {
            NavigationStack {
                ScrollView {
                    DayPickerPanel(agenda: agenda, selected: listDay, pendingTaskCount: pendingTaskCount,
                                   onPick: { day in
                                       selectDay(day)
                                       closePicker()
                                   },
                                   onBrowseMonth: onBrowseMonth,
                                   onOverview: { closePicker(); onOpenOverview() },
                                   onTasks: { closePicker(); onOpenTasks() })
                        .padding(16)
                }
                .navigationTitle("日期与记录")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成", action: closePicker) } }
                .background { ButlerBackground() }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82), value: showingPicker)
        .sensoryFeedback(.selection, trigger: listDay)
        .onChange(of: isActive) { if !isActive { listInteraction.cancel() } }
        .onDisappear { listInteraction.cancel() }
    }

    private func closePicker() { showingPicker = false }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            dateCapsule
            Spacer(minLength: 8)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 0) {
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

    /// Home stays anchored to today. The sheet selects the list's date, not a different home page.
    private var dateCapsule: some View {
        HStack(spacing: 6) {
            Button { showingPicker.toggle() } label: {
                HStack(spacing: 8) {
                    Text(Self.label(for: agenda.today, today: agenda.today, calendar: calendar))
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("日期与记录")
            .accessibilityHint("打开完整日期面板，清单当前显示\(Self.label(for: listDay, today: agenda.today, calendar: calendar))")
        }
        .padding(.leading, 18).padding(.trailing, 16)
        .frame(height: 44)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    static func label(for day: Date, today: Date, calendar: Calendar = .current) -> String {
        let weekday = day.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "zh_CN")))
        let offset = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        if calendar.component(.year, from: day) != calendar.component(.year, from: today) {
            return day.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN")))
        }
        switch offset {
        case -1: return "昨天 · \(day.monthDay) \(weekday)"
        case 0: return "今天 · \(day.monthDay) \(weekday)"
        case 1: return "明天 · \(day.monthDay) \(weekday)"
        default: return "\(day.monthDay) \(weekday)"
        }
    }

    // MARK: The day's list

    private var dayList: some View {
        let list = HomeList.build(day: listDay, agenda: agenda, facts: facts,
                                  featured: isToday ? brief.target?.agendaTarget : nil, now: now)
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
            ForEach(Array(list.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { rowDivider }
                HomeRowView(row: row, onOpen: openListItem)
                    .accessibilityAction { if isActive { onOpen(row.target) } }
            }
            if !list.completed.isEmpty {
                if !list.rows.isEmpty { rowDivider }
                Text("已完成 \(list.completed.count) 件")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 13)
                ForEach(list.completed) { row in
                    rowDivider
                    HomeRowView(row: row, onOpen: openListItem)
                        .accessibilityAction { if isActive { onOpen(row.target) } }
                }
            }
        }
        .padding(.vertical, 6)
        .glassCard()
        .contentShape(Rectangle())
        .id(listDay)
        .transition(reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: slideForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: slideForward ? .leading : .trailing).combined(with: .opacity)))
    }

    private func openListItem(_ target: AgendaEntry.Target) {
        guard isActive, listInteraction.allowsTap else {
            ChatDiagnostics.log("home row tap suppressed during browsing")
            return
        }
        ChatDiagnostics.log("home row opened by tap")
        onOpen(target)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 16).padding(.trailing, 16)
    }

    private func step(_ direction: Int) {
        guard isActive else { return }
        guard let next = calendar.date(byAdding: .day, value: direction, to: listDay) else { return }
        selectDay(next)
    }

    private func selectDay(_ day: Date) {
        guard isActive else { return }
        slideForward = day > listDay
        listDay = calendar.startOfDay(for: day)
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
                if !row.lead.isEmpty {
                    Text(row.lead)
                        .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(row.isCompleted ? .secondary : .primary)
                        .frame(minWidth: 44, alignment: .leading)
                }
                if row.isCompleted {
                    Image(systemName: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).frame(width: 6)
                } else {
                    KindBar(color: row.kind.color, height: 34)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).font(.body)
                        .strikethrough(row.isCompleted)
                        .foregroundStyle(row.isCompleted ? Color.secondary : Color.primary).fixedSize(horizontal: false, vertical: true)
                    if let subtitle = row.subtitle {
                        Text(subtitle).font(.subheadline)
                            .foregroundStyle(row.isAlert ? Color.red : .secondary).fixedSize(horizontal: false, vertical: true)
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

/// Quick actions apply to their target; “其他安排” discusses the entire visible reminder.
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
                if !brief.text.isEmpty {
                    Button { onOther(brief) } label: {
                        HStack(spacing: 3) {
                            Text("其他安排")
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.vertical, 6).padding(.leading, 12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("其他安排")
                    .accessibilityHint("讨论当前整张管家提醒，包含其中提到的所有事情")
                }
            }
            Text(brief.text)
                .font(.system(size: 17, weight: .medium))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let target = brief.target {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(Array(brief.actions.enumerated()), id: \.element.id) { index, action in
                        Button { onAction(action, target) } label: {
                            briefButtonLabel(action.label, primary: index == 0)
                        }
                        .buttonStyle(.plain)
                    }
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

/// Full date sheet: month browsing, arbitrary date jump and task history.
struct DayPickerPanel: View {
    let agenda: HomeAgenda
    let selected: Date
    let pendingTaskCount: Int
    let onPick: (Date) -> Void
    let onOverview: () -> Void
    let onTasks: () -> Void

    let onBrowseMonth: (Date) -> Void
    @State private var visibleDate: Date
    private var calendar: Calendar { .current }

    init(agenda: HomeAgenda, selected: Date, pendingTaskCount: Int, onPick: @escaping (Date) -> Void,
         onBrowseMonth: @escaping (Date) -> Void, onOverview: @escaping () -> Void, onTasks: @escaping () -> Void) {
        self.agenda = agenda; self.selected = selected; self.pendingTaskCount = pendingTaskCount
        self.onPick = onPick; self.onBrowseMonth = onBrowseMonth; self.onOverview = onOverview; self.onTasks = onTasks
        _visibleDate = State(initialValue: selected)
    }

    private var month: Date { calendar.dateInterval(of: .month, for: visibleDate)?.start ?? visibleDate }

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
                    Button { visibleDate = calendar.date(byAdding: .month, value: -1, to: month) ?? month } label: { Image(systemName: "chevron.left").frame(width: 34, height: 34) }
                        .accessibilityLabel("上个月")
                    Button { visibleDate = calendar.date(byAdding: .month, value: 1, to: month) ?? month } label: { Image(systemName: "chevron.right").frame(width: 34, height: 34) }
                        .accessibilityLabel("下个月")
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
            DatePicker("跳到指定日期", selection: $visibleDate, displayedComponents: .date)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .padding(.horizontal, 8).padding(.vertical, 10)
            door("查看选定日期", detail: visibleDate.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))),
                 systemImage: "calendar.badge.clock", action: { onPick(calendar.startOfDay(for: visibleDate)) })
            door("回到今天", detail: nil, systemImage: "arrow.uturn.backward", action: { onPick(agenda.today) })
            Divider()
            door("日程总览", detail: "月 · 年 · 列表", systemImage: "calendar", action: onOverview)
            door("全部任务与历史", detail: pendingTaskCount > 0 ? "\(pendingTaskCount) 件待完成" : nil,
                 systemImage: "checklist", action: onTasks)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onChange(of: month, initial: true) { onBrowseMonth(month) }
    }

    private func cell(_ day: Date) -> some View {
        let isToday = day == agenda.today
        let isPast = day < agenda.today
        let isSelected = calendar.isDate(day, inSameDayAs: selected)
        let dots = Array(agenda.dots(on: day).prefix(3))
        return Button { onPick(day) } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 16, weight: isToday || isSelected ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(isSelected ? Color(.systemBackground) : isToday ? Color.red : isPast ? Color.secondary : Color.primary)
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
