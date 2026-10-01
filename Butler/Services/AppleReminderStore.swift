import Foundation

/// Independent of ReminderStore: no mirroring, local notifications, or background write replay.
@MainActor final class AppleReminderStore {
    struct Operation: Codable, Sendable {
        let id: UUID
        let targetID: String
        let change: AppleReminderChange
        var succeeded = false
        var error: String?
    }

    private let device: any AppleReminderDevice
    private let file: URL
    private var loadError: String?
    private var busy = false
    private(set) var operations: [Operation] = []
    var authorization: String { device.authorization }

    init(file: URL, device: any AppleReminderDevice, preparationError: String? = nil) {
        self.file = file
        self.device = device
        loadError = preparationError
        guard preparationError == nil else { return }
        do { operations = try JSONDecoder().decode([Operation].self, from: Data(contentsOf: file)) }
        catch {
            let error = error as NSError
            if error.domain != NSCocoaErrorDomain || error.code != NSFileReadNoSuchFileError {
                loadError = "系统提醒事项操作记录无法读取，原文件已保留；为防止重复写入，请先修复存储"
            }
        }
    }

    nonisolated deinit {}

    private func ready() throws {
        if let loadError { throw AppleReminderFailure(loadError) }
        guard !busy else { throw AppleReminderFailure("系统提醒事项正在操作，请等待结果") }
        guard device.authorized else { throw AppleReminderFailure("尚未获准访问苹果提醒事项；请先提出访问授权并由用户确认") }
    }

    func lists() throws -> [AppleReminderList] { try ready(); return try device.lists() }

    func reminder(_ id: String) throws -> AppleReminderSnapshot {
        try ready()
        guard let value = try device.reminder(id: id) else {
            throw AppleReminderFailure("原系统标识已无法找到；可能被删除、移动或同步后改变，请重新查询，不会自动重建")
        }
        return value
    }

    func reminders(listID: String?) async throws -> [AppleReminderSnapshot] {
        try ready()
        busy = true
        defer { busy = false }
        let values = try await device.reminders(listID: listID)
        try Task.checkCancellation()
        guard device.authorized else { throw AppleReminderFailure("提醒事项访问权限已撤销") }
        return values
    }

    func validate(_ change: AppleReminderChange) throws {
        if case .access = change { return }
        try ready()
        switch change {
        case .access: break
        case .create(let list, let fields):
            try fields.validate()
            try validateList(list)
        case .edit(let before, let patch):
            guard let current = try device.reminder(id: before.id), current.revision == before.revision,
                  current.list.id == before.list.id else {
                throw AppleReminderFailure("系统提醒事项已变化或找不到，请重新查询后确认；不会覆盖外部修改")
            }
            try validateList(before.list)
            switch patch {
            case .title(let title):
                guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 300 else {
                    throw AppleReminderFailure("标题须为1–300字")
                }
            case .notes(let notes):
                guard (notes?.count ?? 0) <= 10_000 else { throw AppleReminderFailure("备注不超过10000字") }
            case .priority(let priority):
                guard (0...9).contains(priority) else { throw AppleReminderFailure("优先级为0–9") }
            case .schedule:
                guard current.scheduleEditable else {
                    throw AppleReminderFailure("这条提醒含位置、复杂重复或其他不可等价编辑的安排；可以改标题/备注，但不能静默覆盖原时间规则")
                }
                try patch.fields(after: before.fields).validate()
            case .completed, .delete: break
            }
        }
    }

    private func validateList(_ expected: AppleReminderList) throws {
        guard let current = try device.lists().first(where: { $0.id == expected.id }), current.writable,
              current.title == expected.title, current.source == expected.source else {
            throw AppleReminderFailure("目标列表已变化、只读或不可用，请重新选择；不会改写到其他列表")
        }
    }

    /// Receives the UUID of an owner-confirmed proposal. Tool/model call IDs cannot authorize writes.
    func apply(_ change: AppleReminderChange, operationID: UUID) async throws -> String {
        try Task.checkCancellation()
        if case .access = change {
            guard !busy else { throw AppleReminderFailure("提醒事项操作正在执行") }
            busy = true
            defer { busy = false }
            guard try await device.authorize() else { throw AppleReminderFailure("没有取得提醒事项权限，没有读写系统内容") }
            return "系统提醒事项访问已获准；尚未创建或修改任何提醒"
        }
        try ready()
        if let previous = operations.first(where: { $0.id == operationID }) {
            guard previous.change == change else { throw AppleReminderFailure("操作标识已使用，不能更改原操作内容") }
            if previous.succeeded { return "此前操作已核实，本次没有重复执行" }
            return try reconcile(operationID)
        }
        try validate(change)
        // An uncertain create cannot be silently retried under a fresh proposal UUID.
        if case .create = change, operations.contains(where: { !$0.succeeded && $0.change == change }) {
            throw AppleReminderFailure("相同创建操作的结果尚待核实，请查询操作记录和系统列表，不会再创建一份")
        }
        busy = true
        defer { busy = false }
        let id: String
        switch change {
        case .access: return ""
        case .create(let list, let fields): id = try device.prepare(listID: list.id, fields: fields)
        case .edit(let before, _): id = before.id
        }
        defer { device.discardPrepared(id: id) }
        guard !id.isEmpty else { throw AppleReminderFailure("系统未提供可记录的对象标识，没有写入") }
        var operation = Operation(id: operationID, targetID: id, change: change)
        try save(operations + [operation]) // Before any EventKit save/remove.
        do {
            switch change {
            case .create: try device.savePrepared(id: id)
            case .edit(let before, let patch): try device.edit(before: before, patch: patch)
            case .access: break
            }
            guard matches(operation, current: try device.reminder(id: id), confirmedDelete: true) else {
                throw AppleReminderFailure("系统未返回预期结果")
            }
            operation.succeeded = true
            try replace(operation)
            return "已读回核对系统结果；不代表通知已送达"
        } catch {
            operation.succeeded = false
            operation.error = error.localizedDescription
            try? replace(operation)
            throw AppleReminderFailure("操作结果待核实：\(error.localizedDescription)。不会自动重试；请查询系统对象和操作记录。")
        }
    }

    /// Explicit read-only reconciliation. Never treat a lost ID as proof of a successful deletion.
    func reconcile(_ operationID: UUID) throws -> String {
        try ready()
        guard var operation = operations.first(where: { $0.id == operationID }) else {
            throw AppleReminderFailure("找不到这次操作")
        }
        if operation.succeeded { return "此前操作已核实，本次没有重复执行" }
        guard matches(operation, current: try device.reminder(id: operation.targetID), confirmedDelete: false) else {
            throw AppleReminderFailure("仍无法确认操作结果；标识失效不等于删除成功，不会自动重建或重试")
        }
        operation.succeeded = true; operation.error = nil
        try replace(operation)
        return "当前系统内容与已确认的目标一致；没有重复写入"
    }

    private func matches(_ operation: Operation, current: AppleReminderSnapshot?, confirmedDelete: Bool) -> Bool {
        switch operation.change {
        case .access: return false
        case .create(let list, let fields): return current?.list.id == list.id && current?.fields == fields && current?.completed == false
        case .edit(let before, let patch):
            if case .delete = patch { return confirmedDelete && current == nil }
            guard let current, current.list.id == before.list.id else { return false }
            switch patch {
            case .title(let title): return current.fields.title == title
            case .notes(let notes): return current.fields.notes == notes
            case .priority(let priority): return current.fields.priority == priority
            case .schedule(let due, let recurrence, let notify):
                return current.fields.due == due && current.fields.recurrence == recurrence && current.fields.notifyAtDue == notify && current.scheduleEditable
            case .completed(let completed): return current.completed == completed
            case .delete: return false
            }
        }
    }

    private func replace(_ operation: Operation) throws {
        try save(operations.map { $0.id == operation.id ? operation : $0 })
    }

    private func save(_ values: [Operation]) throws {
        if let loadError { throw AppleReminderFailure(loadError) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: file, options: .atomic)
        operations = values
    }
}
