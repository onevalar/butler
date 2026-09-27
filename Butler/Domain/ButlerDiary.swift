import Foundation

/// 管家日记: one card per day, written from what was actually saved after the owner confirmed.
struct DiaryDay: Identifiable, Equatable {
    let day: Date
    let headline: String
    let lines: [String]
    let conversations: Int
    var id: Date { day }

    /// The last `limit` days with conversation, newest first.
    static func build(from turns: [ChatTurn], limit: Int = 14, calendar: Calendar = .current) -> [DiaryDay] {
        let byDay = Dictionary(grouping: turns) { calendar.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).prefix(limit).compactMap { day in
            let dayTurns = byDay[day] ?? []
            let saved = dayTurns.flatMap(\.receipts).filter { $0.hasPrefix("✓") }
                .map { $0.dropFirst().trimmingCharacters(in: .whitespaces) }
            return DiaryDay(day: day, headline: headline(for: saved, conversations: dayTurns.count),
                            lines: saved, conversations: dayTurns.count)
        }
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
