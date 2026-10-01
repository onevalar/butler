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

    func begin(ids: [UUID], titles: [String]) throws -> UUID {
        let consumed = try consumedIDs()
        guard !ids.isEmpty, ids.count == titles.count, Set(ids).count == ids.count,
              ids.allSatisfy({ !consumed.contains($0) }) else {
            throw FolderFailure("这些操作已经开始过或记录不完整，请先核查结果，不会重复执行。")
        }
        let entry = Entry(id: UUID(), proposalIDs: ids, titles: titles, date: .now)
        try save(entries + [entry])
        return entry.id
    }

    func progress(_ id: UUID, receipts: [String], finished: Bool = false) throws {
        _ = try records()
        guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].finished, !entries[index].reported else {
            throw FolderFailure("执行记录已结束或不存在。")
        }
        var next = entries
        next[index].receipts = receipts
        next[index].finished = finished
        try save(next)
    }

    func acknowledge(_ ids: Set<UUID>) throws {
        _ = try records()
        var next = entries
        for i in next.indices where ids.contains(next[i].id) {
            next[i].reported = true
            next[i].titles = []
            next[i].receipts = [] // History owns displayed content; retain only replay-prevention IDs.
        }
        try save(next)
    }

    private func save(_ next: [Entry]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        entries = next
    }
}
