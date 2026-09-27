import SwiftUI

/// One whole day on TimelineUI's day timeline. The week strip and all-day items stay pinned on top
/// (like Apple Calendar); the hours scroll underneath and open at now or the day's first event.
struct DayScheduleView: View {
    let agenda: HomeAgenda
    @State var day: Date
    let onOpen: (AgendaEntry.Target) -> Void

    private var entries: [AgendaEntry] { agenda.entries(on: day) }
    private var items: [TimelineItem] { entries.map(\.timelineItem) }
    private var allDay: [TimelineItem] { items.filter(\.isAllDay) }

    /// Monday to Sunday around the day shown, so any date opened from the overview has its week.
    private var week: [Date] {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: day)
        let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: day) ?? day
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    var body: some View {
        let timeline = DayTimelineView(items: items, day: day)
        ScrollViewReader { proxy in
            ScrollView {
                TimelineHourGrid(items: items, day: day, hours: 0...23, onTap: tap)
                    .padding(.top, 20).padding(.leading, 8).padding(.trailing, 12).padding(.bottom, 12)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaBar(edge: .top) {
                VStack(spacing: 12) {
                    WeekStrip(agenda: agenda, selected: $day, days: week)
                        .padding(.horizontal, 12)
                    if !allDay.isEmpty {
                        TimelineAllDaySection(items: allDay, onTap: tap)
                            .padding(.vertical, 12).padding(.trailing, 16).padding(.leading, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 8)
            }
            .onAppear { scroll(proxy, to: timeline.scrollAnchorHour, animated: false) }
            .onChange(of: day) { _, _ in scroll(proxy, to: DayTimelineView(items: items, day: day).scrollAnchorHour, animated: true) }
        }
        .navigationTitle(day.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_CN"))))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if day != agenda.today {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("今天") { withAnimation(.snappy) { day = agenda.today } }
                }
            }
        }
    }

    private func tap(_ item: TimelineItem) {
        if let entry = entries.first(where: { $0.id == item.id }) { onOpen(entry.target) }
    }

    private func scroll(_ proxy: ScrollViewProxy, to hour: Int, animated: Bool) {
        // Wait one layout pass so the grid exists before scrolling to it.
        Task { @MainActor in
            if animated {
                withAnimation { proxy.scrollTo("hour-\(hour)", anchor: .top) }
            } else {
                proxy.scrollTo("hour-\(hour)", anchor: .top)
            }
        }
    }
}
