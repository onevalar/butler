import SwiftUI

/// One continuous list. The calendar locates a day; only an explicit range filters it.
struct CalendarOverviewView: View {
    let agenda: HomeAgenda
    let onBrowse: (DateInterval) -> Void
    let onBrowseMonth: (Date) -> Void
    let onOpen: (AgendaEntry) -> Void

    @State private var window: AgendaWindow
    @State private var visibleDay: Date?
    @State private var jumpRevision = 0
    @State private var userScrolled = false
    @State private var showingDates = false
    @Environment(CalendarFeed.self) private var calendarFeed
    private let calendar = Calendar.current

    init(agenda: HomeAgenda, onBrowse: @escaping (DateInterval) -> Void,
         onBrowseMonth: @escaping (Date) -> Void, onOpen: @escaping (AgendaEntry) -> Void) {
        self.agenda = agenda; self.onBrowse = onBrowse
        self.onBrowseMonth = onBrowseMonth; self.onOpen = onOpen
        _window = State(initialValue: AgendaWindow(today: agenda.today))
        _visibleDay = State(initialValue: agenda.today)
    }

    private var overview: AgendaOverview {
        AgendaOverview(agenda: agenda, interval: window.interval, calendar: calendar, focusedDay: window.anchor)
    }
    private var waitingForCalendar: Bool {
        calendarFeed.enabled && calendarFeed.canRead && !calendarFeed.covers(window.interval)
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(overview.days) { day in
                            VStack(alignment: .leading, spacing: 0) {
                                dateHeading(day.date)
                                dayRows(day)
                            }
                            .padding(.bottom, 28)
                            .id(day.date)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 24)
                    .padding(.bottom, max(24, viewport.size.height - 160))
                }
                .scrollPosition(id: $visibleDay, anchor: .top)
                .clipped()
                .onScrollPhaseChange { _, phase, context in
                    if phase == .interacting { userScrolled = true }
                    guard phase == .idle, userScrolled, !showingDates else { return }
                    userScrolled = false
                    let geometry = context.geometry
                    let top = geometry.contentOffset.y + geometry.contentInsets.top
                    let bottom = geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height
                    if top < 60 { extend(earlier: true) }
                    else if bottom < 60 { extend(earlier: false) }
                }
                .task(id: jumpRevision) {
                    // Wait for the destination's date anchor to participate in layout, not a timed animation.
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(window.anchor, anchor: .top)
                    visibleDay = window.anchor
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let range = window.selection {
                    HStack(spacing: 12) {
                        Button { showingDates = true } label: { Text(rangeLabel(range)).multilineTextAlignment(.leading) }
                        Spacer(minLength: 0)
                        Button("取消限定") { locate(visibleDay ?? window.anchor) }
                    }
                    .font(.subheadline).buttonStyle(.plain)
                    .frame(minHeight: 44).padding(.horizontal, 24)
                }
                calendarStatus
            }
            .padding(.bottom, 6)
        }
        .background { ButlerBackground() }
        .navigationTitle("日程总览")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("日期") { showingDates = true }
                    .accessibilityHint("打开月历，定位日期或选择时间段")
            }
        }
        .onChange(of: window.interval, initial: true) { _, range in onBrowse(range) }
        .sheet(isPresented: $showingDates) {
            OverviewDatePicker(agenda: agenda, initialDate: visibleDay ?? window.anchor,
                               selection: window.selection, onBrowseMonth: onBrowseMonth) { start, end in
                if let end { window.select(from: start, through: end, calendar: calendar) }
                else { window.locate(start, calendar: calendar) }
                visibleDay = window.anchor
                showingDates = false
                jumpRevision += 1
            }
        }
    }

    private func locate(_ day: Date) {
        userScrolled = false
        window.locate(day, calendar: calendar)
        visibleDay = window.anchor
        jumpRevision += 1
    }

    private func extend(earlier: Bool) {
        guard window.selection == nil else { return }
        let kept = visibleDay ?? window.anchor
        window.extend(earlier: earlier, keeping: kept, calendar: calendar)
        // scrollPosition preserves the visible date when earlier rows are prepended.
    }

    /// Only says something when it matters: the calendar was turned on but can't be read, or is still loading.
    /// Earlier and later days load by themselves as the list reaches either end; there are no load buttons.
    @ViewBuilder private var calendarStatus: some View {
        if !calendarFeed.enabled {
            EmptyView()
        } else if !calendarFeed.canRead {
            status("无法读取系统日历，请检查日历权限")
        } else if waitingForCalendar {
            status("正在读取系统日历…")
        }
    }

    private func status(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.vertical, 8)
    }

    private func dateHeading(_ day: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(dateLabel(day)).font(.title3.weight(.semibold))
            Text(day.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "zh_CN")))
                 + (calendar.isDate(day, inSameDayAs: agenda.today) ? " · 今天" : ""))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func dayRows(_ day: AgendaOverview.Day) -> some View {
        ForEach(Array(day.entries.enumerated()), id: \.element.id) { index, entry in
            if index > 0 { Divider().padding(.leading, 68) }
            overviewRow(entry)
        }
        if !day.routines.isEmpty {
            DisclosureGroup {
                ForEach(day.routines) { overviewRow($0) }
            } label: {
                Text("每日提醒 · \(day.routines.count)")
                    .font(.footnote).foregroundStyle(.secondary).frame(minHeight: 44)
            }
            .tint(Color.secondary)
        }
        if day.entries.isEmpty && day.routines.isEmpty {
            Text(waitingForCalendar ? "正在读取安排…" : "暂无安排")
                .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 16)
        }
    }

    private func overviewRow(_ entry: AgendaEntry) -> some View {
        Button { onOpen(entry) } label: {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.isAllDay ? "全天" : (entry.calendarSpan?.start ?? entry.start)?.clockTime ?? "全天")
                        .font(.subheadline)
                    // Reminder end values are synthetic timeline lengths, not actual appointments.
                    if !entry.isAllDay, let span = entry.calendarSpan,
                       span.end > span.start, calendar.isDate(span.start, inSameDayAs: span.end) {
                        Text("–\(span.end.clockTime)").font(.caption)
                    }
                }
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 54, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title).font(.body)
                        .foregroundStyle(entry.isCompleted ? .secondary : .primary)
                    if let subtitle = entry.subtitle, !entry.isRoutine {
                        Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let span = entry.calendarSpan, spansDays(span, allDay: entry.isAllDay) {
                        Text(spanLabel(span, allDay: entry.isAllDay)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                if entry.isCompleted {
                    Image(systemName: "checkmark").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("已完成")
                }
            }
            .padding(.vertical, 14).frame(minHeight: 60).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dateLabel(_ day: Date) -> String {
        let format = calendar.component(.year, from: day) == calendar.component(.year, from: agenda.today)
            ? Date.FormatStyle.dateTime.month().day() : Date.FormatStyle.dateTime.year().month().day()
        return day.formatted(format.locale(Locale(identifier: "zh_CN")))
    }

    private func rangeLabel(_ range: DateInterval) -> String {
        let end = calendar.date(byAdding: .day, value: -1, to: range.end)!
        return range.start == end ? dateLabel(range.start) : "\(dateLabel(range.start))—\(dateLabel(end))"
    }

    private func spansDays(_ span: DateInterval, allDay: Bool) -> Bool {
        let end = allDay && span.duration > 0 ? span.end.addingTimeInterval(-1) : span.end
        return !calendar.isDate(span.start, inSameDayAs: end)
    }

    private func spanLabel(_ span: DateInterval, allDay: Bool) -> String {
        let end = allDay && span.duration > 0 ? span.end.addingTimeInterval(-1) : span.end
        if allDay { return "\(dateLabel(span.start))—\(dateLabel(end))" }
        return "\(dateLabel(span.start)) \(span.start.clockTime)—\(dateLabel(end)) \(end.clockTime)"
    }
}

private struct OverviewDatePicker: View {
    let agenda: HomeAgenda
    let onBrowseMonth: (Date) -> Void
    /// nil end means locate, even when an explicit one-day range would have identical endpoints.
    let onPick: (Date, Date?) -> Void
    @State private var month: Date
    @State private var start: Date?
    @State private var end: Date?
    @State private var selectingRange: Bool
    private let initialDate: Date
    private let calendar = Calendar.current
    @Environment(\.dismiss) private var dismiss
    @Environment(CalendarFeed.self) private var calendarFeed

    init(agenda: HomeAgenda, initialDate: Date, selection: DateInterval?, onBrowseMonth: @escaping (Date) -> Void,
         onPick: @escaping (Date, Date?) -> Void) {
        self.agenda = agenda; self.initialDate = initialDate
        self.onBrowseMonth = onBrowseMonth; self.onPick = onPick
        _month = State(initialValue: Calendar.current.dateInterval(of: .month, for: initialDate)!.start)
        _start = State(initialValue: selection?.start)
        _end = State(initialValue: selection.map { Calendar.current.date(byAdding: .day, value: -1, to: $0.end)! })
        _selectingRange = State(initialValue: selection != nil)
    }

    private var validRange: Bool {
        guard let start, let end else { return false }
        return AgendaWindow.validSelection(from: start, through: end, calendar: calendar)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    monthNavigation
                    HStack(spacing: 0) {
                        ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) {
                            Text($0).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                        let leading = (calendar.component(.weekday, from: month) + 5) % 7
                        ForEach(0..<leading, id: \.self) { _ in Color.clear.frame(height: 44) }
                        ForEach(AgendaWindow.days(in: calendar.dateInterval(of: .month, for: month)!, calendar: calendar), id: \.self) { day in
                            cell(day)
                        }
                    }
                    if calendarFeed.enabled && calendarFeed.canRead && !calendarFeed.covers(calendar.dateInterval(of: .month, for: month)!) {
                        Text("正在读取日历标记…").font(.footnote).foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack {
                        Button(selectingRange ? "取消时间段" : "选择时间段") {
                            selectingRange.toggle(); start = nil; end = nil
                        }
                        Spacer()
                        Button("今天") { onPick(agenda.today, nil) }
                    }
                    .font(.subheadline).frame(minHeight: 44)
                    if selectingRange {
                        HStack(spacing: 12) {
                            Text(rangePrompt).font(.footnote).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("查看") { if let start, let end { onPick(start, end) } }
                                .buttonStyle(.borderedProminent).disabled(!validRange)
                        }
                        if start != nil && end != nil && !validRange {
                            Text("一次最多查看366天，请缩短时间段。")
                                .font(.footnote).foregroundStyle(.red)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 20)
            }
            .background { ButlerBackground() }
            .navigationTitle("选择日期").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭日期选择")
                }
            }
        }
        .presentationDetents([.height(540), .large])
        .presentationDragIndicator(.visible)
        .onChange(of: month, initial: true) { _, value in onBrowseMonth(value) }
    }

    private var monthNavigation: some View {
        HStack {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel("上个月")
            Spacer(minLength: 0)
            Picker("年份", selection: Binding(get: { calendar.component(.year, from: month) }, set: { setMonth(year: $0) })) {
                let year = calendar.component(.year, from: month)
                ForEach((year - 10)...(year + 10), id: \.self) { Text("\($0)年").tag($0) }
            }.pickerStyle(.menu)
            Picker("月份", selection: Binding(get: { calendar.component(.month, from: month) }, set: { setMonth(number: $0) })) {
                ForEach(1...12, id: \.self) { Text("\($0)月").tag($0) }
            }.pickerStyle(.menu)
            Spacer(minLength: 0)
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .accessibilityLabel("下个月")
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
    }

    private func shiftMonth(_ amount: Int) { month = calendar.date(byAdding: .month, value: amount, to: month)! }
    private func setMonth(year: Int? = nil, number: Int? = nil) {
        month = calendar.date(from: DateComponents(year: year ?? calendar.component(.year, from: month),
                                                   month: number ?? calendar.component(.month, from: month), day: 1))!
    }

    private var rangePrompt: String {
        guard let start else { return "选择开始日期" }
        let format = Date.FormatStyle.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))
        return "\(start.formatted(format))—\(end.map { $0.formatted(format) } ?? "选择结束日期")"
    }

    private func cell(_ day: Date) -> some View {
        let picked = selectingRange ? (day == start || day == end) : calendar.isDate(day, inSameDayAs: initialDate)
        let between = selectingRange && start != nil && end != nil && day > start! && day < end!
        let hasEvents = !agenda.dots(on: day).isEmpty
        return Button {
            if !selectingRange { onPick(day, nil) }
            else if let first = start, end == nil { start = min(first, day); end = max(first, day) }
            else { start = day; end = nil }
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))").font(.body).monospacedDigit()
                Circle().fill(hasEvents ? (picked ? Color(.systemBackground) : Color.secondary) : .clear).frame(width: 3, height: 3)
            }
            .foregroundStyle(picked ? Color(.systemBackground) : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(picked ? Color.primary : between ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(.dateTime.year().month().day().weekday(.wide).locale(Locale(identifier: "zh_CN"))) + (hasEvents ? "，有安排" : ""))
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}
