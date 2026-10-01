import CryptoKit
import EventKit
import Foundation

@MainActor final class EventKitCalendarDevice: SystemCalendarDevice {
    private let store = EKEventStore()
    private var prepared: [String: EKEvent] = [:]
    var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func authorize() async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined || status == .writeOnly { _ = try await store.requestFullAccessToEvents() }
        return authorized
    }
    private func requireAccess() throws {
        guard authorized else { throw CalendarFailure("系统日历权限未获准或已撤销") }
    }
    private func list(_ calendar: EKCalendar) -> SystemCalendarList {
        .init(id: calendar.calendarIdentifier, title: calendar.title,
              source: calendar.source.title + " [" + calendar.source.sourceIdentifier + "]", writable: calendar.allowsContentModifications)
    }
    func calendars() throws -> [SystemCalendarList] {
        try requireAccess(); store.reset()
        return store.calendars(for: .event).map(list).sorted { $0.id < $1.id }
    }
    private func calendar(_ id: String) throws -> EKCalendar {
        guard let calendar = store.calendar(withIdentifier: id), calendar.allowedEntityTypes.contains(.event) else {
            throw CalendarFailure("目标日历已不存在")
        }
        return calendar
    }
    func events(start: Date, end: Date, calendarID: String?) throws -> [SystemCalendarEvent] {
        try requireAccess(); store.reset()
        let calendars = try calendarID.map { [try calendar($0)] }
        return try store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars))
            .map(snapshot).sorted { $0.key.start == $1.key.start ? $0.key.itemID < $1.key.itemID : $0.key.start < $1.key.start }
    }
    private func native(_ key: CalendarEventKey) throws -> EKEvent? {
        try requireAccess(); store.reset()
        let matches = store.events(matching: store.predicateForEvents(withStart: key.start.addingTimeInterval(-1),
            end: key.start.addingTimeInterval(1), calendars: nil)).filter {
                $0.calendarItemIdentifier == key.itemID && $0.startDate == key.start
            }
        guard matches.count <= 1 else { throw CalendarFailure("事件标识对应多个实例，停止操作，请重新查询") }
        return matches.first
    }
    func event(_ key: CalendarEventKey) throws -> SystemCalendarEvent? { try native(key).map(snapshot) }

    func prepare(calendarID: String, fields: CalendarEventFields, frequency: String?) throws -> CalendarEventKey {
        try requireAccess(); try fields.validate()
        let target = try calendar(calendarID)
        guard target.allowsContentModifications else { throw CalendarFailure("日历只读") }
        let event = EKEvent(eventStore: store); event.calendar = target
        event.title = fields.title; event.notes = fields.notes; event.location = fields.location
        schedule(fields, event: event)
        if let frequency {
            let native: EKRecurrenceFrequency
            switch frequency {
            case "daily": native = .daily
            case "weekly": native = .weekly
            case "monthly": native = .monthly
            case "yearly": native = .yearly
            default: throw CalendarFailure("不支持该重复规则")
            }
            event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: native, interval: 1, end: nil))
        }
        let key = key(event); prepared[key.itemID] = event; return key
    }
    func savePrepared(_ key: CalendarEventKey) throws -> CalendarEventKey {
        try requireAccess()
        guard let event = prepared[key.itemID], event.calendar.allowsContentModifications else { throw CalendarFailure("待写入事件已失效") }
        try store.save(event, span: .thisEvent, commit: true)
        return self.key(event)
    }
    func discardPrepared(_ key: CalendarEventKey) { prepared[key.itemID] = nil }

    func edit(_ before: SystemCalendarEvent, patch: CalendarEventPatch, span: CalendarEventSpan) throws -> CalendarEventKey? {
        guard let event = try native(before.key), try snapshot(event).revision == before.revision,
              event.calendar.allowsContentModifications, !event.hasAttendees, event.organizer == nil else {
            throw CalendarFailure("事件在执行前已变化、只读或含邀请，未写入")
        }
        let nativeSpan: EKSpan = span == .thisEvent ? .thisEvent : .futureEvents
        switch patch {
        case .delete: try store.remove(event, span: nativeSpan, commit: true); return nil
        case .title(let title): event.title = title
        case .notes(let notes): event.notes = notes
        case .location(let location): event.location = location; event.structuredLocation = nil
        case .schedule: schedule(patch.fields(after: before.fields), event: event)
        }
        try store.save(event, span: nativeSpan, commit: true)
        return key(event)
    }
    private func key(_ event: EKEvent) -> CalendarEventKey { .init(itemID: event.calendarItemIdentifier, start: event.startDate) }
    private func schedule(_ fields: CalendarEventFields, event: EKEvent) {
        event.timeZone = TimeZone(identifier: fields.timeZone); event.isAllDay = fields.allDay
        event.startDate = fields.start; event.endDate = fields.end
        event.alarms = nil
        if let minutes = fields.alertMinutes { event.addAlarm(EKAlarm(relativeOffset: -Double(minutes) * 60)) }
    }

    private func snapshot(_ event: EKEvent) throws -> SystemCalendarEvent {
        let alarms = event.alarms ?? []
        let simpleAlarm = alarms.count == 1 && alarms[0].absoluteDate == nil && alarms[0].structuredLocation == nil
            && alarms[0].proximity == .none && alarms[0].relativeOffset <= 0 && alarms[0].relativeOffset >= -40320 * 60
            && alarms[0].relativeOffset.truncatingRemainder(dividingBy: 60) == 0
        let fields = CalendarEventFields(title: event.title ?? "", location: event.location, notes: event.notes,
            start: event.startDate, end: event.endDate, timeZone: (event.timeZone ?? .current).identifier,
            allDay: event.isAllDay, alertMinutes: simpleAlarm ? Int(-alarms[0].relativeOffset / 60) : nil)
        let rules = event.recurrenceRules ?? []
        let ruleJSON: [[String: Any]] = rules.map { r in
            ["frequency": r.frequency.rawValue, "interval": r.interval, "calendar": r.calendarIdentifier,
             "week_start": r.firstDayOfTheWeek, "weekdays": (r.daysOfTheWeek ?? []).map { [$0.dayOfTheWeek.rawValue, $0.weekNumber] },
             "month_days": r.daysOfTheMonth ?? [], "months": r.monthsOfTheYear ?? [], "weeks": r.weeksOfTheYear ?? [],
             "year_days": r.daysOfTheYear ?? [], "positions": r.setPositions ?? [],
             "end": r.recurrenceEnd?.endDate?.timeIntervalSince1970 as Any? ?? NSNull(),
             "count": r.recurrenceEnd?.occurrenceCount as Any? ?? NSNull()]
        }
        var recurrence = "none"
        if let r = rules.first {
            recurrence = String(decoding: try JSONSerialization.data(withJSONObject: ruleJSON, options: [.sortedKeys]), as: UTF8.self)
            if rules.count == 1, r.interval == 1, r.recurrenceEnd == nil,
               (r.daysOfTheWeek ?? []).isEmpty,
               [r.daysOfTheMonth, r.monthsOfTheYear, r.weeksOfTheYear, r.daysOfTheYear, r.setPositions].allSatisfy({ $0?.isEmpty ?? true }) {
                switch r.frequency {
                case .daily: recurrence = "daily"
                case .weekly: recurrence = "weekly"
                case .monthly: recurrence = "monthly"
                case .yearly: recurrence = "yearly"
                @unknown default: break
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let raw: [String: Any] = ["fields": String(decoding: try encoder.encode(fields), as: UTF8.self),
            "calendar": String(decoding: try encoder.encode(list(event.calendar)), as: UTF8.self),
            "rules": ruleJSON, "detached": event.isDetached, "status": event.status.rawValue,
            "attendees": (event.attendees ?? []).map { "\($0.url.absoluteString):\($0.participantStatus.rawValue)" },
            "organizer": event.organizer?.url.absoluteString as Any? ?? NSNull(),
            "modified": event.lastModifiedDate?.timeIntervalSince1970 as Any? ?? NSNull(),
            "url": event.url?.absoluteString as Any? ?? NSNull(),
            "latitude": event.structuredLocation?.geoLocation?.coordinate.latitude as Any? ?? NSNull(),
            "longitude": event.structuredLocation?.geoLocation?.coordinate.longitude as Any? ?? NSNull(),
            "alarms": alarms.map { a -> [String: Any] in
                ["absolute": a.absoluteDate?.timeIntervalSince1970 as Any? ?? NSNull(), "offset": a.relativeOffset,
                 "proximity": a.proximity.rawValue, "location": a.structuredLocation?.title as Any? ?? NSNull(),
                 "latitude": a.structuredLocation?.geoLocation?.coordinate.latitude as Any? ?? NSNull(),
                 "longitude": a.structuredLocation?.geoLocation?.coordinate.longitude as Any? ?? NSNull(),
                 "radius": a.structuredLocation?.radius as Any? ?? NSNull()]
            }]
        let revision = SHA256.hash(data: try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])).map { String(format: "%02x", $0) }.joined()
        return SystemCalendarEvent(key: key(event), calendar: list(event.calendar), fields: fields, revision: revision,
            recurring: !rules.isEmpty || event.isDetached, recurrenceDescription: recurrence,
            editable: event.calendar.allowsContentModifications && !event.hasAttendees && event.organizer == nil && event.status != .canceled,
            scheduleEditable: (alarms.isEmpty || simpleAlarm) && event.structuredLocation == nil && event.timeZone != nil)
    }
}

extension SystemCalendarStore {
    static let shared: SystemCalendarStore = {
        let directory = URL.applicationSupportDirectory.appendingPathComponent("DeviceCalendar", isDirectory: true)
        var errorMessage: String?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
        } catch { errorMessage = "无法建立仅限本设备的日历操作记录：\(error.localizedDescription)" }
        return SystemCalendarStore(file: directory.appendingPathComponent("operations.json"), device: EventKitCalendarDevice(), preparationError: errorMessage)
    }()
}
