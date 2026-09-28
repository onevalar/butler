import Foundation

/// A phase is a bounded part of a task's reminder policy. Its end is inclusive.
struct ReminderPhase: Codable, Equatable, Identifiable {
    var id = UUID()
    var startDate: Date
    var endDate: Date?
    var repeats: TimedReminder.Repeat = .none
    var intervalMinutes: Int?
    var maxOccurrences: Int?
}

struct ReminderActivity: Codable, Equatable, Identifiable {
    var id = UUID()
    var date = Date()
    var kind: String
    var detail: String
}

/// Pure scheduling shared by the agenda, plan preview and notification delivery.
/// A notification date does not itself mean that the real-world task was completed.
enum ReminderSchedule {
    struct InvalidRule: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Shared by the confirmation card and saved task detail, including every rule and bound.
    static func ruleSummary(_ reminder: TimedReminder) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: reminder.timeZoneIdentifier)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let phases = reminder.phases ?? [ReminderPhase(startDate: reminder.fireDate, repeats: reminder.repeats)]
        var lines = ["时区：\(reminder.timeZoneIdentifier)"]
        if reminder.status == .paused { lines.append("任务保持暂停；恢复后按以下规则提醒。") }
        for (index, phase) in phases.enumerated() {
            let cadence: String
            if let interval = phase.intervalMinutes { cadence = "每 \(interval) 分钟" }
            else {
                switch phase.repeats {
                case .none: cadence = "仅提醒一次"
                case .daily: cadence = "每天同一时间"
                case .weekly: cadence = "每周同一星期、同一时间"
                }
            }
            var line = "阶段 \(index + 1)：\(formatter.string(from: phase.startDate)) 起，\(cadence)"
            if let end = phase.endDate { line += "；至 \(formatter.string(from: end))（含）" }
            if phase.intervalMinutes != nil || phase.repeats != .none {
                if let count = phase.maxOccurrences { line += "；最多 \(count) 次（含首次，从阶段开始累计）" }
                if phase.endDate == nil, phase.maxOccurrences == nil {
                    line += "；本阶段未设截止或次数上限"
                }
            }
            lines.append(line)
        }
        if phases.count > 1 { lines.append("各阶段分别生效，下一阶段不会自动结束上一阶段；同一时刻只提醒一次。") }
        if let end = reminder.endDate {
            lines.append("全局停止时间：\(formatter.string(from: end))（含）；到时停止提醒，不自动标记完成。")
        } else { lines.append("未设全局停止时间；各阶段按自身规则执行。") }
        if let completion = reminder.autoCompleteAt {
            lines.append("\(formatter.string(from: completion)) 按约定自动标记完成，并停止提醒。")
        }
        lines.append("多个时间或次数限制以最先达到的为准；完成或取消整个任务后停止全部后续提醒，暂停期间不提醒。")
        return lines.joined(separator: "\n")
    }

    static func validate(_ reminder: TimedReminder) throws {
        guard !reminder.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reminder.text.count <= 200 else { throw InvalidRule(message: "提醒内容需为 1–200 字") }
        guard TimeZone(identifier: reminder.timeZoneIdentifier) != nil else {
            throw InvalidRule(message: "提醒时区无效")
        }
        guard reminder.fireDate.timeIntervalSince1970.isFinite else { throw InvalidRule(message: "提醒时间无效") }
        guard [reminder.endDate, reminder.autoCompleteAt].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSince1970.isFinite }) else {
            throw InvalidRule(message: "提醒结束时间无效")
        }
        if let end = reminder.endDate, end < reminder.fireDate { throw InvalidRule(message: "结束时间不能早于开始时间") }
        if let completion = reminder.autoCompleteAt, completion <= reminder.fireDate {
            throw InvalidRule(message: "自动结束时间必须晚于开始时间")
        }
        if let phases = reminder.phases {
            guard !phases.isEmpty, phases.count <= 16 else { throw InvalidRule(message: "提醒需包含 1–16 个阶段") }
            for phase in phases {
                guard phase.startDate.timeIntervalSince1970.isFinite,
                      phase.endDate.map({ $0.timeIntervalSince1970.isFinite }) ?? true else {
                    throw InvalidRule(message: "阶段时间无效")
                }
                guard phase.startDate >= reminder.fireDate else { throw InvalidRule(message: "阶段不能早于任务开始时间") }
                guard reminder.endDate.map({ phase.startDate <= $0 }) ?? true,
                      reminder.autoCompleteAt.map({ phase.startDate < $0 }) ?? true else {
                    throw InvalidRule(message: "阶段开始时间必须在任务结束之前")
                }
                if let end = phase.endDate, end < phase.startDate { throw InvalidRule(message: "阶段结束不能早于开始") }
                if let interval = phase.intervalMinutes {
                    guard (1...10_080).contains(interval), phase.repeats == .none else {
                        throw InvalidRule(message: "间隔需为 1–10080 分钟，且不能与每日或每周规则同时设置")
                    }
                    guard phase.endDate != nil || phase.maxOccurrences != nil || reminder.endDate != nil || reminder.autoCompleteAt != nil else {
                        throw InvalidRule(message: "高频提醒必须设置结束时间或次数上限")
                    }
                }
                if let count = phase.maxOccurrences, !(1...1000).contains(count) {
                    throw InvalidRule(message: "每阶段提醒次数需为 1–1000 次")
                }
            }
        }
    }

    static func calendar(for reminder: TimedReminder) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: reminder.timeZoneIdentifier) ?? .current
        return calendar
    }

    /// Returns the next unique dates strictly after `now`; overlapping phases fire once.
    static func preview(_ reminder: TimedReminder, now: Date = .now, limit: Int = 8) -> [Date] {
        guard reminder.status == .active, limit > 0 else { return [] }
        let phases = reminder.phases ?? [ReminderPhase(startDate: reminder.fireDate, repeats: reminder.repeats)]
        let calendar = calendar(for: reminder)
        return Array(Set(phases.flatMap { dates(for: $0, reminder: reminder, after: now, limit: limit, calendar: calendar) })
            .sorted().prefix(limit))
    }

    static func occurrences(_ reminder: TimedReminder, on day: Date, calendar displayCalendar: Calendar = .current) -> [Date] {
        let start = displayCalendar.startOfDay(for: day)
        guard let end = displayCalendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        var bounded = reminder
        bounded.endDate = min(reminder.endDate ?? end, end)
        return preview(bounded, now: start.addingTimeInterval(-0.001), limit: 1500).filter { $0 < end }
    }

    /// An unbounded single calendar rule can use the system's native repeat mechanism.
    /// A future start cannot be discarded: until its first occurrence, use dated requests.
    static func canUseNativeRepeat(_ reminder: TimedReminder, now: Date) -> Bool {
        nativeRepeatPhase(reminder, now: now) != nil
    }

    static func nativeRepeatPhase(_ reminder: TimedReminder, now: Date) -> ReminderPhase? {
        guard reminder.status == .active, reminder.endDate == nil, reminder.autoCompleteAt == nil else { return nil }
        let phase: ReminderPhase
        if let phases = reminder.phases {
            guard phases.count == 1, let first = phases.first, first.endDate == nil,
                  first.intervalMinutes == nil, first.maxOccurrences == nil else { return nil }
            phase = first
        } else { phase = ReminderPhase(startDate: reminder.fireDate, repeats: reminder.repeats) }
        guard phase.repeats != .none else { return nil }
        let calendar = calendar(for: reminder)
        var matching = calendar.dateComponents([.hour, .minute, .second], from: phase.startDate)
        if phase.repeats == .weekly { matching.weekday = calendar.component(.weekday, from: phase.startDate) }
        guard let next = calendar.nextDate(after: now, matching: matching, matchingPolicy: .nextTime), next >= phase.startDate else { return nil }
        return phase
    }

    private static func dates(for phase: ReminderPhase, reminder: TimedReminder, after now: Date,
                              limit: Int, calendar: Calendar) -> [Date] {
        let deadline = [phase.endDate, reminder.endDate].compactMap { $0 }.min()
        func ended(_ date: Date, ordinal: Int) -> Bool {
            (deadline.map { date > $0 } ?? false) ||
                (reminder.autoCompleteAt.map { date >= $0 } ?? false) ||
                (phase.maxOccurrences.map { ordinal >= $0 } ?? false)
        }
        func allowed(_ date: Date, ordinal: Int) -> Bool {
            date > now && date >= phase.startDate &&
                (deadline == nil || date <= deadline!) &&
                (reminder.autoCompleteAt == nil || date < reminder.autoCompleteAt!) &&
                (phase.maxOccurrences == nil || ordinal < phase.maxOccurrences!)
        }
        if let interval = phase.intervalMinutes {
            guard interval > 0 else { return [] }
            let step = Double(interval) * 60
            let elapsed = floor(now.timeIntervalSince(phase.startDate) / step) + 1
            guard elapsed.isFinite, elapsed < Double(Int.max - limit) else { return [] }
            let first = max(0, Int(elapsed))
            var result: [Date] = []
            for ordinal in first..<(first + limit) {
                let date = phase.startDate.addingTimeInterval(Double(ordinal) * step)
                if ended(date, ordinal: ordinal) { break }
                if allowed(date, ordinal: ordinal) { result.append(date) }
            }
            return result
        }
        guard phase.repeats != .none else { return allowed(phase.startDate, ordinal: 0) ? [phase.startDate] : [] }
        let stepDays = phase.repeats == .daily ? 1 : 7
        let elapsedDays = calendar.dateComponents([.day], from: calendar.startOfDay(for: phase.startDate),
                                                  to: calendar.startOfDay(for: now)).day ?? 0
        let first = max(0, elapsedDays / stepDays)
        let clock = calendar.dateComponents([.hour, .minute, .second], from: phase.startDate)
        var result: [Date] = []
        // One extra iteration accounts for today's occurrence being in the past.
        for ordinal in first..<(first + limit + 1) {
            guard let day = calendar.date(byAdding: .day, value: ordinal * stepDays, to: calendar.startOfDay(for: phase.startDate)),
                  let date = calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0,
                                           second: clock.second ?? 0, of: day) else { continue }
            if ended(date, ordinal: ordinal) { break }
            if allowed(date, ordinal: ordinal) { result.append(date) }
            if result.count == limit { break }
        }
        return result
    }
}
