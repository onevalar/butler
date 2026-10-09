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
    let onBriefInteraction: () -> Void
    let onBrowseMonth: (Date) -> Void
    /// Done / later / pause / cancel straight from the list, without opening the task.
    var onTaskAction: (UUID, TaskQuickAction) -> Void = { _, _ in }

    @State private var showingPicker = false
    @State private var dateNavigation: HomeDayNavigationStyle = .slide
    @State private var listInteraction = HomeDayInteraction()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var calendar: Calendar { .current }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !brief.text.isEmpty {
                    BriefCard(brief: brief, busy: briefBusy, onAction: onBriefAction, onInteraction: onBriefInteraction)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
                dayNavigation
                HomeDayPager(day: $listDay, interaction: listInteraction, isActive: isActive,
                             navigationStyle: dateNavigation) { day in
                    dayList(day).padding(.horizontal, 16)
                }
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
            // Just the month: tap a day to see it. The overview lives at the bottom of home, tasks in settings.
            DayPickerPanel(agenda: agenda, selected: listDay,
                           onPick: { day in
                               selectDay(day, style: .fade)
                               closePicker()
                           },
                           onBrowseMonth: onBrowseMonth)
                .padding(.horizontal, 16).padding(.top, 30)
                .frame(maxHeight: .infinity, alignment: .top)
                // Tall enough for a six-week month and no more, on the system sheet surface.
                .presentationDetents([.height(420)])
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
            calendarButton
            Spacer(minLength: 8)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 0) {
                    Button(action: onOpenInventory) {
                        ItemsGlyph(size: 21, lineWidth: 1.7).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("物品")
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

    /// Today stays visible while the schedule below browses other dates.
    private var calendarButton: some View {
        Button { showingPicker.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(agenda.today.monthDay).font(.title2.weight(.semibold))
                Text(agenda.today.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "zh_CN"))))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选择日期")
        .accessibilityHint("打开月历，清单当前显示\(Self.label(for: listDay, today: agenda.today, calendar: calendar))")
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

    private var dayNavigation: some View {
        HStack(spacing: 4) {
            Text(listDay == agenda.today ? "今日安排" : browsedDateLabel)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            if listDay != agenda.today {
                Button("回到今天") { selectDay(agenda.today) }
                    .font(.subheadline)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("回到今天")
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .disabled(!isActive || listInteraction.isSettling)
        .padding(.horizontal, 22)
    }

    private var browsedDateLabel: String {
        let date = calendar.component(.year, from: listDay) == calendar.component(.year, from: agenda.today)
            ? listDay.monthDay
            : listDay.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN")))
        let weekday = listDay.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "zh_CN")))
        return "\(date) \(weekday)"
    }

    private func dayList(_ day: Date) -> some View {
        let list = HomeList.build(day: day, agenda: agenda, facts: facts,
                                  featured: nil, now: now)
        return VStack(spacing: 0) {
            if list.rows.isEmpty && list.completed.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    Text(day == agenda.today ? "今天暂无安排" : "这天没有安排")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 18).frame(minHeight: 56)
            }
            ForEach(Array(list.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { rowDivider }
                HomeRowView(row: row, onOpen: openListItem, onTaskAction: taskAction)
                    .accessibilityAction { if isActive { onOpen(row.target) } }
            }
            if !list.completed.isEmpty {
                // A small caption above the finished ones, not a row of its own between two lines.
                Text("已完成 \(list.completed.count) 件")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.top, list.rows.isEmpty ? 6 : 16).padding(.bottom, 2)
                ForEach(Array(list.completed.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { rowDivider }
                    HomeRowView(row: row, onOpen: openListItem, onTaskAction: taskAction)
                        .accessibilityAction { if isActive { onOpen(row.target) } }
                }
            }
        }
        .padding(.vertical, 6)
        .glassCard()
        .contentShape(Rectangle())
    }

    private func taskAction(_ id: UUID, _ action: TaskQuickAction) {
        guard isActive, listInteraction.allowsTap else { return }
        onTaskAction(id, action)
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

    private func selectDay(_ day: Date, style: HomeDayNavigationStyle = .slide) {
        guard isActive, !listInteraction.isSettling else { return }
        dateNavigation = style
        listDay = calendar.startOfDay(for: day)
    }

    // MARK: One quiet line

    /// The same today-through-Sunday window as the overview; routines are named separately.
    private var quietLinks: some View {
        quietRow("日程总览", AgendaOverview.homeSubtitle(agenda: agenda), action: onOpenOverview)
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
/// What can be done to a task from the home list.
enum TaskQuickAction { case complete, remindLater, pause, cancel, nudge }

/// One line of the day list. A task has a circle to tick it off (like Reminders) and, on a long press,
/// the other things you'd otherwise dig for on its page.
struct HomeRowView: View {
    let row: HomeListRow
    let onOpen: (AgendaEntry.Target) -> Void
    var onTaskAction: (UUID, TaskQuickAction) -> Void = { _, _ in }

    private var taskID: UUID? {
        if case .reminder(let id) = row.target { return id }
        return nil
    }

    var body: some View {
        HStack(spacing: 0) {
            if let taskID, !row.isCompleted {
                Button { onTaskAction(taskID, .complete) } label: {
                    Circle().strokeBorder(row.kind.color, lineWidth: 1.8)
                        .frame(width: 24, height: 24)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 6)
                .accessibilityLabel("完成「\(row.title)」")
            }
            Button { onOpen(row.target) } label: {
                HStack(spacing: 14) {
                    if !row.lead.isEmpty {
                        Text(row.lead)
                            .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(row.isCompleted ? .secondary : .primary)
                            .frame(minWidth: 44, alignment: .leading)
                    }
                    if row.isCompleted {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(.secondary)
                    } else if taskID == nil {
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
                    // Tasks are ticked off with the circle; the capsule is only for things at home.
                    if let action = row.action, taskID == nil { CapsuleLabel(action) }
                }
                .padding(.leading, taskID != nil && !row.isCompleted ? 4 : 16).padding(.trailing, 14).padding(.vertical, 9)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            if let taskID, !row.isCompleted {
                if let nudge = HouseholdStore.shared.names.nudgeLabel(ReminderStore.openOnDevice().reminder(id: taskID)?.sharing) {
                    Button(nudge, systemImage: "hand.wave") { onTaskAction(taskID, .nudge) }
                }
                Button("完成", systemImage: "checkmark.circle") { onTaskAction(taskID, .complete) }
                Button("30 分钟后再提醒", systemImage: "clock.arrow.circlepath") { onTaskAction(taskID, .remindLater) }
                Button("暂停提醒", systemImage: "pause.circle") { onTaskAction(taskID, .pause) }
                Button("取消任务", systemImage: "xmark.circle", role: .destructive) { onTaskAction(taskID, .cancel) }
                Divider()
                Button("查看详情", systemImage: "info.circle") { onOpen(row.target) }
            }
        }
    }
}
