import Foundation

struct CalendarFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct SystemCalendarList: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let source: String
    let writable: Bool
}

/// Recurring instances share an item ID; the original start distinguishes occurrences.
struct CalendarEventKey: Codable, Equatable, Sendable {
    let itemID: String
    let start: Date
}

struct CalendarEventFields: Codable, Equatable, Sendable {
    var title: String
    var location: String?
    var notes: String?
    var start: Date
    /// Exclusive end, including all-day events.
    var end: Date
    var timeZone: String
    var allDay: Bool
    var alertMinutes: Int?

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 300,
              (notes?.count ?? 0) <= 10_000, (location?.count ?? 0) <= 1000,
              let zone = TimeZone(identifier: timeZone), end > start,
              alertMinutes.map({ (0...40320).contains($0) }) ?? true else {
            throw CalendarFailure("日历标题、起止时间、时区或通知提前量无效")
        }
        if allDay {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            guard calendar.startOfDay(for: start) == start, calendar.startOfDay(for: end) == end else {
                throw CalendarFailure("全天事件须使用指定时区的零点，结束日期不包含在事件内")
            }
        }
    }

    var summary: String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: timeZone)
        formatter.dateFormat = allDay ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
        return "\(formatter.string(from: start)) → \(formatter.string(from: end))（\(timeZone)\(allDay ? "，全天，结束日不含" : "")）\n地点：\(location ?? "无")；"
            + (alertMinutes.map { "提前\($0)分钟通知" } ?? "不添加通知（系统默认偏好仍可能生效）")
    }
}

enum CalendarEventSpan: String, Codable, Sendable {
    case thisEvent, futureEvents
    var summary: String { self == .thisEvent ? "仅这一次" : "这次及以后所有重复事件" }
}

struct SystemCalendarEvent: Codable, Equatable, Sendable {
    let key: CalendarEventKey
    let calendar: SystemCalendarList
    let fields: CalendarEventFields
    let revision: String
    let recurring: Bool
    let recurrenceDescription: String
    /// Invitations/attendees are deliberately not editable through these tools.
    let editable: Bool
    let scheduleEditable: Bool
}

enum CalendarEventPatch: Codable, Equatable, Sendable {
    case title(String), notes(String?), location(String?)
    case schedule(start: Date, end: Date, timeZone: String, allDay: Bool, alertMinutes: Int?)
    case delete

    func fields(after old: CalendarEventFields) -> CalendarEventFields {
        var fields = old
        switch self {
        case .title(let value): fields.title = value
        case .notes(let value): fields.notes = value
        case .location(let value): fields.location = value
        case .schedule(let start, let end, let zone, let allDay, let alert):
            fields.start = start; fields.end = end; fields.timeZone = zone; fields.allDay = allDay; fields.alertMinutes = alert
        case .delete: break
        }
        return fields
    }
}

enum SystemCalendarChange: Codable, Equatable, Sendable {
    case access(Bool)
    /// Basic repetition only; editing retains the native recurrence rather than replacing it.
    case create(calendar: SystemCalendarList, fields: CalendarEventFields, frequency: String?)
    case edit(before: SystemCalendarEvent, patch: CalendarEventPatch, span: CalendarEventSpan)
}

@MainActor protocol SystemCalendarDevice {
    var authorized: Bool { get }
    func authorize() async throws -> Bool
    func calendars() throws -> [SystemCalendarList]
    func events(start: Date, end: Date, calendarID: String?) throws -> [SystemCalendarEvent]
    func event(_ key: CalendarEventKey) throws -> SystemCalendarEvent?
    func prepare(calendarID: String, fields: CalendarEventFields, frequency: String?) throws -> CalendarEventKey
    func savePrepared(_ key: CalendarEventKey) throws -> CalendarEventKey
    func discardPrepared(_ key: CalendarEventKey)
    func edit(_ before: SystemCalendarEvent, patch: CalendarEventPatch, span: CalendarEventSpan) throws -> CalendarEventKey?
}
