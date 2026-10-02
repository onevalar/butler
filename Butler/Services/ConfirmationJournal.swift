import Foundation

/// Evidence only: never stores executable payloads, schedules work or retries effects.
@MainActor final class ConfirmationJournal {
    nonisolated deinit {}
    struct Entry: Codable, Identifiable {
        let id: UUID
        let proposalIDs: [UUID]
        var titles: [String]
        let date: Date
        var receipts: [String] = []
        var finished = false
        var reported = false
        /// Absent in old journals; legacy strings are never guessed into success states.
        var results: [ConfirmationResult]?
    }
    private let file: URL
    private var entries: [Entry] = []
    private var broken = false

    init(file: URL) {
        self.file = file
        do { entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file)) }
        catch {
            let error = error as NSError
            broken = error.domain != NSCocoaErrorDomain || error.code != NSFileReadNoSuchFileError
        }
    }

    func records() throws -> [Entry] {
        guard !broken else { throw FolderFailure("执行记录无法读取，停止新修改以避免重复；原记录保留。") }
        return entries
    }

    func consumedIDs() throws -> Set<UUID> { Set(try records().flatMap(\.proposalIDs)) }

    func begin(ids: [UUID], titles: [String], results: [ConfirmationResult]? = nil) throws -> UUID {
        let consumed = try consumedIDs()
        guard !ids.isEmpty, ids.count == titles.count, Set(ids).count == ids.count,
              ids.allSatisfy({ !consumed.contains($0) }) else {
            throw FolderFailure("这些操作已经开始过或记录不完整，请先核查结果，不会重复执行。")
        }
        if let results {
            guard results.map(\.proposalID) == ids, results.allSatisfy({ $0.state == .notStarted }) else {
                throw FolderFailure("确认项目与执行记录不匹配，本次没有执行。")
            }
        }
        let entry = Entry(id: UUID(), proposalIDs: ids, titles: titles, date: .now, results: results)
        try save(entries + [entry])
        return entry.id
    }

    func progress(_ id: UUID, receipts: [String], finished: Bool = false, results: [ConfirmationResult]? = nil) throws {
        _ = try records()
        guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].finished, !entries[index].reported else {
            throw FolderFailure("执行记录已结束或不存在。")
        }
        var next = entries
        if let results {
            guard results.map(\.proposalID) == entries[index].proposalIDs,
                  !finished || !results.contains(where: { $0.state == .running }) else {
                throw FolderFailure("执行结果与确认项目不匹配，停止后续操作。")
            }
        }
        next[index].receipts = receipts
        next[index].finished = finished
        next[index].results = results
        try save(next)
    }

    func acknowledge(_ ids: Set<UUID>) throws {
        _ = try records()
        var next = entries
        for i in next.indices where ids.contains(next[i].id) {
            next[i].reported = true
            next[i].titles = []
            next[i].receipts = [] // History owns displayed content; retain only replay-prevention IDs.
            next[i].results = nil
        }
        try save(next)
    }

    private func save(_ next: [Entry]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        entries = next
    }
}
