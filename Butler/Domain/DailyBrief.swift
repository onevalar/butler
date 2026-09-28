import Foundation

/// The few sentences at the top of 今天: what needs handling, what's still ahead today, what's due soon.
/// Written on the device from the agenda, so it is always there and never made up.
struct DailyBrief: Equatable {
    let greeting: String
    let text: String
    let basis: String
    let isEvening: Bool

    static func compose(agenda: HomeAgenda, lotCount: Int, reminderCount: Int, usesCalendar: Bool,
                        now: Date = .now, calendar: Calendar = .current) -> DailyBrief {
        let hour = calendar.component(.hour, from: now)
        let evening = hour >= 18 || hour < 5
        var sentences: [String] = []

        // Needs handling now.
        let expired = agenda.needsAttention.filter { $0.kind == .expired }.map(\.title)
        let low = agenda.needsAttention.filter { $0.kind == .lowStock }.map(\.title)
        var attention: [String] = []
        if !expired.isEmpty { attention.append("\(list(expired))已过期") }
        if !low.isEmpty { attention.append("\(list(low))快用完了") }
        if !attention.isEmpty {
            let count = expired.count + low.count
            sentences.append("有 \(count) 样要处理：\(attention.joined(separator: "，"))")
        }

        let pending = agenda.pending(on: agenda.today, at: now)
        if !pending.isEmpty {
            sentences.append("还有 \(pending.count) 件任务待完成：\(list(pending.map(\.title)))")
        }

        let completed = agenda.completed(on: agenda.today)
        if !completed.isEmpty { sentences.append("今天已完成 \(completed.count) 件任务") }

        // Still ahead today.
        let today = agenda.entries(on: agenda.today)
        let dueToday = today.filter { $0.isAllDay && ($0.kind == .expired || $0.kind == .expiring) }.map(\.title)
        if !dueToday.isEmpty { sentences.append(dueToday.joined(separator: "，")) }
        let ahead = today.filter { entry in
            guard let start = entry.start else { return false }
            return !entry.isCompleted && start > now && (entry.kind == .reminder || entry.kind == .calendar)
        }
        if !ahead.isEmpty {
            let lead = evening ? "今晚还有" : "今天"
            let shown = ahead.prefix(2).map { entry -> String in
                let time = spokenTime(entry.start ?? now, calendar: calendar)
                return entry.kind == .reminder ? "\(time)提醒你\(entry.title)" : "\(time)\(entry.title)"
            }
            let more = ahead.count > 2 ? "，还有 \(ahead.count - 2) 件" : ""
            sentences.append(lead + shown.joined(separator: "，") + more)
        }

        // Due in the coming days (in the evening, lead with tomorrow).
        let soon = agenda.days.filter { $0 > agenda.today }.flatMap { day in
            agenda.entries(on: day).filter { $0.kind == .expired || $0.kind == .expiring }
        }
        if !soon.isEmpty {
            let shown = soon.prefix(2).map { "\($0.day.relativeDayName(from: agenda.today, calendar: calendar))\($0.title)" }
            let more = soon.count > 2 ? "，这周还有 \(soon.count - 2) 样" : ""
            sentences.append(shown.joined(separator: "，") + more)
        }

        if sentences.isEmpty {
            sentences.append(lotCount == 0
                ? "家里还没记东西。买了什么跟我说一句，我来记着到期"
                : (evening ? "今天的事都办完了，家里的东西也都还新鲜" : "今天没有要操心的事，家里的东西都还新鲜"))
        }

        var basis = ["家里的 \(lotCount) 样东西"]
        if reminderCount > 0 { basis.append("\(reminderCount) 条提醒") }
        if usesCalendar { basis.append("日历") }

        return DailyBrief(greeting: greeting(hour: hour), text: sentences.joined(separator: "。") + "。",
                          basis: "依据：" + basis.joined(separator: " · "), isEvening: evening)
    }

    static func greeting(hour: Int) -> String {
        switch hour {
        case 5..<11: "早上好"
        case 11..<13: "中午好"
        case 13..<18: "下午好"
        case 18..<24: "晚上好"
        default: "夜深了"
        }
    }

    /// "下午 2 点", "上午 9:30", "晚上 9 点".
    static func spokenTime(_ date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let period = switch hour {
        case 0..<6: "凌晨"
        case 6..<12: "上午"
        case 12..<13: "中午"
        case 13..<18: "下午"
        default: "晚上"
        }
        let twelve = hour > 12 ? hour - 12 : hour
        return minute == 0 ? "\(period) \(twelve) 点" : "\(period) \(twelve):\(String(format: "%02d", minute)) "
    }

    private static func list(_ names: [String]) -> String {
        names.count <= 2 ? names.joined(separator: "、") : names.prefix(2).joined(separator: "、") + " 等 \(names.count) 样"
    }
}

extension Date {
    /// "明天", "后天", "周三" relative to `today` (testable counterpart of `relativeDayName`).
    func relativeDayName(from today: Date, calendar: Calendar) -> String {
        let offset = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: self)).day ?? 0
        switch offset {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        default:
            let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            return names[calendar.component(.weekday, from: self) - 1]
        }
    }
}
