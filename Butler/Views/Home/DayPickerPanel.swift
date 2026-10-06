import SwiftUI

/// Date sheet: one month at a time; tap a day to see its list.
struct DayPickerPanel: View {
    let agenda: HomeAgenda
    let selected: Date
    let onPick: (Date) -> Void
    let onBrowseMonth: (Date) -> Void
    @State private var visibleDate: Date
    private var calendar: Calendar { .current }

    init(agenda: HomeAgenda, selected: Date, onPick: @escaping (Date) -> Void, onBrowseMonth: @escaping (Date) -> Void) {
        self.agenda = agenda; self.selected = selected
        self.onPick = onPick; self.onBrowseMonth = onBrowseMonth
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
        }
        .frame(maxWidth: .infinity)
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

}
