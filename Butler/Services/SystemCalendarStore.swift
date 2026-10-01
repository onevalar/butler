import Foundation

@MainActor final class SystemCalendarStore {
    struct Operation: Codable {
        let id: UUID
        let change: SystemCalendarChange
        var key: CalendarEventKey
        var succeeded = false
        var error: String?
    }
    private struct State: Codable {
        var conversationAllowed = false
        var operations: [Operation] = []
    }
    private var state = State()
    private let file: URL
    private let device: any SystemCalendarDevice
    private var storageError: String?
    private var busy = false
    var conversationAllowed: Bool { state.conversationAllowed }
    var systemAuthorized: Bool { device.authorized }

    init(file: URL, device: any SystemCalendarDevice, preparationError: String? = nil) {
        self.file = file; self.device = device; storageError = preparationError
        guard preparationError == nil else { return }
        do { state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) }
        catch {
            let e = error as NSError
            if e.domain != NSCocoaErrorDomain || e.code != NSFileReadNoSuchFileError {
                storageError = "日历操作记录损坏或不可读，已停止对话访问，未覆盖原记录"
            }
        }
    }

    nonisolated deinit {}

    private func ready() throws {
        if let storageError { throw CalendarFailure(storageError) }
        guard !busy else { throw CalendarFailure("日历操作正在执行") }
        guard conversationAllowed, device.authorized else {
            throw CalendarFailure("请先确认允许对话使用日历；首页展示授权不等于允许发送给模型")
        }
    }

    func calendars() throws -> [SystemCalendarList] { try ready(); return try device.calendars() }
    func event(_ key: CalendarEventKey) throws -> SystemCalendarEvent {
        try ready()
        guard let event = try device.event(key) else { throw CalendarFailure("找不到原事件，可能已移动、删除或同步后标识改变；请重新查询，不会重建") }
        return event
    }
    func events(start: Date, end: Date, calendarID: String?) throws -> [SystemCalendarEvent] {
        try ready()
        guard end > start, end.timeIntervalSince(start) <= 366 * 86400 else { throw CalendarFailure("查询范围须大于0且不超过366天") }
        return try device.events(start: start, end: end, calendarID: calendarID)
    }
    func operations() throws -> [Operation] { try ready(); return state.operations }

    func validate(_ change: SystemCalendarChange) throws {
        if case .access = change { return }
        try ready()
        let target: SystemCalendarList
        switch change {
        case .access: return
        case .create(let calendar, let fields, let frequency):
            target = calendar
            try fields.validate()
            guard frequency == nil || ["daily", "weekly", "monthly", "yearly"].contains(frequency!) else {
                throw CalendarFailure("仅支持每日/周/月/年重复，其他规则不能简化")
            }
        case .edit(let before, let patch, let span):
            let current = try event(before.key)
            guard current.revision == before.revision, current.calendar == before.calendar, current.editable else {
                throw CalendarFailure("事件已变化或不可编辑；含邀请/参与人的事件不通过此工具修改")
            }
            guard span == .thisEvent || current.recurring else { throw CalendarFailure("非重复事件只能选择仅这一次") }
            if case .schedule = patch, !current.scheduleEditable { throw CalendarFailure("包含复杂通知或位置安排，不能静默覆盖时间设置") }
            if case .delete = patch {} else { try patch.fields(after: before.fields).validate() }
            target = before.calendar
        }
        guard try device.calendars().contains(target), target.writable else { throw CalendarFailure("目标日历已变化或只读，请重新查询") }
    }

    func apply(_ change: SystemCalendarChange, operationID: UUID) async throws -> String {
        try Task.checkCancellation()
        if case .access(let allowed) = change {
            if let storageError { throw CalendarFailure(storageError) }
            guard !busy else { throw CalendarFailure("日历操作正在执行") }
            busy = true; defer { busy = false }
            if allowed {
                guard try await device.authorize() else { throw CalendarFailure("系统日历权限未获准") }
                try Task.checkCancellation()
            }
            var next = state; next.conversationAllowed = allowed; try save(next)
            return allowed ? "已允许按请求将相关日历内容用于对话；未读取或修改事件" : "已关闭后续对话日历访问；首页展示不受影响，历史对话中的内容不会自动删除"
        }
        try ready()
        if let old = state.operations.first(where: { $0.id == operationID }) {
            guard old.change == change else { throw CalendarFailure("操作标识已使用") }
            return try reconcile(operationID)
        }
        try validate(change)
        if state.operations.contains(where: { !$0.succeeded && $0.change == change }) {
            throw CalendarFailure("相同操作结果待核实，不会重复执行")
        }
        busy = true; defer { busy = false }
        let key: CalendarEventKey
        switch change {
        case .access: return ""
        case .create(let calendar, let fields, let frequency): key = try device.prepare(calendarID: calendar.id, fields: fields, frequency: frequency)
        case .edit(let before, _, _): key = before.key
        }
        defer { device.discardPrepared(key) }
        guard !key.itemID.isEmpty else { throw CalendarFailure("系统未提供可记录的标识，未写入") }
        var operation = Operation(id: operationID, change: change, key: key)
        var next = state; next.operations.append(operation); try save(next)
        do {
            switch change {
            case .create: operation.key = try device.savePrepared(key)
            case .edit(let before, let patch, let span): operation.key = try device.edit(before, patch: patch, span: span) ?? key
            case .access: break
            }
            // Persist a changed occurrence ID after a native series split, before readback.
            try replace(operation)
            guard try matches(operation, justDeleted: true) else { throw CalendarFailure("读回内容与预期不符") }
            operation.succeeded = true; try replace(operation)
            return "系统已接受所选范围的操作，并核对目标事件；不代表云端同步或通知送达，后续重复实例仍以系统查询为准"
        } catch {
            operation.succeeded = false; operation.error = error.localizedDescription
            try? replace(operation)
            throw CalendarFailure("日历操作结果待核实：\(error.localizedDescription)。不会自动重试或重建，请查询操作记录。")
        }
    }

    func reconcile(_ id: UUID) throws -> String {
        try ready()
        guard var operation = state.operations.first(where: { $0.id == id }) else { throw CalendarFailure("找不到操作记录") }
        if operation.succeeded { return "此前操作已核实，本次未重复写入" }
        // A future-series change cannot be proven from one occurrence after a lost reply.
        if case .edit(_, _, .futureEvents) = operation.change { throw CalendarFailure("后续重复范围的结果不明，请查询系统日历核对；不会重复执行") }
        guard try matches(operation, justDeleted: false) else { throw CalendarFailure("尚不能核实；标识失效不等于删除成功，不会自动重建") }
        operation.succeeded = true; operation.error = nil; try replace(operation)
        return "当前目标内容与已确认操作一致，没有再次写入"
    }

    private func matches(_ op: Operation, justDeleted: Bool) throws -> Bool {
        let current = try device.event(op.key)
        switch op.change {
        case .access: return false
        case .create(let calendar, let fields, let frequency):
            return current?.calendar.id == calendar.id && current?.fields == fields && current?.recurrenceDescription == (frequency ?? "none")
        case .edit(let before, let patch, _):
            if case .delete = patch { return justDeleted && current == nil }
            guard let current, current.calendar.id == before.calendar.id else { return false }
            let expected = patch.fields(after: before.fields)
            switch patch {
            case .title: return current.fields.title == expected.title
            case .notes: return current.fields.notes == expected.notes
            case .location: return current.fields.location == expected.location
            case .schedule: return current.fields == expected && current.scheduleEditable
            case .delete: return false
            }
        }
    }
    private func replace(_ operation: Operation) throws {
        var next = state; next.operations = next.operations.map { $0.id == operation.id ? operation : $0 }; try save(next)
    }
    private func save(_ value: State) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: .atomic); state = value
    }
}
