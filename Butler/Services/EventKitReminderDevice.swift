import CryptoKit
import EventKit
import Foundation

@MainActor final class EventKitReminderDevice: AppleReminderDevice {
    private let store = EKEventStore()
    private var prepared: [String: EKReminder] = [:]
    var authorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    var authorization: String {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: "authorized"
        case .notDetermined: "not_determined"
        case .denied: "denied"
        case .restricted: "restricted"
        default: "unavailable"
        }
    }

    func authorize() async throws -> Bool {
        if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
            _ = try await store.requestFullAccessToReminders()
        }
        return authorized
    }

    private func requireAccess() throws {
        guard authorized else { throw AppleReminderFailure("苹果提醒事项访问未获准或已撤销") }
    }

    func lists() throws -> [AppleReminderList] {
        try requireAccess()
        return store.calendars(for: .reminder).map(list).sorted { $0.id < $1.id }
    }

    private func list(_ calendar: EKCalendar) -> AppleReminderList {
        AppleReminderList(id: calendar.calendarIdentifier, title: calendar.title,
                          source: calendar.source.title, writable: calendar.allowsContentModifications,
                          isDefault: calendar.calendarIdentifier == store.defaultCalendarForNewReminders()?.calendarIdentifier)
    }

    private func calendar(_ id: String) throws -> EKCalendar {
        try requireAccess()
        guard let calendar = store.calendar(withIdentifier: id), calendar.allowedEntityTypes.contains(.reminder) else {
            throw AppleReminderFailure("找不到这个提醒事项列表")
        }
        return calendar
    }

    func reminders(listID: String?) async throws -> [AppleReminderSnapshot] {
        try requireAccess()
        store.reset()
        let calendars = try listID.map { [try calendar($0)] }
        let predicate = store.predicateForReminders(in: calendars)
        let result: [EKReminder]? = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        try requireAccess()
        guard let result else { throw AppleReminderFailure("系统读取提醒事项失败，不能把失败当作空列表") }
        return try result.map(snapshot).sorted { $0.id < $1.id }
    }

    func reminder(id: String) throws -> AppleReminderSnapshot? {
        try requireAccess()
        store.reset()
        return try (store.calendarItem(withIdentifier: id) as? EKReminder).map(snapshot)
    }

    func prepare(listID: String, fields: AppleReminderFields) throws -> String {
        try fields.validate()
        let calendar = try calendar(listID)
        guard calendar.allowsContentModifications else { throw AppleReminderFailure("目标列表为只读") }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = fields.title
        reminder.notes = fields.notes
        reminder.priority = fields.priority
        try setSchedule(fields, on: reminder)
        // Apple documents calendarItemIdentifier as assigned at creation, before saving.
        let id = reminder.calendarItemIdentifier
        prepared[id] = reminder
        return id
    }

    func savePrepared(id: String) throws {
        try requireAccess()
        guard let reminder = prepared[id], reminder.calendar.allowsContentModifications else {
            throw AppleReminderFailure("待保存对象或可写列表已失效")
        }
        try store.save(reminder, commit: true)
    }

    func discardPrepared(id: String) { prepared[id] = nil }

    func edit(before: AppleReminderSnapshot, patch: AppleReminderPatch) throws {
        try requireAccess()
        store.reset()
        guard let reminder = store.calendarItem(withIdentifier: before.id) as? EKReminder,
              try snapshot(reminder).revision == before.revision, reminder.calendar.allowsContentModifications else {
            throw AppleReminderFailure("系统对象在执行前已变化或不可写，请重新查询")
        }
        switch patch {
        case .title(let title): reminder.title = title
        case .notes(let notes): reminder.notes = notes
        case .priority(let priority): reminder.priority = priority
        case .completed(let completed): reminder.isCompleted = completed
        case .schedule: try setSchedule(patch.fields(after: before.fields), on: reminder)
        case .delete:
            try store.remove(reminder, commit: true)
            return
        }
        try store.save(reminder, commit: true)
    }

    private func setSchedule(_ fields: AppleReminderFields, on reminder: EKReminder) throws {
        try fields.validate()
        reminder.timeZone = fields.due?.timeZone.flatMap(TimeZone.init(identifier:))
        reminder.dueDateComponents = fields.due?.components
        // Relative alarms use the start date; keep it equal to the deadline/recurrence anchor.
        reminder.startDateComponents = fields.recurrence != nil || fields.notifyAtDue ? fields.due?.components : nil
        reminder.recurrenceRules = nil
        if let rule = fields.recurrence {
            let frequency: EKRecurrenceFrequency
            switch rule.frequency {
            case .daily: frequency = .daily
            case .weekly: frequency = .weekly
            case .monthly: frequency = .monthly
            case .yearly: frequency = .yearly
            }
            let weekdays: [EKWeekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
            reminder.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: frequency, interval: rule.interval,
                daysOfTheWeek: rule.weekdays.isEmpty ? nil : rule.weekdays.sorted().map { EKRecurrenceDayOfWeek(weekdays[$0 - 1]) },
                daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil))
        }
        reminder.alarms = nil
        if fields.notifyAtDue { reminder.addAlarm(EKAlarm(relativeOffset: 0)) }
    }

    private func due(_ components: DateComponents?, zone: TimeZone?) -> AppleReminderDue? {
        guard let c = components, c.calendar == nil || c.calendar?.identifier == .gregorian,
              let year = c.year, let month = c.month, let day = c.day else { return nil }
        let value = AppleReminderDue(year: year, month: month, day: day, hour: c.hour, minute: c.hour == nil ? nil : (c.minute ?? 0),
                                    timeZone: c.hour == nil ? nil : (c.timeZone ?? zone)?.identifier)
        return (try? value.date()) == nil ? nil : value
    }

    private func recurrence(_ rules: [EKRecurrenceRule]) -> AppleReminderRecurrence? {
        guard rules.count == 1, let r = rules.first, r.recurrenceEnd == nil,
              [r.daysOfTheMonth, r.monthsOfTheYear, r.weeksOfTheYear, r.daysOfTheYear, r.setPositions].allSatisfy({ $0?.isEmpty ?? true }),
              (r.daysOfTheWeek ?? []).allSatisfy({ $0.weekNumber == 0 }) else { return nil }
        let frequency: AppleReminderRecurrence.Frequency
        switch r.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        @unknown default: return nil
        }
        let result = AppleReminderRecurrence(frequency: frequency, interval: r.interval,
                                            weekdays: (r.daysOfTheWeek ?? []).map { ($0.dayOfTheWeek.rawValue + 5) % 7 + 1 }.sorted())
        return (try? result.validate()) == nil ? nil : result
    }

    private func snapshot(_ reminder: EKReminder) throws -> AppleReminderSnapshot {
        let due = due(reminder.dueDateComponents, zone: reminder.timeZone)
        let rules = reminder.recurrenceRules ?? []
        let recurrence = recurrence(rules)
        let alarms = reminder.alarms ?? []
        let notify = alarms.count == 1 && alarms[0].structuredLocation == nil && alarms[0].proximity == .none
            && ((alarms[0].absoluteDate == nil && alarms[0].relativeOffset == 0)
                || (due?.hour != nil && alarms[0].absoluteDate == (try? due?.date())))
        let simpleStart = reminder.startDateComponents == nil || reminder.startDateComponents == reminder.dueDateComponents
        let editable = simpleStart && (reminder.dueDateComponents == nil || due != nil)
            && (rules.isEmpty || recurrence != nil) && (alarms.isEmpty || (notify && due?.hour != nil))
            && (reminder.dueDateComponents?.second ?? 0) == 0
        let fields = AppleReminderFields(title: reminder.title ?? "", notes: reminder.notes, due: due,
                                         priority: reminder.priority, recurrence: recurrence, notifyAtDue: notify)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let schedule: [String: Any] = [
            "due": String(decoding: try encoder.encode(reminder.dueDateComponents), as: UTF8.self),
            "start": String(decoding: try encoder.encode(reminder.startDateComponents), as: UTF8.self),
            "time_zone": reminder.timeZone?.identifier as Any? ?? NSNull(),
            "rules": rules.map { r -> [String: Any] in
                ["frequency": r.frequency.rawValue, "interval": r.interval, "calendar": r.calendarIdentifier,
                 "week_start": r.firstDayOfTheWeek, "weekdays": (r.daysOfTheWeek ?? []).map { [$0.dayOfTheWeek.rawValue, $0.weekNumber] },
                 "month_days": r.daysOfTheMonth ?? [], "months": r.monthsOfTheYear ?? [], "weeks": r.weeksOfTheYear ?? [],
                 "year_days": r.daysOfTheYear ?? [], "positions": r.setPositions ?? [],
                 "end": r.recurrenceEnd?.endDate?.timeIntervalSince1970 as Any? ?? NSNull(),
                 "count": r.recurrenceEnd?.occurrenceCount as Any? ?? NSNull()]
            },
            "alarms": alarms.map { alarm -> [String: Any] in
                ["at": alarm.absoluteDate?.timeIntervalSince1970 as Any? ?? NSNull(), "offset": alarm.relativeOffset,
                 "proximity": alarm.proximity.rawValue, "location": alarm.structuredLocation?.title as Any? ?? NSNull(),
                 "latitude": alarm.structuredLocation?.geoLocation?.coordinate.latitude as Any? ?? NSNull(),
                 "longitude": alarm.structuredLocation?.geoLocation?.coordinate.longitude as Any? ?? NSNull(),
                 "radius": alarm.structuredLocation?.radius as Any? ?? NSNull()]
            }
        ]
        let raw: [String: Any] = ["id": reminder.calendarItemIdentifier, "list": reminder.calendar.calendarIdentifier,
            "source": reminder.calendar.source.sourceIdentifier, "list_title": reminder.calendar.title,
            "title": reminder.title ?? "", "notes": reminder.notes as Any? ?? NSNull(), "priority": reminder.priority,
            "completed": reminder.isCompleted, "schedule": schedule, "url": reminder.url?.absoluteString as Any? ?? NSNull(),
            "location": reminder.location as Any? ?? NSNull(), "modified": reminder.lastModifiedDate?.timeIntervalSince1970 as Any? ?? NSNull()]
        let revision = SHA256.hash(data: try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])).map { String(format: "%02x", $0) }.joined()
        return AppleReminderSnapshot(id: reminder.calendarItemIdentifier, list: list(reminder.calendar), fields: fields,
            completed: reminder.isCompleted, revision: revision, scheduleEditable: editable,
            scheduleDescription: editable ? fields.scheduleSummary : "保留复杂系统安排，不支持改期：" + String(decoding: try JSONSerialization.data(withJSONObject: schedule, options: [.sortedKeys]), as: UTF8.self))
    }
}

extension AppleReminderStore {
    static let shared: AppleReminderStore = {
        let directory = URL.applicationSupportDirectory.appendingPathComponent("DeviceAppleReminders", isDirectory: true)
        var preparationError: String?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
        } catch { preparationError = "无法建立仅限本设备的操作记录：\(error.localizedDescription)" }
        return AppleReminderStore(file: directory.appendingPathComponent("operations.json"), device: EventKitReminderDevice(), preparationError: preparationError)
    }()
}
