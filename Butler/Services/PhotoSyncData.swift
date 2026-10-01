import Foundation

/// One item's image or one saved turn's attachments. No message text or system-library access.
struct SyncPhotoBundle: Codable, Equatable {
    struct File: Codable, Equatable { let name: String; let data: Data }
    let scopeKey: String?
    let files: [File]
    func validate(for key: SyncRecord.Key) throws {
        guard key.kind.isPhoto, !files.isEmpty, files.count <= (key.kind == .itemPhoto ? 1 : 4),
              files.allSatisfy({ !$0.data.isEmpty && $0.data.count <= 4_000_000 }),
              files.map(\.name) == files.map(\.name).sorted(), Set(files.map(\.name)).count == files.count else {
            throw SyncFailure("图片数量、大小或名称无效。")
        }
        if key.kind == .itemPhoto {
            guard scopeKey == nil, files[0].name == "image" else { throw SyncFailure("物品图片关联无效。") }
        } else {
            let names = Set((0..<4).map { "\(key.id.uuidString)-\($0).jpg" })
            guard let scopeKey, !scopeKey.isEmpty, scopeKey.utf8.count <= 200,
                  scopeKey.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }),
                  Set(files.map(\.name)).isSubset(of: names) else { throw SyncFailure("聊天图片关联无效，不能写入任意路径。") }
        }
    }
}

struct SyncPhotoSourceValue {
    let bundle: SyncPhotoBundle?
    /// A saved chat declares an attachment which this device has not downloaded yet.
    let incomplete: Bool
}

@MainActor protocol SyncPhotoSource {
    func photos() throws -> [SyncRecord.Key: SyncPhotoSourceValue]
    /// Return false when the owner has not arrived. Must accept an interrupted write's
    /// before/after mixture, but refuse any third value before modifying any file.
    func apply(_ key: SyncRecord.Key, before: SyncPhotoBundle?, after: SyncPhotoBundle?) throws -> Bool
}

@MainActor final class PhotoSyncData: SyncLocalData {
    private struct Entry: Codable, Equatable {
        let key: SyncRecord.Key
        var bundle: SyncPhotoBundle?
        var applied: Bool
    }
    private struct Job: Codable { let key: SyncRecord.Key; let before: SyncPhotoBundle?; let after: SyncPhotoBundle? }
    private struct State: Codable { var entries: [Entry] = []; var job: Job? }
    private let file: URL
    private let source: any SyncPhotoSource
    private var state: State
    init(file: URL, source: any SyncPhotoSource) throws {
        self.file = file; self.source = source
        state = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) : State()
        guard Set(state.entries.map(\.key)).count == state.entries.count else { throw SyncFailure("图片接收记录重复。") }
        for entry in state.entries { try entry.bundle?.validate(for: entry.key) }
        if !FileManager.default.fileExists(atPath: file.path) { try save(state) }
    }
    private func save(_ next: State) throws {
        guard next.entries.reduce(0, { $0 + ($1.bundle?.files.reduce(0, { $0 + $1.data.count }) ?? 0) }) <= 75_000_000 else {
            throw SyncFailure("本机图片暂存超过75MB，停止而非丢弃图片。")
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SyncRecord.encode(next).write(to: file, options: .atomic); state = next
    }
    private func recover() throws {
        guard let job = state.job else { return }
        let applied = try source.apply(job.key, before: job.before, after: job.after)
        var next = state
        next.entries.removeAll { $0.key == job.key }
        next.entries.append(.init(key: job.key, bundle: job.after, applied: applied))
        next.job = nil; try save(next)
    }
    func abandonImport() throws {
        // Backup restore/reconnection must not apply an old staged image over restored data.
        try save(State())
    }
    func unavailableKeys() throws -> Set<SyncRecord.Key> {
        Set(try source.photos().filter { $0.value.incomplete }.map(\.key))
    }
    func snapshot() throws -> [SyncRecord.Key: Data] {
        try recover()
        var values = try source.photos()
        // Fill only missing owners' attachments; an existing local replacement wins detection.
        for entry in state.entries where entry.bundle != nil {
            if let value = values[entry.key], value.incomplete || (!entry.applied && value.bundle == nil) {
                var next = state; next.job = Job(key: entry.key, before: nil, after: entry.bundle)
                try save(next); try recover(); values = try source.photos()
            }
        }
        var next = state
        for index in next.entries.indices {
            let entry = next.entries[index]
            if let value = values[entry.key] {
                if !value.incomplete { next.entries[index].bundle = value.bundle; next.entries[index].applied = true }
            } else if entry.applied { next.entries[index].bundle = nil }
        }
        for (key, value) in values where !value.incomplete && !next.entries.contains(where: { $0.key == key }) {
            if let bundle = value.bundle {
                try bundle.validate(for: key)
                next.entries.append(.init(key: key, bundle: bundle, applied: true))
            }
        }
        if next.entries != state.entries { try save(next) }
        return try Dictionary(uniqueKeysWithValues: state.entries.compactMap { entry in
            try entry.bundle.map { (entry.key, try SyncRecord.encode($0)) }
        })
    }
    func replace(_ key: SyncRecord.Key, expected: Data?, with payload: Data?) throws {
        guard try snapshot()[key] == expected else { throw SyncFailure("本机图片刚发生变化，未覆盖。") }
        let before = try expected.map { try JSONDecoder().decode(SyncPhotoBundle.self, from: $0) }
        let after = try payload.map { try JSONDecoder().decode(SyncPhotoBundle.self, from: $0) }
        try after?.validate(for: key)
        var next = state; next.job = Job(key: key, before: before, after: after)
        try save(next); try recover()
    }
}
