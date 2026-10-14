import Foundation

/// Understands "七点18提醒我一下", "明天早上8点半提醒我买菜", "每天晚上9点提醒我吃药", "20分钟后提醒我关火"
/// on the phone itself, so a reminder can still be set when the model can't be reached.
/// A bare clock time means the nearest one still ahead (at 18:55, "7点" is 19:00 today).
enum LocalReminderParser {
    struct Result: Equatable {
        let text: String
        let fireDate: Date
        let repeats: TimedReminder.Repeat
        var timePeriod: ArrangementPeriod? = nil
    }

    static func parse(_ raw: String, now: Date = .now, calendar: Calendar = .current) -> Result? {
        // This offline fallback creates notifications only. Never downgrade an explicit alarm request.
        guard !["闹钟", "响铃", "叫醒", "倒计时", "计时器"].contains(where: raw.contains) else { return nil }
        guard raw.contains("提醒") || raw.contains("叫我") || raw.contains("通知") else { return nil }
        let text = normalizeNumbers(raw.replacingOccurrences(of: "：", with: ":"))
        var repeats: TimedReminder.Repeat = .none
        if text.contains("每天") || text.contains("每晚") || text.contains("每早") { repeats = .daily }

        // "20分钟后", "半小时后", "2小时后"
        if let relative = relativeOffset(in: text) {
            return Result(text: content(of: raw), fireDate: now.addingTimeInterval(relative), repeats: .none)
        }

        let today = calendar.startOfDay(for: now)
        var day = today
        var dayGiven = false
        if text.contains("后天") { day = calendar.date(byAdding: .day, value: 2, to: today) ?? today; dayGiven = true }
        else if text.contains("明天") || text.contains("明早") || text.contains("明晚") { day = calendar.date(byAdding: .day, value: 1, to: today) ?? today; dayGiven = true }
        else if text.contains("今天") || text.contains("今晚") || text.contains("今早") { dayGiven = true }
        if let weekday = weekday(in: text) {
            repeats = text.contains("每周") || text.contains("每个周") || text.contains("每星期") ? .weekly : repeats
            let current = calendar.component(.weekday, from: today)
            var ahead = (weekday - current + 7) % 7
            if ahead == 0 && !text.contains("今") { ahead = repeats == .weekly ? 0 : 7 }
            day = calendar.date(byAdding: .day, value: ahead, to: today) ?? today
            dayGiven = true
        }

        guard let (hour, minute) = clock(in: text) else {
            // Narrow offline fallback: a named day, no location trigger or unsupported numeric time.
            guard dayGiven, repeats == .none,
                  !["到家", "到公司", "离开", "到达", "点", "小时", "分钟"].contains(where: text.contains) else { return nil }
            let period: ArrangementPeriod = ["下午"].contains(where: text.contains) ? .afternoon
                : ["晚上", "今晚", "明晚", "傍晚"].contains(where: text.contains) ? .evening
                : text.contains("中午") ? .noon
                : ["上午", "早上", "早晨", "明早", "今早"].contains(where: text.contains) ? .morning : .day
            let stripped = raw.replacingOccurrences(of: #"^(请)?(帮我)?(今天|明天|后天|今晚|明晚|今早|明早|(?:周|星期|礼拜)[一二三四五六日天])(上午|早上|早晨|中午|下午|傍晚|晚上)?"#, with: "", options: .regularExpression)
            return Result(text: content(of: stripped), fireDate: day, repeats: .none, timePeriod: period)
        }
        var h = hour
        let afternoon = ["下午", "晚上", "今晚", "明晚", "傍晚", "夜里", "每晚"].contains { text.contains($0) }
        let morning = ["早上", "早晨", "上午", "凌晨", "今早", "明早", "每早"].contains { text.contains($0) }
        if afternoon, h < 12 { h += 12 }
        if text.contains("中午"), h < 11 { h += 12 }

        func at(_ hour: Int, on day: Date) -> Date? {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
        }
        var fire: Date?
        if afternoon || morning || h > 12 || dayGiven {
            fire = at(h, on: day)
            if !dayGiven, let f = fire, f <= now { fire = calendar.date(byAdding: .day, value: 1, to: f) }
        } else {
            // A bare clock time: the nearest of h (morning) and h + 12 that is still ahead.
            let candidates = [h, h + 12].filter { $0 < 24 }.compactMap { at($0, on: today) }
                + [h, h + 12].filter { $0 < 24 }.compactMap { at($0, on: calendar.date(byAdding: .day, value: 1, to: today) ?? today) }
            fire = candidates.filter { $0 > now }.min()
        }
        guard let fireDate = fire else { return nil }
        if repeats == .none, fireDate <= now { return nil }
        return Result(text: content(of: raw), fireDate: fireDate, repeats: repeats)
    }

    // MARK: - Pieces

    /// What to show in the notification: the request without the time and the filler words.
    static func content(of raw: String) -> String {
        var text = raw
        let patterns = [
            #"(每天|每晚|每早|每周|每个周|每星期)?(今天|明天|后天|今晚|明晚|今早|明早)?(凌晨|早上|早晨|上午|中午|下午|傍晚|晚上|夜里)?"#
                + #"([0-9零一二两三四五六七八九十]+)\s*(点|:|时)\s*([0-9零一二三四五六七八九十]+|半|一刻|三刻)?\s*(分)?"#,
            #"(周|星期|礼拜)[一二三四五六日天]"#,
            #"[0-9零一二两三四五六七八九十半]+\s*(个)?\s*(分钟|小时)\s*(以)?后"#,
            #"(帮我|给我)?(定|设|设置|订)?(一个|个)?"#,
            #"(提醒我|提醒一下|提醒|叫我|通知我|的一个通知|通知)"#,
            #"(的时候|时候|一下|一声|到时|到点|记得|吧|哦|啊|呀)"#,
            #"[，。,.!！?？\s]"#,
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "的去要"))
        return text.isEmpty ? "到时间了" : text
    }

    private static func clock(in text: String) -> (Int, Int)? {
        let pattern = #"([0-9]{1,2})\s*(?:点|:|时)\s*([0-9]{1,2}|半|一刻|三刻)?"#
        guard let match = text.range(of: pattern, options: .regularExpression) else { return nil }
        let piece = String(text[match])
        let numbers = piece.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.compactMap(Int.init)
        guard let hour = numbers.first, hour <= 24 else { return nil }
        var minute = numbers.count > 1 ? numbers[1] : 0
        if piece.contains("半") { minute = 30 }
        if piece.contains("一刻") { minute = 15 }
        if piece.contains("三刻") { minute = 45 }
        guard minute < 60 else { return nil }
        return (hour == 24 ? 0 : hour, minute)
    }

    private static func relativeOffset(in text: String) -> TimeInterval? {
        if text.contains("半小时后") || text.contains("半个小时后") { return 30 * 60 }
        guard let match = text.range(of: #"([0-9]+)\s*(个)?\s*(分钟|小时)\s*(以)?后"#, options: .regularExpression) else { return nil }
        let piece = String(text[match])
        guard let value = Int(piece.prefix { $0.isNumber }) else { return nil }
        return TimeInterval(value) * (piece.contains("小时") ? 3600 : 60)
    }

    private static func weekday(in text: String) -> Int? {
        guard let match = text.range(of: #"(周|星期|礼拜)[一二三四五六日天]"#, options: .regularExpression) else { return nil }
        let names: [Character: Int] = ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7]
        return text[match].last.flatMap { names[$0] }
    }

    /// "七点十八" → "7点18", "十点半" → "10点半". Leaves weekday names alone.
    static func normalizeNumbers(_ text: String) -> String {
        let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        var result = ""
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            var value = 0
            if run.contains("十") {
                let parts = run.split(separator: "十", omittingEmptySubsequences: false)
                let tens = parts[0].isEmpty ? 1 : (digits[parts[0].first!] ?? 1)
                let ones = parts.count > 1 && !parts[1].isEmpty ? (digits[parts[1].first!] ?? 0) : 0
                value = tens * 10 + ones
            } else {
                value = run.reduce(0) { $0 * 10 + (digits[$1] ?? 0) }
            }
            result += String(value)
            run = ""
        }
        let chars = Array(text)
        for (index, char) in chars.enumerated() {
            let previous = index > 0 ? chars[index - 1] : " "
            let isWeekdayName = "周期拜".contains(previous) && run.isEmpty
            if (digits[char] != nil || char == "十") && !isWeekdayName && !(char == "一" && (index + 1 < chars.count && "刻下个些".contains(chars[index + 1]))) {
                run.append(char)
            } else {
                flush()
                result.append(char)
            }
        }
        flush()
        return result
    }
}
