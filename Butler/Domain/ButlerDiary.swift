import Foundation

/// 管家日记: one card per day, written from what was actually saved after the owner confirmed.
struct DiaryDay: Identifiable, Equatable {
    let day: Date
    let headline: String
    let lines: [String]
    let conversations: Int
    /// What the rest of the family did that day ("妈妈完成了 交水费").
    var family: [String] = []
    var id: Date { day }

    /// The last `limit` days with conversation or family activity, newest first.
    static func build(from turns: [ChatTurn], tasks: [TimedReminder] = [], household: HouseholdNames = .none,
                      limit: Int = 14, calendar: Calendar = .current) -> [DiaryDay] {
        let byDay = Dictionary(grouping: turns) { calendar.startOfDay(for: $0.date) }
        let familyByDay = familyLines(tasks, household: household, calendar: calendar)
        return Set(byDay.keys).union(familyByDay.keys).sorted(by: >).prefix(limit).compactMap { day in
            let dayTurns = byDay[day] ?? []
            let saved = dayTurns.flatMap(\.receipts).filter { $0.hasPrefix("✓") }
                .map { $0.dropFirst().trimmingCharacters(in: .whitespaces) }
            let family = familyByDay[day] ?? []
            let headline = dayTurns.isEmpty ? "家里：" + familyHeadline(family) : headline(for: saved, conversations: dayTurns.count)
            return DiaryDay(day: day, headline: headline, lines: saved, conversations: dayTurns.count, family: family)
        }
    }

    /// Others' doings on shared tasks, by day, oldest first within a day.
    static func familyLines(_ tasks: [TimedReminder], household: HouseholdNames, calendar: Calendar) -> [Date: [String]] {
        guard household.isActive else { return [:] }
        var result: [Date: [(Date, String)]] = [:]
        for task in tasks where task.sharing?.isShared == true {
            for event in task.activity {
                guard let by = event.by, by != household.me, let who = household.name(by) else { continue }
                let verb: String
                switch event.kind {
                case "created": verb = "安排了"
                case "completed": verb = "完成了"
                case "reopened": verb = "重新打开了"
                case "cancelled": verb = "取消了"
                default: continue
                }
                result[calendar.startOfDay(for: event.date), default: []].append((event.date, "\(who)\(verb) \(task.text)"))
            }
        }
        return result.mapValues { $0.sorted { $0.0 < $1.0 }.map(\.1) }
    }

    static func familyHeadline(_ lines: [String]) -> String {
        let done = lines.filter { $0.contains("完成了") }.count
        return done > 0 ? "家人完成了 \(done) 件事" : "家人做了 \(lines.count) 件事"
    }

    static func headline(for saved: [String], conversations: Int) -> String {
        let added = saved.filter { $0.hasPrefix("新增") }.count
        let reminders = saved.filter { $0.hasPrefix("提醒") }.count
        let learned = saved.filter { $0.hasPrefix("记住") || $0.hasPrefix("更正") }.count
        let changed = saved.count - added - reminders - learned - saved.filter { $0.hasPrefix("取消提醒") }.count
        var parts: [String] = []
        if added > 0 { parts.append("记了 \(added) 样东西") }
        if changed > 0 { parts.append("改了 \(changed) 处") }
        if reminders > 0 { parts.append("设了 \(reminders) 个提醒") }
        if learned > 0 { parts.append("记住了 \(learned) 个习惯") }
        return parts.isEmpty ? "聊了 \(conversations) 次" : parts.joined(separator: "，")
    }
}
