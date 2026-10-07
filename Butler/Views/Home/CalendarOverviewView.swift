import SwiftUI

/// One continuous list. The calendar jumps to a day without filtering nearby dates.
struct CalendarOverviewView: View {
    let agenda: HomeAgenda
    let onBrowse: (DateInterval) -> Void
    let onBrowseMonth: (Date) -> Void
    let onOpen: (AgendaEntry) -> Void

    @State private var window: AgendaWindow
    @State private var visibleDay: Date?
    @State private var jumpRevision = 0
    @State private var userScrolled = false
    @State private var hasBrowsed = false
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
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .scrollPosition(id: $visibleDay, anchor: .top)
            .clipped()
            .onScrollPhaseChange { _, phase, context in
                if phase == .interacting { userScrolled = true; hasBrowsed = true }
                guard phase == .idle, userScrolled, !showingDates else { return }
                userScrolled = false
                let geometry = context.geometry
                let top = geometry.contentOffset.y + geometry.contentInsets.top
                let bottom = geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height
                if top < 60 { extend(earlier: true) }
                else if bottom < 60 { extend(earlier: false) }
            }
            .task(id: OverviewJump(revision: jumpRevision, days: overview.days.map(\.id))) {
                // onBrowse loads the requested window asynchronously. Keep the requested
                // date anchored as those groups arrive, until the user starts browsing.
                guard !hasBrowsed else { return }
                await Task.yield()
                guard !Task.isCancelled, !hasBrowsed else { return }
                proxy.scrollTo(window.anchor, anchor: .top)
                visibleDay = window.anchor
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            calendarStatus
        }
        .background { ButlerBackground() }
        .navigationTitle("日程总览")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingDates = true } label: {
                    Image(systemName: "calendar")
                }
                .accessibilityLabel("选择日期")
                .accessibilityHint("打开月历，跳转到某一天的安排")
            }
        }
        .onChange(of: window.interval, initial: true) { _, range in onBrowse(range) }
        .sheet(isPresented: $showingDates) {
            OverviewDatePicker(agenda: agenda, initialDate: visibleDay ?? window.anchor,
                               onBrowseMonth: onBrowseMonth) { day in
                locate(day)
                showingDates = false
            }
        }
    }

    private func locate(_ day: Date) {
        userScrolled = false
        hasBrowsed = false
        window.locate(day, calendar: calendar)
        visibleDay = window.anchor
        jumpRevision += 1
    }

    private func extend(earlier: Bool) {
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
        .accessibilityAction(named: "选择日期") { showingDates = true }
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

private struct OverviewJump: Equatable {
    let revision: Int
    let days: [Date]
}

private struct OverviewDatePicker: View {
    let agenda: HomeAgenda
    let onBrowseMonth: (Date) -> Void
    let onPick: (Date) -> Void
    @State private var month: Date
    @State private var contentHeight: CGFloat = 420
    private let initialDate: Date
    private let calendar = Calendar.current
    @Environment(\.dismiss) private var dismiss
    @Environment(CalendarFeed.self) private var calendarFeed

    init(agenda: HomeAgenda, initialDate: Date, onBrowseMonth: @escaping (Date) -> Void,
         onPick: @escaping (Date) -> Void) {
        self.agenda = agenda; self.initialDate = initialDate
        self.onBrowseMonth = onBrowseMonth; self.onPick = onPick
        _month = State(initialValue: Calendar.current.dateInterval(of: .month, for: initialDate)!.start)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack {
                    Text("选择日期").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 12)
                    Button("回到今天") { onPick(agenda.today) }
                        .font(.subheadline).frame(minHeight: 44)
                }
                monthNavigation
                HStack(spacing: 0) {
                    ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                    let leading = (calendar.component(.weekday, from: month) + 5) % 7
                    ForEach(0..<leading, id: \.self) { _ in
                        Color.clear.frame(height: 44).accessibilityHidden(true)
                    }
                    ForEach(AgendaWindow.days(in: calendar.dateInterval(of: .month, for: month)!, calendar: calendar), id: \.self) { day in
                        cell(day)
                    }
                }
                if calendarFeed.enabled && calendarFeed.canRead && !calendarFeed.covers(calendar.dateInterval(of: .month, for: month)!) {
                    Text("正在读取日历标记…").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 16)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { height in
                if height > 0 { contentHeight = height }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .presentationBackground(.regularMaterial)
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .accessibilityAction(.escape) { dismiss() }
        .onChange(of: month, initial: true) { _, value in onBrowseMonth(value) }
    }

    private var monthNavigation: some View {
        HStack(spacing: 0) {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel("上个月")
            Spacer(minLength: 0)
            Picker("年份", selection: Binding(get: { calendar.component(.year, from: month) }, set: { setMonth(year: $0) })) {
                let year = calendar.component(.year, from: month)
                ForEach((year - 10)...(year + 10), id: \.self) { Text(verbatim: "\($0)年").tag($0) }
            }.pickerStyle(.menu)
            Picker("月份", selection: Binding(get: { calendar.component(.month, from: month) }, set: { setMonth(number: $0) })) {
                ForEach(1...12, id: \.self) { Text(verbatim: "\($0)月").tag($0) }
            }.pickerStyle(.menu)
            Spacer(minLength: 0)
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .accessibilityLabel("下个月")
        }
        .foregroundStyle(.primary)
    }

    private func shiftMonth(_ amount: Int) { month = calendar.date(byAdding: .month, value: amount, to: month)! }
    private func setMonth(year: Int? = nil, number: Int? = nil) {
        month = calendar.date(from: DateComponents(year: year ?? calendar.component(.year, from: month),
                                                   month: number ?? calendar.component(.month, from: month), day: 1))!
    }

    private func cell(_ day: Date) -> some View {
        let picked = calendar.isDate(day, inSameDayAs: initialDate)
        let today = calendar.isDate(day, inSameDayAs: agenda.today)
        let hasEvents = !agenda.dots(on: day).isEmpty
        // Explicit semantic colors avoid resolving .primary through the selected
        // cell's inverted foreground, which made its background lose contrast.
        let ink = picked ? Color(uiColor: .systemBackground) : Color(uiColor: .label)
        return Button { onPick(day) } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))").font(.body).monospacedDigit()
                Circle().fill(hasEvents ? ink.opacity(picked ? 1 : 0.5) : .clear).frame(width: 3, height: 3)
            }
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(picked ? Color(uiColor: .label) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                if today && !picked {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color(uiColor: .label).opacity(0.3), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(day.formatted(.dateTime.year().month().day().weekday(.wide).locale(Locale(identifier: "zh_CN")))
                            + (today ? "，今天" : "") + (hasEvents ? "，有安排" : ""))
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}
