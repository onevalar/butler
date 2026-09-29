import Foundation

/// Small wording helpers for the morning and evening lines.
enum DailyBrief {
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
