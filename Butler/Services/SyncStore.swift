import Foundation

/// Local files remain authoritative. A failed network operation never rolls them back.
@MainActor final class SyncStore {
    struct Baseline: Codable {
        let key: SyncRecord.Key
        var payload: Data?
        var heads: Set<UUID>
    }
    struct Import: Codable {
        let key: SyncRecord.Key
        let before: Data?
        let after: Data?
        let heads: Set<UUID>
    }
    struct State: Codable {
        var version = 1
        var device = UUID()
        var account: String?
        var enabled = false
        var records: [SyncRecord] = []
        var sent: Set<UUID> = []
        var baselines: [Baseline] = []
        var importing: Import?
        var lastSuccess: Date?
        var cloudEpoch: UUID?
        var cleanup: SyncCleanup?
        var needsReconnect: Bool?
        var adopting: Bool?
    }
    private let file: URL
    private let local: any SyncLocalData
    private let transport: any SyncTransport
    private let kinds: Set<SyncRecord.Kind>
    private var state = State()
    private var failed = false
    private var generation = UUID()
    private(set) var busy = false
    private(set) var warning: String?
    var enabled: Bool { state.enabled && !failed }
    var lastSuccess: Date? { state.lastSuccess }
    var needsReconnect: Bool { state.needsReconnect == true }
    var cleanupID: UUID? { state.cleanup?.id }
    var deviceID: UUID { state.device }
    var pendingCount: Int { state.records.filter { !state.sent.contains($0.id) }.count }
    init(file: URL, local: any SyncLocalData, transport: any SyncTransport,
         kinds: Set<SyncRecord.Kind> = [.inventory, .task, .note]) {
        self.file = file; self.local = local; self.transport = transport; self.kinds = kinds
        do {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            guard state.version == 1, state.records.allSatisfy({ kinds.contains($0.key.kind) }),
                  state.baselines.allSatisfy({ kinds.contains($0.key.kind) }),
                  state.importing.map({ kinds.contains($0.key.kind) }) ?? true else { throw SyncFailure("同步记录版本或范围不匹配。") }
            try Self.validate(state.records)
        } catch {
            let e = error as NSError
            failed = e.domain != NSCocoaErrorDomain || e.code != NSFileReadNoSuchFileError
            if failed { warning = "同步记录不可读，已停止同步；原数据未清除。" }
        }
    }
    nonisolated deinit {}
    private func save(_ next: State) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SyncRecord.encode(next).write(to: file, options: .atomic)
        state = next
    }
    private func ready(_ token: UUID) throws {
        try Task.checkCancellation()
        guard !failed, state.enabled, generation == token else { throw SyncFailure("同步已关闭或中断，未继续处理。") }
    }
    private func checkAccount(_ token: UUID) async throws -> String {
        try ready(token)
        let account = try await transport.account(); try ready(token)
        guard account == state.account else {
            var next = state; next.enabled = false; try save(next); generation = UUID()
            throw SyncFailure("iCloud账户发生变化，已暂停；本机资料保留，不向新账户上传。请切回原账户后确认开启。")
        }
        return account
    }
    func pause() throws {
        generation = UUID()
        guard !failed else { throw SyncFailure("同步记录不可读，已停止但不能覆盖原文件。") }
        var next = state; next.enabled = false
        do { try save(next) } catch { failed = true; throw error }
    }
    func prepareForRestore() throws {
        try pause()
        try local.abandonImport()
        var next = state; next.importing = nil
        try save(next)
    }
    func setEnabled(_ enabled: Bool) async throws {
        guard !failed else { throw SyncFailure("同步记录不可读，不能覆盖。") }
        if !enabled {
            try pause()
            return
        }
        guard !busy else { throw SyncFailure("正在同步，请稍后重试。") }
        busy = true; defer { busy = false }
        let token = generation
        let account = try await transport.account()
        try Task.checkCancellation()
        guard token == generation else { throw SyncFailure("开启操作已取消。") }
        guard state.account == nil || state.account == account else { throw SyncFailure("此同步记录属于另一个iCloud账户，不能把原资料自动上传给新账户。") }
        guard state.cleanup == nil, !needsReconnect else { throw SyncFailure("云端清理待核对或已完成；请先查看状态，再单独确认重新连接，不能普通开启后传回旧资料。") }
        let head = try await transport.head(account: account)
        guard token == generation else { throw SyncFailure("开启操作已取消。") }
        if state.account == nil { var bound = state; bound.account = account; try save(bound) }
        try acceptEpoch(head)
        var next = state; next.account = account; next.enabled = true; try save(next)
    }
    private func acceptEpoch(_ head: SyncCloudHead) throws {
        guard head.cleaning == nil, head.epoch == state.cloudEpoch else {
            var next = state; next.enabled = false; next.needsReconnect = true
            try save(next); generation = UUID()
            throw SyncFailure("云端正在清理或已换代，本机已暂停，旧资料未上传。完成清理后需单独确认重新连接。")
        }
    }
    /// Read-only preview, with an exact server revision. Never captures local changes.
    func previewCleanup(_ mode: SyncCleanup.Mode) async throws -> SyncCleanup {
        guard !failed, !busy, let account = state.account else { throw SyncFailure("请先在本机确认iCloud账户，并等待同步空闲。") }
        if let pending = state.cleanup {
            guard pending.mode == mode else { throw SyncFailure("先核对并继续原清理操作，不能换一种范围重复发起。") }
            return pending
        }
        guard try await transport.account() == account else { throw SyncFailure("iCloud账户不匹配。") }
        let head = try await transport.head(account: account)
        guard head.cleaning == nil else { throw SyncFailure("另一设备正在清理，请在发起设备核对进度。") }
        let rows = try await transport.fetch(account: account, head: head)
        try Self.validate(rows)
        guard rows.allSatisfy({ kinds.contains($0.key.kind) }) else { throw SyncFailure("云端范围不匹配。") }
        let ancestors = Set(rows.flatMap(\.parents)), current = rows.filter { !ancestors.contains($0.id) }
        // Keep every unresolved branch too; cleanup must never choose a conflict winner.
        let retained = mode == .everything ? [] : current.map {
            SyncRecord(id: UUID(), key: $0.key, parents: [], payload: $0.payload, device: $0.device)
        }
        return SyncCleanup(id: UUID(), account: account, head: head, mode: mode,
                           removed: Set(rows.map(\.id)), retained: retained)
    }
    func clean(_ plan: SyncCleanup) async throws {
        guard !failed, !busy, state.account == plan.account,
              state.cleanup == nil || state.cleanup == plan,
              plan.retained.allSatisfy({ kinds.contains($0.key.kind) }) else { throw SyncFailure("清理状态已变化，未执行新操作。") }
        try Self.validate(plan.retained)
        try pause()
        var next = state; next.cleanup = plan; next.needsReconnect = true; try save(next)
        busy = true; defer { busy = false }
        do {
            try await transport.clean(plan)
            // Do not touch local user data or automatically reset baselines for upload.
            var finished = state; finished.cleanup = nil; try save(finished)
            warning = "云端清理已完成，本机资料保留；重新连接并上传本机资料须另行确认。"
        } catch let error as SyncCleanupNotStarted {
            var next = state; next.cleanup = nil; try save(next)
            warning = error.localizedDescription
            throw error
        } catch {
            warning = "清理可能部分完成；本机已暂停。请在本设备重新提出相同范围以核对并继续原操作，不能当作成功或新建另一操作。"
            throw error
        }
    }
    func reconnectPreview() async throws -> (String, SyncCloudHead) {
        guard !failed, !busy, state.cleanup == nil, let account = state.account,
              try await transport.account() == account else { throw SyncFailure("请先完成原清理并核对iCloud账户。") }
        let head = try await transport.head(account: account)
        guard head.cleaning == nil else { throw SyncFailure("云端清理尚未结束。") }
        return (account, head)
    }
    func reconnect(account: String, head: SyncCloudHead) async throws {
        let token = generation
        let current = try await reconnectPreview()
        guard current.0 == account, current.1 == head, !busy, token == generation else { throw SyncFailure("云端或本机在确认期间变化，请重新核对。") }
        try local.abandonImport()
        var next = State(); next.device = state.device; next.account = account
        next.cloudEpoch = head.epoch; next.enabled = true; next.adopting = true
        try save(next); generation = UUID(); warning = nil
    }
    /// Retains all branches; selecting a winner creates another revision, not a cloud overwrite.
    func conflicts() throws -> [[SyncRecord]] {
        guard !failed else { throw SyncFailure("同步记录不可读。") }
        return Set(state.records.map(\.key)).compactMap { key in
            let rows = heads(key)
            return rows.count > 1 ? rows.sorted { $0.id.uuidString < $1.id.uuidString } : nil
        }.sorted { $0[0].key.id.uuidString < $1[0].key.id.uuidString }
    }
    private func heads(_ key: SyncRecord.Key) -> [SyncRecord] {
        let rows = state.records.filter { $0.key == key }, ancestors = Set(rows.flatMap(\.parents))
        return rows.filter { !ancestors.contains($0.id) }
    }
    static func validate(_ rows: [SyncRecord]) throws {
        let limit = rows.allSatisfy { $0.key.kind.isPhoto } ? 100_000_000 : 20_000_000
        guard rows.count <= 10_000, rows.reduce(0, { $0 + ($1.payload?.count ?? 0) }) <= limit,
              Set(rows.map(\.id)).count == rows.count else { throw SyncFailure("同步记录过多或编号重复，停止而非截断。") }
        let map = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for row in rows {
            try row.validate()
            guard row.parents.allSatisfy({ map[$0]?.key == row.key }) else { throw SyncFailure("同步历史不完整，不能把缺失当删除。") }
        }
        // Detect cycles without recursively traversing untrusted cloud data.
        var remaining = map, visited = Set<UUID>()
        while !remaining.isEmpty {
            let ready = remaining.values.filter { $0.parents.isSubset(of: visited) }.map(\.id)
            guard !ready.isEmpty else { throw SyncFailure("同步历史含循环，已停止。") }
            for id in ready { remaining.removeValue(forKey: id); visited.insert(id) }
        }
    }
    /// Journal recovery must run before detecting local edits, otherwise an imported value
    /// could be mistaken for a new local edit after termination between two saves.
    private func recoverImport() throws {
        guard let job = state.importing else { return }
        let actual = try local.snapshot()[job.key]
        if actual == job.before { try local.replace(job.key, expected: job.before, with: job.after) }
        var next = state
        if actual == job.before || actual == job.after {
            next.baselines.removeAll { $0.key == job.key }
            next.baselines.append(.init(key: job.key, payload: job.after, heads: job.heads))
        }
        // A local edit after the crash is preserved and captured against the old baseline.
        next.importing = nil; try save(next)
    }
    private func capture() throws {
        let snapshot = try local.snapshot()
        let unavailable = try local.unavailableKeys()
        guard snapshot.keys.allSatisfy({ kinds.contains($0.kind) }) else { throw SyncFailure("本机同步资料超出已许可范围，停止本轮。") }
        var next = state
        for key in Set(snapshot.keys).union(state.baselines.map(\.key)) {
            guard !unavailable.contains(key) else { continue }
            let old = state.baselines.first { $0.key == key }
            guard snapshot[key] != old?.payload else { continue }
            let row = SyncRecord(id: UUID(), key: key, parents: old?.heads ?? [], payload: snapshot[key], device: state.device)
            try row.validate(); next.records.append(row)
            next.baselines.removeAll { $0.key == key }
            next.baselines.append(.init(key: key, payload: row.payload, heads: [row.id]))
        }
        try Self.validate(next.records); try save(next)
    }
    private func importUnambiguous() throws {
        let unavailable = try local.unavailableKeys()
        for key in Set(state.records.map(\.key)) {
            let rows = heads(key)
            guard rows.count == 1, let row = rows.first else { continue }
            let old = state.baselines.first { $0.key == key }
            let repairing = unavailable.contains(key) && row.payload != nil
            guard old?.heads != [row.id] || repairing else { continue }
            var next = state
            next.importing = .init(key: key, before: repairing ? try local.snapshot()[key] : old?.payload, after: row.payload, heads: [row.id])
            try save(next); try recoverImport()
        }
    }
    func resolve(key: SyncRecord.Key, expectedHeads: Set<UUID>, selected: UUID, applyLocally: Bool = true) throws {
        guard enabled, !busy else { throw SyncFailure("请先开启同步并等待当前同步结束。") }
        if applyLocally { try recoverImport(); try capture() }
        else if state.importing != nil { throw SyncFailure("先等待上次聊天导入核对完成，再选择版本。") }
        let rows = heads(key)
        guard rows.count > 1, Set(rows.map(\.id)) == expectedHeads,
              let chosen = rows.first(where: { $0.id == selected }) else { throw SyncFailure("冲突版本已变化，请重新查看确认。") }
        var next = state
        next.records.append(.init(id: UUID(), key: key, parents: expectedHeads, payload: chosen.payload, device: state.device))
        try Self.validate(next.records); try save(next)
        // Chat confirmation itself is a working conversation. Leave its files untouched;
        // next sync captures any intervening local edit as a branch before importing.
        if applyLocally { try importUnambiguous() }
    }
    func synchronize() async throws {
        guard enabled else { throw SyncFailure("同步尚未开启。") }
        guard !busy else { throw SyncFailure("同步正在进行。") }
        busy = true; defer { busy = false }; let token = generation
        do {
            let account = try await checkAccount(token)
            let head = try await transport.head(account: account); try ready(token)
            try acceptEpoch(head)
            if state.adopting != true { try recoverImport(); try capture() }
            let fetched = try await transport.fetch(account: account, head: head)
            _ = try await checkAccount(token)
            try acceptEpoch(try await transport.head(account: account)); try ready(token)
            guard fetched.allSatisfy({ kinds.contains($0.key.kind) }) else { throw SyncFailure("云端同步资料范围不匹配，未导入。") }
            try Self.validate(fetched)
            // A complete fetch cannot silently lose previously acknowledged revisions.
            let remoteIDs = Set(fetched.map(\.id))
            guard state.sent.isSubset(of: remoteIDs) else { throw SyncFailure("云端历史缺失或被清除，暂停本轮；不自动重传旧资料。") }
            var map = Dictionary(uniqueKeysWithValues: state.records.map { ($0.id, $0) })
            for row in fetched {
                if let old = map[row.id], old != row { throw SyncFailure("同编号同步记录不一致。") }
                map[row.id] = row
            }
            var next = state; next.records = Array(map.values); next.sent.formUnion(remoteIDs)
            if state.adopting == true {
                let snapshot = try local.snapshot(), ancestors = Set(fetched.flatMap(\.parents))
                let current = fetched.filter { !ancestors.contains($0.id) }
                for key in Set(current.map(\.key)) {
                    let heads = current.filter { $0.key == key }
                    if heads.count == 1, let row = heads.first, snapshot[key] == row.payload {
                        next.baselines.append(.init(key: key, payload: row.payload, heads: [row.id]))
                    }
                }
                next.adopting = nil
            }
            try Self.validate(next.records); try save(next)
            // The user may have edited during fetch. Capture that branch before importing.
            try capture(); try importUnambiguous()
            // Parents must be delivered before children, including after partial failure.
            while let row = state.records.first(where: { !state.sent.contains($0.id) && $0.parents.isSubset(of: state.sent) }) {
                _ = try await checkAccount(token)
                try await transport.send(row, account: account, epoch: state.cloudEpoch)
                _ = try await checkAccount(token)
                var next = state; next.sent.insert(row.id); try save(next)
            }
            try ready(token)
            var finished = state; finished.lastSuccess = .now; try save(finished); warning = nil
        } catch {
            warning = (error as? SyncFailure)?.message ?? "同步未完成，保留本机数据与待同步记录；请检查网络和iCloud后重试。"
            throw error
        }
    }
}
