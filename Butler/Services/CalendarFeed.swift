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

    init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    nonisolated deinit {}

    var canRead: Bool { status == .fullAccess }
    /// The owner said no (or a profile blocks calendars): only system settings can change it.
    var isBlocked: Bool { status == .denied || status == .restricted }

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
            return
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate).map { event in
            CalendarEventInfo(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "日程",
                              location: event.location, calendarName: event.calendar?.title ?? "日历",
                              start: event.startDate, end: event.endDate, isAllDay: event.isAllDay)
        }
    }
}
