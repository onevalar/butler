import Foundation

/// OCR is a candidate, never proof that a printed date is an expiry date.
struct DateParser {
    enum Context: Equatable { case expiry, production, ambiguous, unlabeled }
    struct Candidate {
        let date: Date?
        let context: Context
        var guidance: String {
            switch context {
            case .expiry: return "请核对识别日期，并确认它是包装有效期。"
            case .production: return "这是生产日期，不能当作有效期。请另选包装有效期。"
            case .ambiguous: return "日期有歧义或包含多个日期，请手动选择包装有效期。"
            case .unlabeled: return "未找到有效期标记，请核实这不是生产日期。"
            }
        }
    }

    static func parse(_ text: String) -> Date? { candidate(in: text).date }

    static func candidate(in text: String, calendar: Calendar = .current) -> Candidate {
        let upper = text.uppercased()
        let production = ["生产", "制造", "MFG", "MFD", "PROD"].contains { upper.contains($0) }
        let expiry = ["有效期至", "有效日期", "到期", "失效", "EXP", "BEST BEFORE", "USE BY"].contains { upper.contains($0) }
        // Deliberately reject two-digit years, month/day ambiguity and partial dates.
        let pattern = "(?<![0-9])(?:[0-9]{4}[-/.年\\s][0-9]{1,2}[-/.月\\s][0-9]{1,2}日?|[0-9]{8}|[0-9]{1,2}[-/.][0-9]{1,2}[-/.][0-9]{4})(?![0-9])"
        let ns = text as NSString
        let matches = (try? NSRegularExpression(pattern: pattern))?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []
        guard matches.count == 1, !(production && expiry) else {
            return Candidate(date: nil, context: production && !expiry ? .production : .ambiguous)
        }
        let raw = ns.substring(with: matches[0].range)
        var parts = raw.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
        if parts.count == 1, raw.count == 8 {
            parts = [String(raw.prefix(4)), String(raw.dropFirst(4).prefix(2)), String(raw.suffix(2))]
        }
        guard parts.count == 3 else { return Candidate(date: nil, context: .ambiguous) }
        var year: Int, month: Int, day: Int
        if parts[0].count == 4 {
            year = Int(parts[0])!; month = Int(parts[1])!; day = Int(parts[2])!
        } else {
            day = Int(parts[0])!; month = Int(parts[1])!; year = Int(parts[2])!
            guard day > 12 else { return Candidate(date: nil, context: .ambiguous) }
        }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let components = DateComponents(year: year, month: month, day: day)
        guard (2001..<2100).contains(year), let date = gregorian.date(from: components),
              gregorian.component(.year, from: date) == year,
              gregorian.component(.month, from: date) == month,
              gregorian.component(.day, from: date) == day else {
            return Candidate(date: nil, context: .ambiguous)
        }
        return Candidate(date: production ? nil : date, context: production ? .production : (expiry ? .expiry : .unlabeled))
    }
}
