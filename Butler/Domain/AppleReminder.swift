import Foundation

struct AppleReminderFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct AppleReminderList: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let source: String
    let writable: Bool
    let isDefault: Bool
}

/// A date-only deadline is not midnight and must not gain a notification implicitly.
struct AppleReminderDue: Codable, Equatable, Sendable {
    let year: Int
    let month: Int
    let day: Int
    var hour: Int? = nil
    var minute: Int? = nil
    var timeZone: String? = nil

    var components: DateComponents {
        var value = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        value.calendar = Calendar(identifier: .gregorian)
        value.timeZone = timeZone.flatMap(TimeZone.init(identifier:))
        return value
    }

    func date() throws -> Date {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              (hour == nil) == (minute == nil),
              hour.map({ (0...23).contains($0) }) ?? true,
              minute.map({ (0...59).contains($0) }) ?? true,
              hour == nil ? timeZone == nil : timeZone.flatMap(TimeZone.init(identifier:)) != nil else {
            throw AppleReminderFailure("截止日期或时区无效；只有日期与具体时间不能混用")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: components) else { throw AppleReminderFailure("截止日期无效") }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard actual.year == year, actual.month == month, actual.day == day,
              hour == nil || (actual.hour == hour && actual.minute == minute) else {
            throw AppleReminderFailure("这个日期或当地时间不存在（可能遇到夏令时跳时），请重新确认")
        }
        return date
    }

    var summary: String {
        let day = String(format: "%04d-%02d-%02d", year, month, day)
        guard let hour, let minute else { return day + "（仅日期）" }
        return day + String(format: " %02d:%02d", hour, minute) + " " + (timeZone ?? "")
    }
}

struct AppleReminderRecurrence: Codable, Equatable, Sendable {
    enum Frequency: String, Codable, Sendable { case daily, weekly, monthly, yearly }
    let frequency: Frequency
    let interval: Int
    /// ISO Monday 1 ... Sunday 7. Empty means the due date's weekday.
    var weekdays: [Int] = []

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.frequency == rhs.frequency && lhs.interval == rhs.interval && lhs.weekdays.sorted() == rhs.weekdays.sorted()
    }

    func validate() throws {
        guard (1...365).contains(interval), Set(weekdays).count == weekdays.count,
              weekdays.allSatisfy({ (1...7).contains($0) }),
              frequency == .weekly || weekdays.isEmpty else {
            throw AppleReminderFailure("重复规则需要有效间隔；指定星期仅适用于每周重复")
        }
    }

    var summary: String {
        let unit: String
        switch frequency { case .daily: unit = "天"; case .weekly: unit = "周"; case .monthly: unit = "月"; case .yearly: unit = "年" }
        let names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        return "每 \(interval) \(unit)" + (weekdays.isEmpty ? "" : "，" + weekdays.sorted().compactMap { (1...7).contains($0) ? names[$0 - 1] : nil }.joined(separator: "、"))
    }
}

struct AppleReminderFields: Codable, Equatable, Sendable {
    var title: String
    var notes: String?
    var due: AppleReminderDue?
    var priority: Int = 0
    var recurrence: AppleReminderRecurrence?
    var notifyAtDue: Bool = false

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 300,
              (notes?.count ?? 0) <= 10_000, (0...9).contains(priority) else {
            throw AppleReminderFailure("标题须为1–300字、备注不超过10000字、优先级为0–9")
        }
        if let due { _ = try due.date() }
        if let recurrence {
            try recurrence.validate()
            guard due != nil else { throw AppleReminderFailure("重复提醒需要明确首次截止日期") }
        }
        if notifyAtDue, due?.hour == nil { throw AppleReminderFailure("到点通知需要明确时分；只有日期不会自动设置午夜通知") }
    }

    var scheduleSummary: String {
        (due?.summary ?? "无截止时间") + "；" + (recurrence?.summary ?? "不重复")
            + (notifyAtDue ? "；截止时由系统提醒事项通知（不是响铃闹钟）" : "；不额外添加通知，系统自有提醒偏好仍可能生效")
    }
}

struct AppleReminderSnapshot: Codable, Equatable, Sendable {
    let id: String
    let list: AppleReminderList
    let fields: AppleReminderFields
    let completed: Bool
    /// Hash of native content, including fields not exposed for editing and modification date.
    let revision: String
    /// Complex external schedules are readable; unrelated edits preserve them unchanged.
    let scheduleEditable: Bool
    let scheduleDescription: String
}

enum AppleReminderPatch: Codable, Equatable, Sendable {
    case title(String), notes(String?), priority(Int)
    case schedule(due: AppleReminderDue?, recurrence: AppleReminderRecurrence?, notifyAtDue: Bool)
    case completed(Bool), delete

    func fields(after old: AppleReminderFields) -> AppleReminderFields {
        var result = old
        switch self {
        case .title(let title): result.title = title
        case .notes(let notes): result.notes = notes
        case .priority(let priority): result.priority = priority
        case .schedule(let due, let recurrence, let notify):
            result.due = due; result.recurrence = recurrence; result.notifyAtDue = notify
        case .completed, .delete: break
        }
        return result
    }
}

enum AppleReminderChange: Codable, Equatable, Sendable {
    case access
    case create(list: AppleReminderList, fields: AppleReminderFields)
    case edit(before: AppleReminderSnapshot, patch: AppleReminderPatch)
}

@MainActor protocol AppleReminderDevice {
    var authorized: Bool { get }
    var authorization: String { get }
    func authorize() async throws -> Bool
    func lists() throws -> [AppleReminderList]
    func reminders(listID: String?) async throws -> [AppleReminderSnapshot]
    func reminder(id: String) throws -> AppleReminderSnapshot?
    /// Allocate an EventKit object/ID without saving. Journal that ID before the first write.
    func prepare(listID: String, fields: AppleReminderFields) throws -> String
    func savePrepared(id: String) throws
    func discardPrepared(id: String)
    /// Re-read and compare revision in the native adapter immediately before saving/removing.
    func edit(before: AppleReminderSnapshot, patch: AppleReminderPatch) throws
}
