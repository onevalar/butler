import Foundation

struct TaskDisplayTask: Equatable {
    let id: UUID
    let revision: Int
    let active: Bool
    var automaticEnd: Date? = nil
}

struct TaskDisplayChange: Codable, Equatable {
    enum Action: String, Codable { case start, end }
    let action: Action
    let taskID: UUID
    let expectedRevision: Int?
    let deadline: Date?
    let sessionID: UUID?
}

struct TaskDisplayRecord: Codable, Equatable, Identifiable {
    enum State: String, Codable { case requesting, active, ending, ended }
    let id: UUID // Also the confirmation operation ID and immutable ActivityKit attribute.
    let taskID: UUID
    let revision: Int
    let deadline: Date
    var state: State
    var systemID: String?
}

struct SystemTaskDisplay: Equatable {
    let id: String
    let sessionID: UUID
    let taskID: UUID
    let active: Bool // Includes ActivityKit stale, but not ended/dismissed.
}

@MainActor protocol TaskDisplayDevice {
    var enabled: Bool { get }
    func read() -> [SystemTaskDisplay]
    func start(_ record: TaskDisplayRecord) throws -> String
    func end(_ id: String) async
}

/// Device-local authorization journal. Never recreate a missing/dismissed activity during recovery.
@MainActor final class TaskDisplayStore {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    private let file: URL
    private let device: any TaskDisplayDevice
    private var readable = true
    private var busy = false
    private(set) var records: [TaskDisplayRecord] = []

    init(file: URL, device: any TaskDisplayDevice) {
        self.file = file; self.device = device
        do { records = try JSONDecoder().decode([TaskDisplayRecord].self, from: Data(contentsOf: file)) }
        catch {
            let error = error as NSError
            readable = error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
        }
    }
    nonisolated deinit {}

    var enabled: Bool { device.enabled }
    func read() throws -> [TaskDisplayRecord] {
        guard readable else { throw Failure("实时活动记录无法读取，原文件已保留，未重建或覆盖。") }
        return records
    }

    func validate(_ change: TaskDisplayChange, tasks: [TaskDisplayTask], now: Date = .now) throws {
        _ = try read()
        switch change.action {
        case .start:
            guard change.sessionID == nil, let revision = change.expectedRevision,
                  tasks.contains(where: { $0.id == change.taskID && $0.revision == revision && $0.active }) else {
                throw Failure("任务已改变、暂停或结束，请重新读取；展示不会创建任务。")
            }
            guard let deadline = change.deadline, deadline.timeIntervalSince1970.isFinite,
                  deadline > now, deadline.timeIntervalSince(now) <= 8 * 3600 else {
                throw Failure("展示必须有明确的未来截止时间，且距现在不超过8小时；不改变任务规则。")
            }
            if let end = tasks.first(where: { $0.id == change.taskID })?.automaticEnd, deadline > end {
                throw Failure("展示截止时间不能晚于任务自动结束时间。")
            }
        case .end:
            guard change.deadline == nil, change.expectedRevision == nil, let id = change.sessionID,
                  records.contains(where: { $0.id == id && $0.taskID == change.taskID }) else {
                throw Failure("请先查询实时活动，再按准确的展示编号关闭。")
            }
        }
    }

    func apply(_ change: TaskDisplayChange, operationID: UUID,
               tasks: () throws -> [TaskDisplayTask], now: Date = .now) async throws -> String {
        guard !busy else { throw Failure("正在核对实时活动，请稍后重试。") }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()
        _ = try read()
        if change.action == .start, records.contains(where: { $0.id == operationID }) {
            return "这次确认已执行过，没有重复开启；请查询当前展示状态。"
        }
        // Ending a display stays possible after its task has been deleted or become unreadable.
        try validate(change, tasks: change.action == .start ? tasks() : [], now: now)
        if change.action == .end {
            try await finish(change.sessionID!)
            return "已核对结束请求；没有完成或取消任务，也没有关闭闹钟。"
        }
        guard device.enabled else { throw Failure("系统未允许实时活动，请在系统设置检查；没有改成通知或闹钟。") }
        guard !records.contains(where: { $0.taskID == change.taskID && $0.state != .ended }),
              !device.read().contains(where: { $0.taskID == change.taskID && $0.active }) else {
            throw Failure("这个任务已有展示或结果待核对，请先查询；不会重复创建。")
        }
        var record = TaskDisplayRecord(id: operationID, taskID: change.taskID, revision: change.expectedRevision!,
            deadline: change.deadline!, state: .requesting)
        try save(records + [record]) // Durable authorization precedes Activity.request.
        record.systemID = try device.start(record)
        record.state = .active
        try replace(record)
        return "系统已接受展示请求，是否可见由系统决定；仅显示时间和状态，到期不代表任务完成。"
    }

    func reconcile(tasks: [TaskDisplayTask], now: Date = .now) async throws {
        guard !busy else { throw Failure("实时活动仍在执行，稍后核对。") }
        busy = true
        defer { busy = false }
        _ = try read()
        let system = device.read()
        for original in records {
            var record = original
            let matches = system.filter { $0.sessionID == record.id && $0.taskID == record.taskID && $0.active }
            guard !matches.isEmpty else {
                guard record.state != .ended else { continue }
                record.state = .ended
                try replace(record)
                continue // Dismissed, never appeared, or expired: never start again.
            }
            let unchanged = tasks.contains {
                $0.id == record.taskID && $0.revision == record.revision && $0.active
                    && ($0.automaticEnd.map { $0 > now } ?? true)
            }
            if record.state == .ended || record.state == .ending || record.deadline <= now || !unchanged {
                try await finish(record.id)
            } else {
                record.state = .active
                record.systemID = matches[0].id
                if record != original { try replace(record) }
            }
        }
    }

    private func finish(_ id: UUID) async throws {
        guard var record = records.first(where: { $0.id == id }) else { return }
        record.state = .ending
        try replace(record) // Survives a kill while awaiting end; recovery can only end, not start.
        for activity in device.read() where activity.sessionID == id && activity.taskID == record.taskID && activity.active {
            await device.end(activity.id)
        }
        guard !device.read().contains(where: { $0.sessionID == id && $0.active }) else {
            throw Failure("结束请求已发出，但系统仍报告展示存在；稍后查询，不会重复开启。")
        }
        record.state = .ended
        try replace(record)
    }

    private func replace(_ record: TaskDisplayRecord) throws {
        try save(records.map { $0.id == record.id ? record : $0 })
    }
    private func save(_ next: [TaskDisplayRecord]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        records = next
    }
}
