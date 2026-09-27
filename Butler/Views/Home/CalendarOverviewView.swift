import SwiftUI

/// Everything ahead, beyond this week: month calendars, a year at a glance, or one long list.
struct CalendarOverviewView: View {
    let agenda: HomeAgenda
    let onOpenDay: (Date) -> Void
    let onOpen: (AgendaEntry.Target) -> Void

    enum Mode: String, CaseIterable { case month = "月", year = "年", list = "列表" }

    @State private var mode: Mode = .month
    @State private var jumpTo: Date?
    private let calendar = Calendar.current
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The first day of this month and the eleven after it.
    private var months: [Date] {
        let start = calendar.dateInterval(of: .month, for: agenda.today)?.start ?? agenda.today
        return (0..<12).compactMap { calendar.date(byAdding: .month, value: $0, to: start) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                switch mode {
                case .month:
                    LazyVStack(spacing: 20) {
                        ForEach(months, id: \.self) { month in
                            MonthCard(month: month, agenda: agenda, onOpenDay: onOpenDay)
                                .id(month)
                        }
                    }
                    .padding(.horizontal, 16)
                case .year:
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 20) {
                        ForEach(months, id: \.self) { month in
                            Button {
                                jumpTo = month
                                withAnimation(reduceMotion ? nil : .snappy) { mode = .month }
                            } label: {
                                MiniMonth(month: month, agenda: agenda)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                case .list:
                    AgendaList(agenda: agenda, onOpen: onOpen)
                        .padding(.horizontal, 16)
                }
            }
            .contentMargins(.vertical, 12, for: .scrollContent)
            .orbScrollTracking()
            .onChange(of: mode) { _, newMode in
                guard newMode == .month, let month = jumpTo else { return }
                Task { @MainActor in
                    proxy.scrollTo(month, anchor: .top)
                    jumpTo = nil
                }
            }
        }
        .background { ButlerBackground() }
        .navigationTitle("日程总览")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("显示方式", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: mode)
    }
}

// MARK: - Month

/// Monday-first weeks, as calendars are usually printed in China.
private func monthDays(_ month: Date, calendar: Calendar) -> [Date?] {
    guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
    let weekday = calendar.component(.weekday, from: month) // 1 = Sunday
    let leading = (weekday + 5) % 7
    let days = range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
    return Array(repeating: nil, count: leading) + days
}

private let weekdayHeaders = ["一", "二", "三", "四", "五", "六", "日"]

private struct MonthCard: View {
    let month: Date
    let agenda: HomeAgenda
    let onOpenDay: (Date) -> Void
    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(month.formatted(.dateTime.year().month(.wide).locale(Locale(identifier: "zh_CN"))))
                .font(.title3.bold())
                .padding(.horizontal, 6)
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    ForEach(weekdayHeaders, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                    ForEach(Array(monthDays(month, calendar: calendar).enumerated()), id: \.offset) { _, day in
                        if let day { cell(day) } else { Color.clear.frame(height: 48) }
                    }
                }
            }
            .padding(12)
            .glassCard(radius: 26)
        }
    }

    private func cell(_ day: Date) -> some View {
        let isToday = day == agenda.today
        let isPast = day < agenda.today
        let dots = isPast ? [] : agenda.dots(on: day)
        return Button { onOpenDay(day) } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.body.weight(isToday ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? Color.white : (isPast ? Color(.tertiaryLabel) : .primary))
                    .frame(width: 32, height: 32)
                    .background(isToday ? Color.red : .clear, in: Circle())
                HStack(spacing: 3) {
                    ForEach(dots, id: \.self) { Circle().fill($0.color).frame(width: 5, height: 5) }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPast)
        .accessibilityLabel(day.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_CN")))
                            + (dots.isEmpty ? "" : "，有安排"))
    }
}

// MARK: - Year

private struct MiniMonth: View {
    let month: Date
    let agenda: HomeAgenda
    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(month.formatted(.dateTime.month(.wide).locale(Locale(identifier: "zh_CN"))))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(calendar.isDate(month, equalTo: agenda.today, toGranularity: .month) ? .red : .primary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 3) {
                // Always six weeks, so every tile in the year grid is the same height.
                let cells = monthDays(month, calendar: calendar)
                ForEach(Array((cells + Array(repeating: nil, count: max(0, 42 - cells.count))).enumerated()), id: \.offset) { _, day in
                    if let day {
                        let kind = day < agenda.today ? nil : agenda.dots(on: day).first
                        Circle()
                            .fill(kind?.color ?? Color(.quaternarySystemFill))
                            .overlay { if day == agenda.today { Circle().strokeBorder(.red, lineWidth: 1.5) } }
                            .frame(width: 8, height: 8)
                    } else {
                        Color.clear.frame(width: 8, height: 8)
                    }
                }
            }
            Text(summary).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .glassCard(radius: 20)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        let days = monthDays(month, calendar: calendar).compactMap { $0 }.filter { $0 >= agenda.today }
        let count = days.reduce(0) { $0 + agenda.entries(on: $1).filter { !$0.isRoutine }.count }
        return count == 0 ? "没有安排" : "\(count) 项"
    }
}

// MARK: - List

private struct AgendaList: View {
    let agenda: HomeAgenda
    let onOpen: (AgendaEntry.Target) -> Void

    private var routines: [AgendaEntry] {
        var seen = Set<AgendaEntry.Target>()
        return agenda.days.flatMap { agenda.entries(on: $0) }.filter { $0.isRoutine && seen.insert($0.target).inserted }
    }

    private var days: [(Date, [AgendaEntry])] {
        agenda.days.compactMap { day in
            let entries = agenda.entries(on: day).filter { !$0.isRoutine }
            return entries.isEmpty ? nil : (day, entries)
        }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            if !agenda.needsAttention.isEmpty {
                section("需要处理", agenda.needsAttention, showsTime: false)
            }
            if !routines.isEmpty {
                section("每天", routines, showsTime: true)
            }
            ForEach(days, id: \.0) { day, entries in
                section(title(for: day), entries, showsTime: true)
            }
            if days.isEmpty && routines.isEmpty && agenda.needsAttention.isEmpty {
                ContentUnavailableView("接下来一年没有安排", systemImage: "calendar",
                                       description: Text("跟管家说一句，比如“下周六提醒我给妈妈打电话”。"))
            }
        }
    }

    private func title(for day: Date) -> String {
        let date = day.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_CN")))
        let offset = Calendar.current.dateComponents([.day], from: agenda.today, to: day).day ?? 0
        switch offset {
        case 0: return "今天 · \(date)"
        case 1: return "明天 · \(date)"
        default: return "\(date) · \(offset) 天后"
        }
    }

    private func section(_ title: String, _ entries: [AgendaEntry], showsTime: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 6)
            GroupCard {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    AgendaRow(entry: entry, accessory: .none, leading: showsTime ? .time(entry) : .bar) { onOpen(entry.target) }
                    if index < entries.count - 1 { RowDivider(inset: showsTime ? 92 : 36) }
                }
            }
        }
    }
}
