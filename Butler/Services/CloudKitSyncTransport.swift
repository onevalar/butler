import CloudKit
import Foundation
import CryptoKit

/// Every append and cleanup batch also changes the same control record atomically.
/// A pre-cleanup writer can therefore never commit after the cleanup fence.
@MainActor final class CloudKitSyncTransport: SyncTransport {
    static let containerID = "iCloud.com.anvalar.Butler"
    private lazy var container = CKContainer(identifier: Self.containerID)
    private let zone: CKRecordZone.ID
    private let photos: Bool
    private let recordType = "ButlerRevisionV1"
    private struct Gate: Codable { var epoch: UUID?; var cleaning: UUID? }
    private var controlID: CKRecord.ID { .init(recordName: "__control__", zoneID: zone) }
    private var cachedAccount: String?
    private var cachedEpoch: UUID?
    private var cachedToken: CKServerChangeToken?
    private var cachedRows: [UUID: SyncRecord] = [:]
    init(chatHistory: Bool = false, photos: Bool = false) {
        self.photos = photos
        zone = CKRecordZone.ID(zoneName: photos ? "ButlerPhotoSyncV1" : (chatHistory ? "ButlerChatSyncV1" : "ButlerPrivateSyncV1"), ownerName: CKCurrentUserDefaultName)
    }
    func account() async throws -> String {
        guard try await container.accountStatus() == .available else { throw SyncFailure("iCloud不可用，本机资料保留。") }
        return try await container.userRecordID().recordName
    }
    private func check(_ expected: String) async throws {
        try Task.checkCancellation()
        guard try await account() == expected else { throw SyncFailure("iCloud账户已变化，本轮停止。") }
    }
    private func control(account: String) async throws -> CKRecord? {
        try await check(account)
        do {
            let record = try await container.privateCloudDatabase.record(for: controlID)
            try await check(account)
            _ = try gate(record)
            return record
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound { return nil }
    }
    private func gate(_ record: CKRecord?) throws -> Gate {
        guard let record else { return Gate() }
        guard record.recordType == "ButlerSyncControlV1", let data = record["payload"] as? Data else {
            throw SyncFailure("云端同步控制记录无效，不能继续写入。")
        }
        return try JSONDecoder().decode(Gate.self, from: data)
    }
    private func head(_ record: CKRecord?) throws -> SyncCloudHead {
        let value = try gate(record)
        return .init(epoch: value.epoch, revision: record?.recordChangeTag, cleaning: value.cleaning)
    }
    func head(account: String) async throws -> SyncCloudHead { try await head(control(account: account)) }
    private func stamp(_ record: CKRecord?, _ value: Gate) throws -> CKRecord {
        let record = record ?? CKRecord(recordType: "ButlerSyncControlV1", recordID: controlID)
        record["payload"] = try SyncRecord.encode(value) as CKRecordValue
        record["nonce"] = UUID().uuidString as CKRecordValue
        return record
    }
    private func decode(_ record: CKRecord) throws -> SyncRecord {
        guard record.recordType == recordType else { throw SyncFailure("不支持的云端记录。") }
        let data: Data
        if photos {
            guard let asset = record["asset"] as? CKAsset, let url = asset.fileURL,
                  let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32_000_000 else {
                throw SyncFailure("图片附件缺失或过大，停止而非当作删除。")
            }
            data = try Data(contentsOf: url)
            guard record["sha256"] as? String == Self.digest(data) else { throw SyncFailure("图片附件校验失败。") }
        } else {
            guard let bytes = record["payload"] as? Data else { throw SyncFailure("云端文字记录缺失。") }
            data = bytes
        }
        let row = try JSONDecoder().decode(SyncRecord.self, from: data)
        try row.validate()
        guard record.recordID.recordName == row.id.uuidString, row.key.kind.isPhoto == photos else { throw SyncFailure("云端编号或范围不匹配。") }
        return row
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func encode(_ row: SyncRecord) throws -> CKRecord {
        let record = CKRecord(recordType: recordType, recordID: .init(recordName: row.id.uuidString, zoneID: zone))
        record["payload"] = try SyncRecord.encode(row) as CKRecordValue
        return record
    }
    /// Full reads during cleanup; incremental cached reads during normal sync.
    private func rows(account: String, incremental: Bool) async throws -> [SyncRecord] {
        var token = incremental ? cachedToken : nil
        var rows = incremental ? cachedRows : [:]
        repeat {
            try await check(account)
            do {
                let page = try await container.privateCloudDatabase.recordZoneChanges(inZoneWith: zone, since: token, resultsLimit: photos ? 3 : 100)
                try await check(account)
                for deletion in page.deletions {
                    guard deletion.recordID != controlID else { throw SyncFailure("云端控制记录被删除，已停止。") }
                    if let id = UUID(uuidString: deletion.recordID.recordName) { rows.removeValue(forKey: id) }
                }
                for (id, result) in page.modificationResultsByID {
                    let record = try result.get().record
                    if id == controlID { _ = try gate(record); continue }
                    let row = try decode(record)
                    if let old = rows[row.id], old != row { throw SyncFailure("云端历史被修改。") }
                    rows[row.id] = row
                }
                guard rows.count <= 20_000, rows.values.reduce(0, { $0 + ($1.payload?.count ?? 0) }) <= (photos ? 200_000_000 : 40_000_000) else {
                    throw SyncFailure("同步历史超出容量，停止而非截断资料。")
                }
                token = page.changeToken
                if !page.moreComing { break }
            } catch let error as CKError where error.code == .zoneNotFound {
                guard rows.isEmpty else { throw SyncFailure("同步区域读取途中消失。") }; return []
            } catch let error as CKError where error.code == .changeTokenExpired && incremental && cachedToken != nil {
                cachedToken = nil; cachedRows = [:]
                return try await self.rows(account: account, incremental: true)
            }
        } while true
        if incremental { cachedRows = rows; cachedToken = token }
        return Array(rows.values)
    }
    func fetch(account: String, head expected: SyncCloudHead) async throws -> [SyncRecord] {
        guard expected.cleaning == nil, try await head(account: account) == expected else { throw SyncFailure("云端状态已变化，请重新核对。") }
        if cachedAccount != account || cachedEpoch != expected.epoch {
            cachedToken = nil; cachedRows = [:]; cachedAccount = account; cachedEpoch = expected.epoch
        }
        let result = try await rows(account: account, incremental: true)
        guard try await head(account: account) == expected else {
            cachedToken = nil; cachedRows = [:]
            throw SyncFailure("读取期间云端发生更改，本轮未导入，请重试。")
        }
        return result
    }
    private func modify(_ records: [CKRecord], deleting: [CKRecord.ID] = [], account: String) async throws {
        try await check(account)
        var temporary: [URL] = []
        defer { for url in temporary { try? FileManager.default.removeItem(at: url) } }
        if photos {
            for record in records where record.recordType == recordType {
                guard let data = record["payload"] as? Data, data.count <= 32_000_000 else { throw SyncFailure("图片记录过大。") }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("butler-sync-\(UUID()).asset")
                temporary.append(url); try data.write(to: url, options: .atomic)
                record["payload"] = nil; record["asset"] = CKAsset(fileURL: url)
                record["sha256"] = Self.digest(data) as CKRecordValue
            }
        }
        let result = try await container.privateCloudDatabase.modifyRecords(saving: records, deleting: deleting,
            savePolicy: .ifServerRecordUnchanged, atomically: true)
        try await check(account)
        for record in records {
            guard let saved = result.saveResults[record.recordID] else { throw SyncFailure("保存回执缺失，需核对原操作。") }
            _ = try saved.get()
        }
        for id in deleting {
            guard let deleted = result.deleteResults[id] else { throw SyncFailure("删除回执缺失，需核对原操作。") }
            try deleted.get()
        }
    }
    func send(_ row: SyncRecord, account: String, epoch: UUID?) async throws {
        try await check(account); try row.validate()
        let control = try await control(account: account), value = try gate(control)
        guard value.epoch == epoch, value.cleaning == nil else { throw SyncFailure("云端已清理或正在清理，旧上传被拒绝。") }
        if control == nil { _ = try await container.privateCloudDatabase.save(CKRecordZone(zoneID: zone)) }
        try await modify([encode(row), stamp(control, value)], account: account)
    }
    func clean(_ plan: SyncCleanup) async throws {
        var control = try await control(account: plan.account)
        var value = try gate(control)
        if value.epoch == plan.id, value.cleaning == nil { return } // Lost final receipt.
        if value.cleaning != plan.id {
            guard try head(control) == plan.head, value.cleaning == nil else {
                throw SyncCleanupNotStarted()
            }
            if control == nil { _ = try await container.privateCloudDatabase.save(CKRecordZone(zoneID: zone)) }
            value.cleaning = plan.id
            do { try await modify([stamp(control, value)], account: plan.account) }
            catch let error as CKError where error.code == .serverRecordChanged { throw SyncCleanupNotStarted() }
        }
        // Durable local plan supplies identical checkpoint IDs after a crash or lost reply.
        var present = Dictionary(uniqueKeysWithValues: try await rows(account: plan.account, incremental: false).map { ($0.id, $0) })
        let kept = Set(plan.retained.map(\.id))
        guard Set(present.keys).isSubset(of: plan.removed.union(kept)) else { throw SyncFailure("清理期间出现未预览记录，保持暂停，请核对。") }
        for row in plan.retained {
            if let old = present[row.id] {
                guard old == row else { throw SyncFailure("清理检查点内容不一致。") }; continue
            }
            control = try await controlRecord(for: plan)
            try await modify([encode(row), stamp(control, try gate(control))], account: plan.account)
            present[row.id] = row
        }
        let deleting = Array(plan.removed.intersection(present.keys)).sorted { $0.uuidString < $1.uuidString }
        for start in stride(from: 0, to: deleting.count, by: 100) {
            control = try await controlRecord(for: plan)
            let ids = deleting[start..<min(start + 100, deleting.count)].map { CKRecord.ID(recordName: $0.uuidString, zoneID: zone) }
            try await modify([stamp(control, try gate(control))], deleting: ids, account: plan.account)
        }
        let remaining = try await rows(account: plan.account, incremental: false)
        guard Set(remaining.map(\.id)) == kept,
              remaining.allSatisfy({ row in plan.retained.contains(row) }) else { throw SyncFailure("清理读回未匹配，未报告完成。") }
        control = try await controlRecord(for: plan)
        try await modify([stamp(control, Gate(epoch: plan.id, cleaning: nil))], account: plan.account)
        cachedToken = nil; cachedRows = [:]
    }
    private func controlRecord(for plan: SyncCleanup) async throws -> CKRecord {
        guard let record = try await control(account: plan.account), try gate(record).cleaning == plan.id else {
            throw SyncFailure("云端清理操作编号变化，停止而非重复执行。")
        }
        return record
    }
}
