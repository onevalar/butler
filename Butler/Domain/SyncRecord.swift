import Foundation

struct SyncFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct SyncCleanupNotStarted: LocalizedError {
    var errorDescription: String? { "预览后云端已变化，清理尚未开始；请重新预览确认。" }
}

/// Immutable revisions, not timestamps or local revision counters, establish ancestry.
struct SyncRecord: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case inventory, task, note, chat, itemPhoto, chatPhoto
        var isPhoto: Bool { self == .itemPhoto || self == .chatPhoto }
    }
    struct Key: Codable, Hashable {
        let kind: Kind
        let id: UUID
    }
    let id: UUID
    let key: Key
    let parents: Set<UUID>
    /// nil is a durable deletion, never an omitted fetch result.
    let payload: Data?
    let device: UUID
    var version = 1

    func validate() throws {
        guard version == 1, !parents.contains(id), parents.count <= 100,
              (payload?.count ?? 0) <= (key.kind.isPhoto ? 22_000_000 : 500_000) else {
            throw SyncFailure("同步记录版本或大小不支持，原数据保留。")
        }
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

@MainActor protocol SyncLocalData {
    /// Complete snapshot, excluding photos, credentials, grants and execution state.
    func snapshot() throws -> [SyncRecord.Key: Data]
    /// Synchronous compare-and-replace. Never schedules new system effects on receipt.
    func replace(_ key: SyncRecord.Key, expected: Data?, with payload: Data?) throws
    func abandonImport() throws
    func unavailableKeys() throws -> Set<SyncRecord.Key>
}

extension SyncLocalData {
    func abandonImport() throws {}
    func unavailableKeys() throws -> Set<SyncRecord.Key> { [] }
}

@MainActor protocol SyncTransport {
    func account() async throws -> String
    func head(account: String) async throws -> SyncCloudHead
    /// Complete immutable log. Any partial fetch or physical deletion must fail closed.
    func fetch(account: String, head: SyncCloudHead) async throws -> [SyncRecord]
    /// Same UUID + same contents is idempotent; a mismatched UUID must be rejected.
    func send(_ record: SyncRecord, account: String, epoch: UUID?) async throws
    /// Fence ordinary writers before deleting; resume only this exact durable operation.
    func clean(_ plan: SyncCleanup) async throws
}

struct SyncCloudHead: Codable, Equatable {
    var epoch: UUID?
    var revision: String?
    var cleaning: UUID?
}

struct SyncCleanup: Codable, Equatable, Identifiable {
    enum Mode: String, Codable { case history, everything }
    let id: UUID
    let account: String
    let head: SyncCloudHead
    let mode: Mode
    let removed: Set<UUID>
    let retained: [SyncRecord]
}

enum SyncChange: Codable, Equatable {
    case enabled(Bool)
    case chatEnabled(Bool)
    case photosEnabled(Bool)
    case cleanup(kind: SyncRecord.Kind, plan: SyncCleanup)
    case reconnect(kind: SyncRecord.Kind, account: String, head: SyncCloudHead)
    case resolve(key: SyncRecord.Key, heads: Set<UUID>, selected: UUID)
}
