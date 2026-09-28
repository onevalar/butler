import Foundation

/// The whole saved conversation, as the model can browse it: an overview, search, and the
/// original turns page by page. The model decides how much to load for the task at hand.
struct ConversationArchive {
    let turns: [ChatTurn]
    /// First turn (0-based) the model already sees verbatim with every message.
    let recentStart: Int?
    /// Last turn (0-based) folded into the running summary, if any.
    let summaryThrough: Int?
    var scopeDescription: String? = nil
    var sources: [UUID: ChatScope] = [:]

    /// Size of one page of original conversation, in characters.
    static let pageBudget = 12_000

    /// Turn numbers shown to the model are 1-based.
    private func number(_ index: Int) -> Int { index + 1 }

    func overview() -> [String: Any] {
        let calendar = Calendar.current
        let days = Dictionary(grouping: turns.indices) { calendar.startOfDay(for: turns[$0].date) }
            .sorted { $0.key < $1.key }
            .map { day, indices -> [String: Any] in
                ["date": day.isoDay, "turns": indices.count,
                 "from_turn": number(indices.min()!), "to_turn": number(indices.max()!),
                 "topics": indices.prefix(4).map { String(turns[$0].question.prefix(30)) }]
            }
        var result: [String: Any] = ["total_turns": turns.count, "days": days.suffix(90).map { $0 }]
        if !turns.isEmpty, let recentStart { result["already_in_context_from_turn"] = number(recentStart) }
        if let summaryThrough { result["summary_covers_up_to_turn"] = number(summaryThrough) }
        if let scopeDescription { result["scope"] = scopeDescription }
        return result
    }

    func search(_ query: String, from: Date?, to: Date?, limit: Int) -> [String: Any] {
        let words = query.split(whereSeparator: { " ,，、;；".contains($0) }).map(String.init)
        let hits = turns.indices.reversed().filter { index in
            let turn = turns[index]
            guard inRange(turn.date, from: from, to: to) else { return false }
            guard !words.isEmpty else { return true }
            let text = turn.question + "\n" + turn.answer + "\n" + turn.receipts.joined(separator: "\n")
            return words.contains { text.localizedStandardContains($0) }
        }
        let shown = hits.prefix(max(1, min(limit, 50))).map { index -> [String: Any] in
            let turn = turns[index]
            var item: [String: Any] = ["turn": number(index), "turn_id": turn.id.uuidString, "date": turn.date.isoDay,
                                      "user": String(turn.question.prefix(200)), "butler": String(turn.answer.prefix(300))]
            addSource(of: turn, to: &item)
            return item
        }
        var result: [String: Any] = ["total_matches": hits.count, "matches": shown,
                                     "hint": "要看完整原文，用 read_conversation 按 turn 读取"]
        if let scopeDescription { result["scope"] = scopeDescription }
        return result
    }

    /// Original turns in order, one page at a time. `cursor` is the turn number to continue from.
    func read(fromTurn: Int?, toTurn: Int?, from: Date?, to: Date?, cursor: Int?) -> [String: Any] {
        let lower = max(0, (cursor ?? fromTurn ?? 1) - 1)
        let upper = min(turns.count - 1, (toTurn ?? turns.count) - 1)
        var page: [[String: Any]] = []
        var used = 0
        var next: Int?
        if lower <= upper {
            for index in lower...upper {
                let turn = turns[index]
                guard inRange(turn.date, from: from, to: to) else { continue }
                var item: [String: Any] = [
                    "turn": number(index),
                    "turn_id": turn.id.uuidString,
                    "time": turn.date.isoDay + " " + turn.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)),
                    "user": turn.question, "butler": turn.answer,
                ]
                addSource(of: turn, to: &item)
                if !turn.receipts.isEmpty { item["saved"] = turn.receipts }
                if turn.photos?.isEmpty == false { item["had_photos"] = true }
                let size = turn.question.count + turn.answer.count + 40
                if used + size > Self.pageBudget, !page.isEmpty {
                    next = number(index)
                    break
                }
                used += size
                page.append(item)
            }
        }
        var result: [String: Any] = ["turns": page, "total_turns": turns.count]
        if let scopeDescription { result["scope"] = scopeDescription }
        if let next {
            result["next_cursor"] = next
            result["hint"] = "还没读完，用 cursor=\(next) 继续读下一页"
        }
        return result
    }

    private func addSource(of turn: ChatTurn, to item: inout [String: Any]) {
        guard let source = sources[turn.id] else { return }
        item["source_scope"] = source.key
        item["source_title"] = source.title
    }

    private func inRange(_ date: Date, from: Date?, to: Date?) -> Bool {
        let calendar = Calendar.current
        if let from, date < calendar.startOfDay(for: from) { return false }
        if let to, let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to)), date >= end { return false }
        return true
    }
}
