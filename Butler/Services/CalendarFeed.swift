import EventKit
import Foundation
import Observation

/// Read-only view of the owner's system calendars, shown on the home timeline when they turn it on.
@MainActor @Observable
final class CalendarFeed {
    private let store = EKEventStore()
    private(set) var events: [CalendarEventInfo] = []
    private(set) var status = EKEventStore.authorizationStatus(for: .event)
    /// The owner's choice in settings. Off until they turn it on.
    var enabled = UserDefaults.standard.bool(forKey: "showSystemCalendar") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "showSystemCalendar")
            Task { await refresh() }
        }
    }
    private var observer: NSObjectProtocol?
    /// How far ahead to read; the overview asks for a year.
    var horizonDays = 8
    /// A separately queried month keeps arbitrary history browsing bounded.
    var focusedDate = Date.now
    /// The overview can request a week, month or explicit date interval beyond the default horizon.
    var focusedInterval: DateInterval?
    private(set) var readIntervals: [DateInterval] = []

    init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    nonisolated deinit {}

    var canRead: Bool { status == .fullAccess }
    /// The owner said no (or a profile blocks calendars): only system settings can change it.
    var isBlocked: Bool { status == .denied || status == .restricted }

    func covers(_ interval: DateInterval) -> Bool {
        readIntervals.contains { $0.start <= interval.start && $0.end >= interval.end }
    }

    /// Asks for access when the owner turns the calendar on. Returns whether it can be read.
    @discardableResult
    func requestAccess() async -> Bool {
        if status == .notDetermined {
            _ = try? await store.requestFullAccessToEvents()
            status = EKEventStore.authorizationStatus(for: .event)
        }
        await refresh()
        return canRead
    }

    func refresh(from start: Date = Calendar.current.startOfDay(for: .now), days: Int? = nil) async {
        let days = days ?? horizonDays
        status = EKEventStore.authorizationStatus(for: .event)
        guard enabled, canRead, let end = Calendar.current.date(byAdding: .day, value: days, to: start) else {
            events = []
            readIntervals = []
            return
        }
        var intervals = [DateInterval(start: start, end: end)]
        if let month = Calendar.current.dateInterval(of: .month, for: focusedDate), month.start < start || month.end > end {
            intervals.append(month)
        }
        if let focusedInterval, !intervals.contains(where: { $0.start <= focusedInterval.start && $0.end >= focusedInterval.end }) {
            intervals.append(focusedInterval)
        }
        var seen = Set<String>()
        events = intervals.flatMap { interval in
            store.events(matching: store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil))
        }.filter { event in
            seen.insert("\(event.eventIdentifier ?? event.calendarItemIdentifier)|\(event.startDate.timeIntervalSince1970)").inserted
        }.map { event in
            CalendarEventInfo(id: event.eventIdentifier ?? event.calendarItemIdentifier, title: event.title ?? "日程",
                              location: event.location, calendarName: event.calendar?.title ?? "日历",
                              start: event.startDate, end: event.endDate, isAllDay: event.isAllDay)
        }
        readIntervals = intervals
    }
}
