import Foundation

/// One thing that happens on a day: food expiring, a reminder, a calendar event.
struct AgendaEntry: Identifiable, Hashable {
    enum Kind: Int, Comparable {
        case expired, expiring, lowStock, reminder, calendar
        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Target: Hashable {
        case lot(UUID)
        case reminder(UUID)
        case calendarEvent(String)
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String?
    /// Start of the day this entry belongs to.
    let day: Date
    /// nil = all day.
    let start: Date?
    let end: Date?
    let target: Target
    /// Happens every day (a daily reminder): shown once in lists and not dotted on every day.
    var isRoutine = false
    var isCompleted = false
    var arrangementReviewDate: Date? = nil
    var arrangementPeriod: ArrangementPeriod? = nil
    var timeLabel: String { arrangementPeriod?.label ?? start?.clockTime ?? "全天" }
    /// Original calendar occurrence, shared by its daily slices but not by other repeats.
    var calendarOccurrenceID: String? = nil
    var calendarSpan: DateInterval? = nil

    var isAllDay: Bool { start == nil }

    func isPending(at now: Date) -> Bool { kind == .reminder && !isCompleted && (arrangementReviewDate ?? start ?? day) <= now }
}

/// A system calendar event, already read from EventKit.
struct CalendarEventInfo: Hashable {
    let id: String
    let title: String
    let location: String?
    let calendarName: String
    let start: Date
    let end: Date
    let isAllDay: Bool
}

/// What the home screen shows: what needs handling now, and the week day by day.
struct HomeAgenda {
    let today: Date
    let days: [Date]
    /// Expired food and things that ran low — handled from the top of home, not tied to a day.
    let needsAttention: [AgendaEntry]
    /// Items that still need a date or a compartment (shown as one summary row).
    let missingInfoCount: Int
    private let byDay: [Date: [AgendaEntry]]

    func entries(on day: Date) -> [AgendaEntry] { byDay[day] ?? [] }

    /// Due tasks stay visible until their lifecycle changes, even outside the
    /// compact hour window. Repeated notifications represent one unfinished task.
    func pending(on day: Date, at now: Date) -> [AgendaEntry] {
        var seen = Set<AgendaEntry.Target>()
        return entries(on: day).filter {
            $0.isPending(at: now) && seen.insert($0.target).inserted
        }
    }

    func completed(on day: Date) -> [AgendaEntry] {
        entries(on: day).filter(\.isCompleted)
    }

    /// Everything after `day` in the week, with each daily routine only at its next occurrence.
    func upcoming(after day: Date) -> [AgendaEntry] {
        var seen = Set<AgendaEntry.Target>()
        return days.filter { $0 > day }.flatMap { entries(on: $0) }.filter { entry in
            guard !entry.isCompleted else { return false }
            guard entry.isRoutine else { return true }
            return seen.insert(entry.target).inserted && !entries(on: day).contains { $0.target == entry.target }
        }
    }

    /// Kinds present on a day, for the dots under the week strip (at most three, most urgent first).
    func dots(on day: Date) -> [AgendaEntry.Kind] {
        var kinds = Array(Set(entries(on: day).filter { !$0.isRoutine }.map(\.kind))).sorted()
        if day == today, needsAttention.contains(where: { $0.kind == .expired }), !kinds.contains(.expired) {
            kinds.insert(.expired, at: 0)
        }
        if day == today, needsAttention.contains(where: { $0.kind == .lowStock }), !kinds.contains(.lowStock) {
            kinds.append(.lowStock)
        }
        return Array(kinds.sorted().prefix(3))
    }

    static func build(lots: [LotFacts], reminders: [TimedReminder], events: [CalendarEventInfo],
                      now: Date = .now, dayCount: Int = 7, calendar: Calendar = .current, additionalDays: [Date] = [],
                      household: HouseholdNames = .none) -> HomeAgenda {
        let today = calendar.startOfDay(for: now)
        let days = (0..<dayCount).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        let displayedDays = Array(Set(days + additionalDays.map { calendar.startOfDay(for: $0) })).sorted()
        let lastDay = displayedDays.last ?? today
        var byDay: [Date: [AgendaEntry]] = [:]
        var attention: [AgendaEntry] = []

        for lot in lots {
            let amount = "\(lot.quantity) \(lot.unit)"
            let place = lot.storageLocation.map { " · \($0)" } ?? ""
            if lot.isRunningLow {
                attention.append(AgendaEntry(id: "low-\(lot.id)", kind: .lowStock, title: lot.name,
                                             subtitle: "只剩 \(amount)\(place)", day: today, start: nil, end: nil,
                                             target: .lot(lot.id)))
                continue
            }
            guard let date = lot.governingDate, let daysLeft = lot.daysLeft else { continue }
            if daysLeft < 0 {
                attention.append(AgendaEntry(id: "expired-\(lot.id)", kind: .expired, title: lot.name,
                                             subtitle: "\(lot.dateStatusLabel)\(place) · \(amount)", day: today,
                                             start: nil, end: nil, target: .lot(lot.id)))
                continue
            }
            let day = calendar.startOfDay(for: date)
            guard day <= lastDay else { continue }
            let planned = lot.governingDateKind == .plannedUseBy
            let title = planned ? "\(lot.name)该吃完了" : (daysLeft == 0 ? "\(lot.name)今天到期" : "\(lot.name)到期")
            byDay[day, default: []].append(AgendaEntry(
                id: "due-\(lot.id)", kind: daysLeft == 0 ? .expired : .expiring, title: title,
                subtitle: "\(amount) · \(lot.dateKindLabel) \(date.monthDay)", day: day, start: nil, end: nil,
                target: .lot(lot.id)))
        }

        // Completion is a retained record, not another notification occurrence.
        // A one-off stays at its planned time. Cross-day completion also appears
        // on the day it was actually done. Repeating tasks finish once, not once
        // for every historical notification or on all future scheduled dates.
        for reminder in reminders where reminder.status == .completed {
            let completion = reminder.activity.last(where: { $0.kind == "completed" || $0.kind == "autoCompleted" })?.date
            let finished = completion ?? reminder.autoCompleteAt ?? reminder.fireDate
            let once = reminder.repeats == .none && reminder.phases == nil
            let scheduled = once && reminder.fireDate <= finished ? reminder.fireDate : finished
            var dates = [scheduled]
            if !calendar.isDate(scheduled, inSameDayAs: finished) { dates.append(finished) }
            for date in dates {
                let day = calendar.startOfDay(for: date)
                guard day <= today else { continue }
                let who = household.completedBy(reminder).map { " · \($0)" } ?? ""
                let detail = (completion.map { "已完成 · \($0.monthDay) \($0.clockTime) 完成" } ?? "已完成") + who
                byDay[day, default: []].append(AgendaEntry(
                    id: "completed-\(reminder.id)-\(date.timeIntervalSince1970)", kind: .reminder,
                    title: reminder.text, subtitle: detail, day: day, start: reminder.timePeriod == nil ? date : nil,
                    end: date.addingTimeInterval(30 * 60), target: .reminder(reminder.id), isCompleted: true))
            }
        }

        for reminder in reminders where reminder.status == .active {
            // An exhausted reminder schedule does not complete its task. Carry
            // older unfinished tasks onto today without inventing another alert.
            if reminder.fireDate < today,
               ReminderSchedule.preview(reminder, now: today.addingTimeInterval(-0.001), limit: 1).isEmpty {
                byDay[today, default: []].append(AgendaEntry(
                    id: "pending-\(reminder.id)", kind: .reminder, title: reminder.text,
                    subtitle: ["\(reminder.fireDate.monthDay) 的任务 · 尚未完成", household.rowLabel(reminder.sharing)]
                        .compactMap { $0 }.joined(separator: " · "), day: today, start: nil, end: nil,
                    target: .reminder(reminder.id)))
            }
            if let period = reminder.timePeriod {
                let day = calendar.startOfDay(for: reminder.fireDate)
                if day <= lastDay {
                    byDay[day, default: []].append(AgendaEntry(
                        id: "arrangement-\(reminder.id)", kind: .reminder, title: reminder.text,
                        subtitle: [period.label, household.rowLabel(reminder.sharing)].compactMap { $0 }.joined(separator: " · "),
                        day: day, start: nil, end: nil, target: .reminder(reminder.id),
                        arrangementReviewDate: reminder.arrangementReviewDate, arrangementPeriod: period))
                }
                continue
            }
            var taskDays = displayedDays
            if reminder.repeats == .none && reminder.phases == nil && reminder.fireDate < today {
                taskDays = Array(Set(taskDays + [calendar.startOfDay(for: reminder.fireDate)])).sorted()
            }
            for day in taskDays {
                for start in ReminderSchedule.occurrences(reminder, on: day, calendar: calendar) {
                    let repeatLabel: String?
                    if reminder.phases != nil { repeatLabel = reminder.whenLabel }
                    else {
                        repeatLabel = switch reminder.repeats {
                        case .daily: "每天重复"
                        case .weekly: "每周重复"
                        case .none: nil
                        }
                    }
                    let labels = [repeatLabel, household.rowLabel(reminder.sharing)].compactMap { $0 }
                    byDay[day, default: []].append(AgendaEntry(
                        id: "reminder-\(reminder.id)-\(start.timeIntervalSince1970)", kind: .reminder, title: reminder.text,
                        subtitle: labels.isEmpty ? nil : labels.joined(separator: " · "), day: day, start: start, end: start.addingTimeInterval(30 * 60),
                        target: .reminder(reminder.id), isRoutine: reminder.repeats == .daily && reminder.phases == nil))
                }
            }
        }

        for event in events {
            for day in displayedDays {
                guard let next = calendar.date(byAdding: .day, value: 1, to: day),
                      event.start < next, event.end > day || (event.end == event.start && event.start >= day) else { continue }
                let subtitle = [event.calendarName, event.location].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                byDay[day, default: []].append(AgendaEntry(
                    id: "event-\(event.id)-\(event.start.timeIntervalSince1970)-\(day.timeIntervalSince1970)", kind: .calendar, title: event.title,
                    subtitle: subtitle.isEmpty ? nil : subtitle, day: day,
                    start: event.isAllDay ? nil : max(event.start, day), end: event.isAllDay ? nil : min(event.end, next),
                    target: .calendarEvent(event.id),
                    calendarOccurrenceID: "\(event.id)|\(event.start.timeIntervalSince1970)",
                    calendarSpan: DateInterval(start: event.start, end: max(event.start, event.end))))
            }
        }

        for day in byDay.keys {
            byDay[day]?.sort { lhs, rhs in
                switch (lhs.start, rhs.start) {
                case let (l?, r?): return l < r
                case (nil, _?): return true
                case (_?, nil): return false
                case (nil, nil): return lhs.kind < rhs.kind
                }
            }
        }
        attention.sort { $0.kind < $1.kind }
        let missing = lots.filter { $0.needsDate || $0.needsCompartment }.count
        return HomeAgenda(today: today, days: days, needsAttention: attention, missingInfoCount: missing, byDay: byDay)
    }

    /// Only the browsed month and its adjacent week are calculated, even when jumping years away.
    static func browsingDays(around date: Date, calendar: Calendar = .current) -> [Date] {
        guard let month = calendar.dateInterval(of: .month, for: date),
              let start = calendar.date(byAdding: .day, value: -7, to: month.start),
              let end = calendar.date(byAdding: .day, value: 7, to: month.end) else { return [] }
        let count = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// When a reminder fires on `day`, if it does.
    static func occurrence(of reminder: TimedReminder, on day: Date, calendar: Calendar) -> Date? {
        ReminderSchedule.occurrences(reminder, on: day, calendar: calendar).first
    }
}
