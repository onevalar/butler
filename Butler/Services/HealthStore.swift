import Foundation

/// No ongoing read grant: every native read is the result of one explicit confirmation.
@MainActor final class HealthStore {
    struct Operation: Codable {
        enum State: String, Codable { case pending, succeeded, closedUnverified }
        let id: UUID
        let token: HealthWriteToken
        var state: State = .pending
    }
    private let file: URL
    private let device: any HealthDevice
    private var storageFailed = false
    private var busy = false
    private var operations: [Operation] = []
    // Confirmed read IDs prevent a double tap from silently refreshing its authorized snapshot.
    private var readOperations: Set<UUID> = []

    init(file: URL, device: any HealthDevice, preparationFailed: Bool = false) {
        self.file = file; self.device = device; storageFailed = preparationFailed
        guard !preparationFailed else { return }
        do { operations = try JSONDecoder().decode([Operation].self, from: Data(contentsOf: file)) }
        catch {
            let e = error as NSError
            storageFailed = e.domain != NSCocoaErrorDomain || e.code != NSFileReadNoSuchFileError
        }
    }
    nonisolated deinit {}
    var available: Bool { device.available }
    func receipts() throws -> [Operation] {
        guard !storageFailed else { throw HealthFailure("健康操作记录无法读取，未覆盖文件，也未重复执行。") }
        return operations
    }

    func apply(_ change: HealthChange, operationID: UUID, now: Date = .now) async throws -> HealthLocalResult {
        _ = try receipts()
        guard available, !busy else { throw HealthFailure("健康功能不可用或另一个操作仍在执行，请稍后再试。") }
        try change.validate(now: now)
        try Task.checkCancellation()
        busy = true; defer { busy = false }
        if let previous = operations.first(where: { $0.id == operationID }) {
            return .init(receipt: "本次确认已执行过，记录状态：\(previous.state.rawValue)。没有重复写入，非succeeded状态不代表系统成功。", localText: nil)
        }
        if case .closeVerification(let id) = change {
            guard let index = operations.firstIndex(where: { $0.id == id }), operations[index].state == .pending else {
                throw HealthFailure("没有该编号的待核对操作。")
            }
            var next = operations; next[index].state = .closedUnverified; try save(next)
            return .init(receipt: "已按你的确认结束等待核对，未认定原操作成功或失败，也未重试、撤销或修改健康记录。以后新增需避免重复。", localText: nil)
        }
        if case .verify(let id) = change {
            guard let index = operations.firstIndex(where: { $0.id == id }) else { throw HealthFailure("找不到操作编号。") }
            if operations[index].state == .succeeded { return .init(receipt: "此前操作已成功，未重新读取或写入。", localText: nil) }
            // Absence cannot prove deletion when read authorization is hidden. Never infer success.
            guard operations[index].token.action == .save else {
                throw HealthFailure("删除回执丢失，查不到记录不能证明删除成功。请在健康App核对，不会自动重试。")
            }
            let found: Bool
            do { found = try await device.verify(operations[index].token) }
            catch is CancellationError { throw CancellationError() }
            catch { throw HealthFailure("本次健康核对未完成，请解锁手机并检查权限；未重复写入。") }
            guard found else {
                throw HealthFailure("尚不能核实写入；可能无可读数据、权限受限或设备锁定，不会自动重建。")
            }
            try Task.checkCancellation()
            var next = operations; next[index].state = .succeeded; try save(next)
            return .init(receipt: "已找到本应用对应写入，没有再次保存。", localText: nil)
        }
        guard !readOperations.contains(operationID) else {
            return .init(receipt: "本次读取确认已使用，没有再次读取；刷新数据需新的确认。", localText: nil)
        }
        if !change.writeTypes.isEmpty, operations.contains(where: { $0.state == .pending }) {
            throw HealthFailure("已有健康写入结果待核实，先核对原操作，防止重新提议造成重复记录。")
        }
        do {
            try await device.authorize(read: change.readTypes, write: change.writeTypes)
            try Task.checkCancellation()
            guard change.writeTypes.allSatisfy({ device.canWrite($0) }) else {
                throw HealthFailure("所需类型的健康写入权限未获准或已撤销，没有写入。")
            }
            switch change {
            case .summary(let metrics, let range):
                readOperations.insert(operationID)
                let text = try await device.summary(metrics, range: range)
                try Task.checkCancellation()
                return .init(receipt: "本次健康查询已完成，结果仅在前台临时显示，未发送给AI；空结果不代表零或拒绝授权。", localText: text)
            case .ownRecords(let metric, let range):
                readOperations.insert(operationID)
                let text = try await device.ownRecords(metric, range: range)
                try Task.checkCancellation()
                return .init(receipt: "本应用健康记录查询已完成，结果仅在前台临时显示，未发送给AI；纠正/删除须用准确编号另行确认。", localText: text)
            default: break
            }
            let token = try await device.prepare(change, operationID: operationID)
            defer { device.discard(token) }
            try Task.checkCancellation()
            guard change.writeTypes.allSatisfy({ device.canWrite($0) }) else { throw HealthFailure("写入权限已变化，未保存。") }
            var operation = Operation(id: operationID, token: token)
            try save(operations + [operation]) // Must survive before any HealthKit mutation.
            do {
                try await device.commit(token)
                // A completed system callback is a receipt; do not require read permission to save.
                operation.state = .succeeded
                try save(operations.map { $0.id == operationID ? operation : $0 })
            } catch {
                throw HealthFailure("健康操作结果待核对，操作编号：\(operationID.uuidString)。没有自动重试；请在健康App核对。")
            }
            return .init(receipt: "健康系统已接受本次修改；未更改任务或库存，不代表跨设备同步完成。", localText: nil)
        } catch let error as HealthFailure { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw HealthFailure("健康操作未完成；请检查设备是否已解锁、系统授权及数据是否可用。没有发送健康查询结果给AI。") }
    }

    private func save(_ next: [Operation]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        operations = next
    }
}
