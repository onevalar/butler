import Foundation
import Observation
import UserNotifications

/// A reminder the owner asked for ("11 点提醒我热饭"), delivered by the system at that time.
struct TimedReminder: Codable, Identifiable, Equatable {
    enum Repeat: String, Codable { case none, daily, weekly }

    var id = UUID()
    var text: String
    var fireDate: Date
    var repeats: Repeat = .none
    var createdAt = Date()

    /// "今天 11:00", "每天 11:00", "每周三 08:30", "9月30日 11:00".
    var whenLabel: String {
        let time = fireDate.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        switch repeats {
        case .daily: return "每天 \(time)"
        case .weekly:
            let weekday = fireDate.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "zh_CN")))
            return "每\(weekday.replacingOccurrences(of: "星期", with: "周")) \(time)"
        case .none:
            let calendar = Calendar.current
            if calendar.isDateInToday(fireDate) { return "今天 \(time)" }
            if calendar.isDateInTomorrow(fireDate) { return "明天 \(time)" }
            return "\(fireDate.monthDay) \(time)"
        }
    }

    func isUpcoming(now: Date = .now) -> Bool { repeats != .none || fireDate > now }
}

/// The owner's timed reminders: a small file on the phone plus system notifications.
@MainActor @Observable
final class ReminderStore {
    private let file: URL
    private let schedules: Bool
    private(set) var reminders: [TimedReminder] = []
    private static let prefix = "butler.reminder."

    init(file: URL, schedules: Bool = true) {
        self.file = file
        self.schedules = schedules
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([TimedReminder].self, from: data) {
            reminders = saved
        }
    }

    nonisolated deinit {}

    static func openOnDevice() -> ReminderStore {
        let directory = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return ReminderStore(file: directory.appendingPathComponent("reminders.json"))
    }

    var upcoming: [TimedReminder] {
        reminders.filter { $0.isUpcoming() }.sorted { $0.fireDate < $1.fireDate }
    }

    func add(_ reminder: TimedReminder) throws {
        var next = reminders.filter { $0.isUpcoming() } // forget ones that already went off
        next.append(reminder)
        try save(next)
        schedule(reminder)
    }

    func remove(_ id: UUID) throws {
        try save(reminders.filter { $0.id != id })
        if schedules {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.prefix + id.uuidString])
        }
    }

    /// Re-reads the file (after a restore) and replaces every scheduled reminder with what it says.
    func reload() {
        if schedules {
            let ids = reminders.map { Self.prefix + $0.id.uuidString }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
        reminders = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([TimedReminder].self, from: $0) } ?? []
        rescheduleAll()
    }

    /// Re-adds every upcoming reminder, e.g. right after notifications were allowed.
    func rescheduleAll() {
        upcoming.forEach(schedule)
    }

    private func save(_ next: [TimedReminder]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        reminders = next
    }

    private func schedule(_ reminder: TimedReminder) {
        guard schedules else { return }
        let content = UNMutableNotificationContent()
        content.title = "小当家提醒"
        content.body = reminder.text
        content.sound = .default
        content.categoryIdentifier = NotificationManager.reminderCategory
        let calendar = Calendar.current
        let components: DateComponents = switch reminder.repeats {
        case .daily: calendar.dateComponents([.hour, .minute], from: reminder.fireDate)
        case .weekly: calendar.dateComponents([.weekday, .hour, .minute], from: reminder.fireDate)
        case .none: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.fireDate)
        }
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: reminder.repeats != .none)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.prefix + reminder.id.uuidString, content: content, trigger: trigger))
    }
}
