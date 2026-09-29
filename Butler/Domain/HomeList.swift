import Foundation

/// One line of the day list on home.
struct HomeListRow: Identifiable, Equatable {
    let id: String
    let kind: AgendaEntry.Kind
    /// "12:00", "明早", or empty for things that belong to the whole day.
    let lead: String
    let title: String
    let subtitle: String?
    /// Draw the subtitle in red (already overdue).
    let isAlert: Bool
    /// A capsule button on the right ("处理", "查看").
    let action: String?
    let target: AgendaEntry.Target
    var isCompleted = false
}

struct HomeDayList: Equatable {
    var rows: [HomeListRow]
    var completed: [HomeListRow]
}

/// What home shows for a day, and the two quiet summary lines under it.
enum HomeList {
    /// Today: what needs handling first (overdue, tasks that have come due, food about to expire, running low),
    /// then the day's schedule. Other days: whole-day things first, then the schedule by time.
    /// `featured` is what the butler's sentence is already about, so it is not listed twice.
    static func build(day: Date, agenda: HomeAgenda, facts: [LotFacts], featured: AgendaEntry.Target? = nil,
                      now: Date, calendar: Calendar = .current) -> HomeDayList {
        let day = calendar.startOfDay(for: day)
        let byID = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [HomeListRow] = []
        var seen = Set<String>()
        func add(_ row: HomeListRow) {
            guard row.target != featured || row.isCompleted, seen.insert(row.id).inserted else { return }
            rows.append(row)
        }

        if day == agenda.today {
            for entry in agenda.needsAttention where entry.kind == .expired {
                add(row(entry, lots: byID, alert: true, action: "处理", now: now, calendar: calendar))
            }
            for entry in agenda.pending(on: day, at: now) {
                add(HomeListRow(id: "pending-" + entry.id, kind: .reminder, lead: entry.start?.clockTime ?? "", title: entry.title,
                                subtitle: entry.subtitle ?? "已到时间", isAlert: false, action: "查看", target: entry.target))
            }
            for offset in 0...2 {
                guard let soon = calendar.date(byAdding: .day, value: offset, to: day) else { continue }
                for entry in agenda.entries(on: soon) where (entry.kind == .expiring || (entry.kind == .expired && entry.isAllDay))
                    && !entry.isCompleted {
                    add(row(entry, lots: byID, alert: false, action: nil, now: now, calendar: calendar))
                }
            }
            for entry in agenda.entries(on: day) where entry.kind == .calendar && entry.isAllDay {
                add(row(entry, lots: byID, alert: false, action: nil, now: now, calendar: calendar))
            }
            for entry in agenda.needsAttention where entry.kind == .lowStock {
                add(row(entry, lots: byID, alert: false, action: nil, now: now, calendar: calendar))
            }
            let pendingIDs = Set(agenda.pending(on: day, at: now).map(\.id))
            for entry in agenda.entries(on: day) where entry.start != nil && !entry.isCompleted && !pendingIDs.contains(entry.id)
                && (entry.kind == .reminder || entry.kind == .calendar) && (entry.end ?? entry.start ?? now) > now {
                add(row(entry, lots: byID, alert: false, action: nil, now: now, calendar: calendar))
            }
            // In the evening, look ahead to what tomorrow morning needs.
            if calendar.component(.hour, from: now) >= 18, let tomorrow = calendar.date(byAdding: .day, value: 1, to: day) {
                for entry in agenda.entries(on: tomorrow) where !entry.isCompleted && (entry.kind == .reminder || entry.kind == .calendar) {
                    guard let start = entry.start, calendar.component(.hour, from: start) < 10 else { continue }
                    let what = entry.kind == .reminder ? "提醒" : (entry.subtitle ?? "日历")
                    add(HomeListRow(id: "morning-" + entry.id, kind: entry.kind, lead: "明早", title: entry.title,
                                    subtitle: "\(start.clockTime) \(what)", isAlert: false, action: nil, target: entry.target))
                }
            }
        } else {
            let entries = agenda.entries(on: day).filter { !$0.isCompleted }
            for entry in entries where entry.start == nil {
                add(row(entry, lots: byID, alert: false, action: nil, now: now, calendar: calendar))
            }
            for entry in entries where entry.start != nil {
                add(row(entry, lots: byID, alert: false, action: nil, now: now, calendar: calendar))
            }
        }

        let completed = day <= agenda.today ? agenda.completed(on: day).map {
            HomeListRow(id: "done-" + $0.id, kind: .reminder, lead: $0.start?.clockTime ?? "", title: $0.title,
                        subtitle: $0.subtitle, isAlert: false, action: nil, target: $0.target, isCompleted: true)
        } : []
        return HomeDayList(rows: rows, completed: completed)
    }

    private static func row(_ entry: AgendaEntry, lots: [UUID: LotFacts], alert: Bool, action: String?,
                            now: Date, calendar: Calendar) -> HomeListRow {
        var title = entry.title
        var subtitle = entry.subtitle
        if case .lot(let id) = entry.target, let lot = lots[id] {
            title = lot.name
            let amount = "\(lot.quantity) \(lot.unit)"
            let place = lot.storageLocation.map { " · \($0)" } ?? ""
            switch entry.kind {
            case .expired where entry.isAllDay && !alert:
                subtitle = "今天到期 · \(amount)\(place)"
            case .expired:
                subtitle = "\(lot.dateStatusLabel) · \(amount)\(place)"
            case .expiring:
                let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: entry.day).day ?? 0
                let when = offset <= 0 ? "今天到期" : offset == 1 ? "明天到期" : offset == 2 ? "后天到期" : "\(offset) 天后到期"
                subtitle = lot.governingDateKind == .plannedUseBy ? "该吃完了 · \(amount)\(place)" : "\(when) · \(amount)\(place)"
            case .lowStock:
                subtitle = "只剩 \(amount)\(place) · 记得买"
            default: break
            }
        } else if entry.kind == .reminder, subtitle == nil {
            subtitle = "定时提醒"
        }
        return HomeListRow(id: entry.id, kind: entry.kind, lead: entry.start?.clockTime ?? "", title: title,
                           subtitle: subtitle, isAlert: alert, action: action, target: entry.target)
    }

    // MARK: Quiet lines

    /// "这周还有 3 件" and a short preview, from tomorrow to a week ahead. Daily routines and finished tasks don't count.
    static func weekAhead(agenda: HomeAgenda, calendar: Calendar = .current) -> (count: Int, preview: String)? {
        var seen = Set<AgendaEntry.Target>()
        let entries = (1...6).compactMap { calendar.date(byAdding: .day, value: $0, to: agenda.today) }.flatMap { day in
            agenda.entries(on: day).filter { !$0.isRoutine && !$0.isCompleted }
        }.filter { seen.insert($0.target).inserted }
        guard !entries.isEmpty else { return nil }
        let preview = entries.prefix(3).map { "\($0.day.relativeDayName(from: agenda.today, calendar: calendar))\($0.title)" }
        return (entries.count, preview.joined(separator: " · "))
    }

    /// "冷藏 6 · 冷冻 2 · 常温 4 · 卫生间 2".
    static func places(facts: [LotFacts]) -> String {
        let groups = Dictionary(grouping: facts) { StorageLocation.groupName(for: $0.storageLocation) }
            .sorted { StorageLocation.sortKey($0.key) < StorageLocation.sortKey($1.key) }
        var parts = groups.prefix(4).map { "\($0.key) \($0.value.count)" }
        if groups.count > 4 { parts.append("…") }
        return parts.joined(separator: " · ")
    }
}
