import Foundation

/// Device-local journal. Never restore/replay alarms from chat history or cloud backups.
@MainActor final class AlarmStore {
    private let file: URL
    private let device: any AlarmDevice
    private var loadError: String?
    private var busy = false
    private(set) var records: [ButlerAlarm] = []

    init(file: URL, device: any AlarmDevice, preparationError: String? = nil) {
        self.file = file
        self.device = device
        if let preparationError {
            loadError = preparationError
            return
        }
        do {
            records = try JSONDecoder().decode([ButlerAlarm].self, from: Data(contentsOf: file))
        } catch {
            let error = error as NSError
            if error.domain != NSCocoaErrorDomain || error.code != NSFileReadNoSuchFileError {
                loadError = "闹钟记录无法读取，原文件已保留；不能覆盖或猜测已有闹钟"
            }
        }
    }

    nonisolated deinit {}

    var authorization: String { device.authorization }

    private func requireReadable() throws {
        if let loadError { throw AlarmFailure(loadError) }
    }

    func record(_ id: UUID) throws -> ButlerAlarm {
        try requireReadable()
        guard let record = records.first(where: { $0.id == id }) else {
            throw AlarmFailure("找不到这个 Butler 闹钟，请先查询闹钟")
        }
        return record
    }

    func validate(_ change: ButlerAlarm.Change, now: Date = .now) throws {
        try requireReadable()
        let old = records.first { $0.id == change.id }
        if let revision = change.expectedRevision {
            guard old?.revision == revision else { throw AlarmFailure("闹钟已经变化，请查询最新记录后重新提出修改") }
        } else if old != nil { throw AlarmFailure("闹钟已存在，不能重复创建") }
        switch change {
        case .set(_, let title, let rule, _):
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200 else {
                throw AlarmFailure("闹钟内容需要 1–200 字")
            }
            try rule.validate(now: now)
        case .action(_, let action, _, let expiresAt):
            guard expiresAt > now else { throw AlarmFailure("这条闹钟操作已过期，请重新查询并确认，避免操作到下一次响铃") }
            guard let old else { throw AlarmFailure("闹钟不存在") }
            if action == .enable { try old.rule.validate(now: now) }
            if action == .pause || action == .resume {
                guard case .timer = old.rule else { throw AlarmFailure("暂停/继续只用于倒计时；重复闹钟请取消/启用") }
            }
        }
    }

    /// Passive reconciliation changes only local evidence. Missing system alarms are never recreated.
    @discardableResult func refresh() throws -> [SystemAlarm] {
        try requireReadable()
        guard !busy else { throw AlarmFailure("闹钟操作正在执行，请等待结果后再查询") }
        let live = try device.read()
        var next = records
        for index in next.indices {
            guard let operation = next[index].operation else { continue }
            let state = live.first { $0.id == next[index].systemID }?.state
            let retiredAreGone = !live.contains { operation.retiredIDs.contains($0.id) }
            let resolved: Bool
            switch operation.kind {
            case .schedule: resolved = state != nil && retiredAreGone
            case .cancel: resolved = state == nil && retiredAreGone
            case .stop: resolved = state == nil || state == .scheduled
            case .pause: resolved = state == .paused
            case .resume: resolved = state == .countdown
            }
            if resolved { next[index].operation = nil; next[index].lastError = nil }
        }
        if next != records { try save(next) }
        return live
    }

    /// The caller supplies the ID of an owner-confirmed proposal, not a model tool-call ID.
    func apply(_ change: ButlerAlarm.Change, operationID: UUID, now: Date = .now) async throws {
        try Task.checkCancellation()
        try requireReadable()
        guard !busy else { throw AlarmFailure("另一个闹钟操作正在执行，请查询结果后重试") }
        if let previous = records.first(where: { $0.operationID == operationID }) {
            // A replay never restarts a timer or stops a later occurrence of a repeating alarm.
            _ = try refresh()
            if try record(previous.id).operation != nil {
                throw AlarmFailure("上次操作结果仍待核实，请查询闹钟后重新确认，不会自动重复执行")
            }
            return
        }
        try validate(change, now: now)
        busy = true
        defer { busy = false }
        let schedules: Bool
        switch change {
        case .set: schedules = true
        case .action(_, let action, _, _): schedules = action == .enable
        }
        if schedules {
            guard try await device.authorize() else { throw AlarmFailure("闹钟权限未获允许，没有设置响铃，也没有改成普通通知") }
            // Authorization can take minutes. Recheck both time and revision after returning.
            try Task.checkCancellation()
            try validate(change, now: max(now, .now))
        }
        let live = try device.read()
        let old = records.first { $0.id == change.id }
        var next: ButlerAlarm
        switch change {
        case .set(let id, let title, let rule, _):
            next = ButlerAlarm(id: id, title: title, rule: rule, revision: (old?.revision ?? 0) + 1,
                               systemID: UUID(), enabled: true, operationID: operationID,
                               operation: .init(kind: .schedule, retiredIDs: retiredIDs(old)), lastError: nil)
        case .action(_, let action, _, _):
            guard var value = old else { throw AlarmFailure("闹钟不存在") }
            let state = live.first { $0.id == value.systemID }?.state
            switch action {
            case .enable:
                guard !value.enabled || state == nil else { throw AlarmFailure("闹钟已在系统中启用，不会重复启动") }
                value.operation = .init(kind: .schedule, retiredIDs: retiredIDs(old))
                value.systemID = UUID()
                value.enabled = true
            case .cancel:
                value.operation = .init(kind: .cancel, retiredIDs: value.operation?.retiredIDs ?? [])
                value.enabled = false
            case .stop, .pause, .resume:
                guard value.operation == nil else { throw AlarmFailure("上次操作尚未核实，请先查询闹钟") }
                let required: SystemAlarm.State = action == .stop ? .alerting : action == .pause ? .countdown : .paused
                guard state == required else { throw AlarmFailure("闹钟当前不是可\(action.summary)的状态，请重新查询") }
                let kind: ButlerAlarm.Operation.Kind = action == .stop ? .stop : action == .pause ? .pause : .resume
                value.operation = .init(kind: kind, retiredIDs: [])
            }
            value.revision += 1
            value.operationID = operationID
            value.lastError = nil
            next = value
        }
        // Journal before any side effect, including removal of the old revision.
        try replace(next)
        do {
            guard let operation = next.operation else { return }
            for id in operation.retiredIDs where live.contains(where: { $0.id == id }) {
                try device.cancel(id: id)
            }
            switch operation.kind {
            case .schedule:
                let remaining = try device.read()
                guard !remaining.contains(where: { operation.retiredIDs.contains($0.id) }) else {
                    throw AlarmFailure("旧闹钟尚未确认取消，没有创建新闹钟")
                }
                try await device.schedule(id: next.systemID, title: next.title, rule: next.rule)
            case .cancel:
                if live.contains(where: { $0.id == next.systemID }) { try device.cancel(id: next.systemID) }
            case .stop: try device.stop(id: next.systemID)
            case .pause: try device.pause(id: next.systemID)
            case .resume: try device.resume(id: next.systemID)
            }
            let observed = try device.read()
            let state = observed.first { $0.id == next.systemID }?.state
            let removed = !observed.contains { operation.retiredIDs.contains($0.id) }
            let accepted: Bool
            switch operation.kind {
            case .schedule: accepted = state != nil && removed
            case .cancel: accepted = state == nil && removed
            case .stop: accepted = state == nil || state == .scheduled
            case .pause: accepted = state == .paused
            case .resume: accepted = state == .countdown
            }
            guard accepted else { throw AlarmFailure("系统尚未返回预期状态，请查询核实；不会自动重试或重复创建") }
            next.operation = nil
            next.lastError = nil
            try replace(next)
        } catch {
            // Keep the pending operation even if the API accepted it before throwing or saving failed.
            var unresolved = try record(next.id)
            unresolved.lastError = error.localizedDescription
            try? replace(unresolved)
            throw AlarmFailure("操作未确认完成：\(error.localizedDescription)。请查询系统状态；旧闹钟可能已取消，不会自动重建。")
        }
    }

    private func retiredIDs(_ old: ButlerAlarm?) -> [UUID] {
        guard let old else { return [] }
        return Array(Set((old.operation?.retiredIDs ?? []) + [old.systemID]))
    }

    private func replace(_ value: ButlerAlarm) throws {
        var next = records
        if let index = next.firstIndex(where: { $0.id == value.id }) { next[index] = value }
        else { next.append(value) }
        try save(next)
    }

    private func save(_ values: [ButlerAlarm]) throws {
        try requireReadable()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: file, options: .atomic)
        records = values
    }
}
