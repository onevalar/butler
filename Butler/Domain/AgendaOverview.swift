import Foundation

/// A bounded, bidirectional loading window; only an explicit range filters the agenda.
/// End dates are exclusive. Calendar arithmetic keeps day boundaries correct across DST.
struct AgendaWindow: Equatable {
    private(set) var anchor: Date
    private(set) var loaded: DateInterval
    private(set) var selection: DateInterval?
    var interval: DateInterval { selection ?? loaded }

    init(today: Date, calendar: Calendar = .current) {
        anchor = calendar.startOfDay(for: today)
        loaded = Self.around(anchor, calendar: calendar)
    }

    private static func around(_ day: Date, calendar: Calendar) -> DateInterval {
        DateInterval(start: calendar.date(byAdding: .day, value: -30, to: day)!,
                     end: calendar.date(byAdding: .day, value: 91, to: day)!)
    }

    mutating func locate(_ day: Date, calendar: Calendar = .current) {
        anchor = calendar.startOfDay(for: day)
        selection = nil
        if anchor < loaded.start || anchor >= loaded.end { loaded = Self.around(anchor, calendar: calendar) }
    }

    mutating func select(from start: Date, through end: Date, calendar: Calendar = .current) {
        guard Self.validSelection(from: start, through: end, calendar: calendar) else { return }
        anchor = calendar.startOfDay(for: start)
        selection = DateInterval(start: anchor, end: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))!)
    }

    /// Add a month at an edge, retiring only dates far behind the reader after a year is loaded.
    mutating func extend(earlier: Bool, keeping day: Date, calendar: Calendar = .current) {
        guard selection == nil else { return }
        if earlier {
            let start = calendar.date(byAdding: .day, value: -30, to: loaded.start)!
            loaded = DateInterval(start: start, end: min(loaded.end, calendar.date(byAdding: .day, value: 366, to: start)!))
        } else {
            let end = calendar.date(byAdding: .day, value: 30, to: loaded.end)!
            loaded = DateInterval(start: max(loaded.start, calendar.date(byAdding: .day, value: -366, to: end)!), end: end)
        }
        if anchor < loaded.start || anchor >= loaded.end {
            let lastDay = calendar.date(byAdding: .day, value: -1, to: loaded.end)!
            anchor = min(max(calendar.startOfDay(for: day), loaded.start), lastDay)
        }
    }

    static func week(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let day = calendar.startOfDay(for: date)
        let monday = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: day) + 5) % 7), to: day)!
        return DateInterval(start: monday, end: calendar.date(byAdding: .day, value: 7, to: monday)!)
    }

    static func days(in interval: DateInterval, calendar: Calendar = .current) -> [Date] {
        let count = calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 0
        return (0..<max(0, count)).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }

    /// Bounds the amount of on-demand work; the date itself can be years in the past or future.
    static func validSelection(from start: Date, through end: Date, calendar: Calendar = .current) -> Bool {
        let length = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? -1
        return (0..<366).contains(length)
    }
}

/// The same projection supplies the homepage count and the overview rows.
struct AgendaOverview {
    struct Day: Identifiable {
        let date: Date
        let entries: [AgendaEntry]
        var routines: [AgendaEntry] = []
        var id: Date { date }
    }

    let days: [Day]
    let routines: [AgendaEntry]
    var count: Int { days.reduce(0) { $0 + $1.entries.filter { !$0.isCompleted }.count } }

    init(agenda: HomeAgenda, interval: DateInterval, calendar: Calendar = .current, focusedDay: Date? = nil) {
        var seenEvents = Set<String>()
        var seenRoutines = Set<AgendaEntry.Target>()
        var daily: [AgendaEntry] = []
        var groups: [Day] = []
        // On a date jump, an ongoing event belongs at the destination, not on a hidden earlier day.
        let focusedOccurrences = Set(focusedDay.map { agenda.entries(on: $0).compactMap(\.calendarOccurrenceID) } ?? [])
        for day in AgendaWindow.days(in: interval, calendar: calendar) {
            var dayRoutines: [AgendaEntry] = []
            let entries = agenda.entries(on: day).filter { entry in
                if entry.isRoutine && !entry.isCompleted {
                    if seenRoutines.insert(entry.target).inserted { daily.append(entry) }
                    dayRoutines.append(entry)
                    return false
                }
                // One multi-day event is one row, but separate occurrences of a repeating event remain separate.
                if let occurrence = entry.calendarOccurrenceID {
                    if focusedOccurrences.contains(occurrence), day != focusedDay { return false }
                    return seenEvents.insert(occurrence).inserted
                }
                return true
            }
            if !entries.isEmpty || (focusedDay != nil && (!dayRoutines.isEmpty || day == focusedDay)) {
                groups.append(Day(date: day, entries: entries, routines: focusedDay == nil ? [] : dayRoutines))
            }
        }
        days = groups
        routines = daily
    }

    static func remainingWeek(agenda: HomeAgenda, calendar: Calendar = .current) -> AgendaOverview {
        let end = AgendaWindow.week(containing: agenda.today, calendar: calendar).end
        return AgendaOverview(agenda: agenda, interval: DateInterval(start: agenda.today, end: end), calendar: calendar)
    }

    static func homeSubtitle(agenda: HomeAgenda, calendar: Calendar = .current) -> String {
        let week = remainingWeek(agenda: agenda, calendar: calendar)
        if week.count == 0 { return week.routines.isEmpty ? "本周剩余时间暂无安排" : "本周只有每日提醒" }
        let daily = week.routines.isEmpty ? "今天至周日" : "另有 \(week.routines.count) 项每日提醒"
        return "本周还有 \(week.count) 项 · \(daily)"
    }
}
