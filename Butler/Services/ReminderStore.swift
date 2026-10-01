import Foundation
import Observation
import UserNotifications

struct TimedReminder: Codable, Identifiable, Equatable {
    enum Repeat: String, Codable { case none, daily, weekly }
    enum Status: String, Codable { case active, paused, completed, cancelled }

    var id: UUID
    var text: String
    var fireDate: Date
    var repeats: Repeat
    var createdAt: Date
    var status: Status
    var revision: Int
    var endDate: Date?
    var autoCompleteAt: Date?
    var phases: [ReminderPhase]?
    var timeZoneIdentifier: String
    var activity: [ReminderActivity]
    /// Device-local: a received task is visible but does not acquire notification ownership.
    var syncReceived: Bool? = nil

    init(id: UUID = UUID(), text: String, fireDate: Date, repeats: Repeat = .none, createdAt: Date = .now,
         status: Status = .active, revision: Int = 1, endDate: Date? = nil, autoCompleteAt: Date? = nil,
         phases: [ReminderPhase]? = nil, timeZoneIdentifier: String = TimeZone.current.identifier,
         activity: [ReminderActivity] = []) {
        self.id = id; self.text = text; self.fireDate = fireDate; self.repeats = repeats; self.createdAt = createdAt
        self.status = status; self.revision = revision; self.endDate = endDate; self.autoCompleteAt = autoCompleteAt
        self.phases = phases; self.timeZoneIdentifier = timeZoneIdentifier; self.activity = activity
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, fireDate, repeats, createdAt, status, revision, endDate, autoCompleteAt, phases, timeZoneIdentifier, activity, syncReceived
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        fireDate = try values.decode(Date.self, forKey: .fireDate)
        repeats = try values.decodeIfPresent(Repeat.self, forKey: .repeats) ?? .none
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? fireDate
        status = try values.decodeIfPresent(Status.self, forKey: .status) ?? .active
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        endDate = try values.decodeIfPresent(Date.self, forKey: .endDate)
        autoCompleteAt = try values.decodeIfPresent(Date.self, forKey: .autoCompleteAt)
        phases = try values.decodeIfPresent([ReminderPhase].self, forKey: .phases)
        timeZoneIdentifier = try values.decodeIfPresent(String.self, forKey: .timeZoneIdentifier) ?? TimeZone.current.identifier
        activity = try values.decodeIfPresent([ReminderActivity].self, forKey: .activity) ?? []
        syncReceived = try values.decodeIfPresent(Bool.self, forKey: .syncReceived)
    }

    var statusLabel: String {
        switch status { case .active: "进行中"; case .paused: "已暂停"; case .completed: "已完成"; case .cancelled: "已取消" }
    }

    var whenLabel: String {
        let calendar = ReminderSchedule.calendar(for: self)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: fireDate)
        let base: String
        if let phases {
            base = "分 \(phases.count) 个阶段提醒"
        } else {
            switch repeats {
            case .daily: base = "每天 \(time)"
            case .weekly:
                formatter.dateFormat = "EEEE HH:mm"
                base = "每\(formatter.string(from: fireDate).replacingOccurrences(of: "星期", with: "周"))"
            case .none:
                if calendar.isDateInToday(fireDate) { base = "今天 \(time)" }
                else if calendar.isDateInTomorrow(fireDate) { base = "明天 \(time)" }
                else { formatter.dateFormat = "M月d日 HH:mm"; base = formatter.string(from: fireDate) }
            }
        }
        let zone = calendar.timeZone.identifier == TimeZone.current.identifier ? "" : " · \(calendar.timeZone.identifier)"
        return base + zone
    }

    func isUpcoming(now: Date = .now) -> Bool { !ReminderSchedule.preview(self, now: now, limit: 1).isEmpty }
}

/// Task records are durable; finishing or cancelling never deletes their history.
@MainActor @Observable
final class ReminderStore {
    private let file: URL
    private let schedules: Bool
    private var loadFailed = false
    private(set) var reminders: [TimedReminder] = []
    private(set) var scheduleWarning: String?
    private var scheduleTask: Task<Void, Never>?
    @ObservationIgnored private var completionTask: Task<Void, Never>?
    private var scheduleGeneration = 0
    private static weak var deviceStore: ReminderStore?
    static let prefix = "butler.reminder."
    /// App policy: reserve room for inventory notifications rather than filling every OS slot.
    static let notificationBudget = 40

    init(file: URL, schedules: Bool = true) {
        self.file = file
        self.schedules = schedules
        do {
            let data = try Data(contentsOf: file)
            reminders = try JSONDecoder().decode([TimedReminder].self, from: data)
        } catch {
            let nsError = error as NSError
            if nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileReadNoSuchFileError {
                loadFailed = true
                scheduleWarning = "提醒记录暂时无法读取，原文件已保留。"
            }
        }
    }

    nonisolated deinit { completionTask?.cancel() }

    static func openOnDevice() -> ReminderStore {
        if let deviceStore { return deviceStore }
        let directory = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        let store = ReminderStore(file: directory.appendingPathComponent("reminders.json"))
        deviceStore = store
        return store
    }

    /// Task visibility is independent of whether another notification is scheduled.
    var active: [TimedReminder] { reminders.filter { $0.status == .active } }

    var upcoming: [TimedReminder] {
        reminders.filter { $0.isUpcoming() }.sorted {
            (ReminderSchedule.preview($0, limit: 1).first ?? .distantFuture) <
                (ReminderSchedule.preview($1, limit: 1).first ?? .distantFuture)
        }
    }

    func reminder(id: UUID) -> TimedReminder? { reminders.first { $0.id == id } }

    /// System entry points must not report unreadable storage as an empty task list.
    func tasksForSystemEntry(now: Date = .now) throws -> [TimedReminder] {
        guard !loadFailed else { throw ReminderSchedule.InvalidRule(message: "任务记录无法读取，请先打开小当家检查；不能把读取失败当成没有待办") }
        try refresh(now: now)
        return reminders
    }

    func todayTasksForSystemEntry(now: Date = .now, calendar: Calendar = .current) throws -> [TimedReminder] {
        _ = try tasksForSystemEntry(now: now)
        return try todayTaskSnapshot(now: now, calendar: calendar)
    }

    /// Read-only projection: widget refresh must not itself complete or reschedule a task.
    func todayTaskSnapshot(now: Date = .now, calendar: Calendar = .current) throws -> [TimedReminder] {
        let today = calendar.startOfDay(for: now)
        return try taskSnapshot().filter { task in
            guard task.status == .active, task.autoCompleteAt.map({ $0 > now }) ?? true else { return false }
            return !ReminderSchedule.occurrences(task, on: today, calendar: calendar).isEmpty
                || (task.fireDate < today && ReminderSchedule.preview(task, now: today.addingTimeInterval(-0.001), limit: 1).isEmpty)
        }.sorted { $0.fireDate < $1.fireDate }
    }

    func taskSnapshot() throws -> [TimedReminder] {
        guard !loadFailed else { throw ReminderSchedule.InvalidRule(message: "任务记录无法读取") }
        return reminders
    }

    func tasksForSync() throws -> [TimedReminder] {
        let current = try taskSnapshot()
        let disk = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode([TimedReminder].self, from: Data(contentsOf: file)) : []
        guard disk == current else { throw SyncFailure("任务文件在其他位置变化，先重新载入再同步。") }
        return current
    }

    /// Called by the sync journal after comparing the complete portable record.
    func receiveSyncedTask(_ id: UUID, value: TimedReminder?) throws {
        _ = try taskSnapshot()
        let old = reminder(id: id)
        var next = reminders.filter { $0.id != id }
        if var value {
            guard value.id == id else { throw SyncFailure("任务编号不一致。") }
            try ReminderSchedule.validate(value)
            value.revision = max(value.revision, (old?.revision ?? 0) + 1)
            value.syncReceived = old?.syncReceived ?? (old == nil ? true : nil)
            next.append(value)
        }
        try save(next)
        // Reconcile cancellations without executing automatic completion inside this import.
        guard schedules else { return }
        scheduleGeneration += 1
        let previous = scheduleTask
        scheduleTask = Task { [weak self] in await previous?.value; await self?.rebuildNotifications() }
    }

    /// Recheck after an asynchronous Siri confirmation. No await between validation and save.
    func complete(_ id: UUID, expectedRevision: Int) throws {
        _ = try tasksForSystemEntry()
        guard let task = reminder(id: id), task.revision == expectedRevision,
              task.status == .active || task.status == .paused else {
            throw ReminderSchedule.InvalidRule(message: "任务已改变、结束或不存在，请重新选择并确认")
        }
        try complete(id)
    }

    func add(_ reminder: TimedReminder) throws {
        try ReminderSchedule.validate(reminder)
        guard self.reminder(id: reminder.id) == nil else { throw ReminderSchedule.InvalidRule(message: "这个任务已经保存") }
        var saved = reminder
        saved.activity.append(ReminderActivity(kind: "created", detail: "创建任务：\(reminder.whenLabel)"))
        try save(reminders + [saved])
        rescheduleAll()
    }

    func update(_ reminder: TimedReminder) throws {
        try ReminderSchedule.validate(reminder)
        guard let old = self.reminder(id: reminder.id) else { throw ReminderSchedule.InvalidRule(message: "任务不存在") }
        guard old.revision == reminder.revision else { throw ReminderSchedule.InvalidRule(message: "任务已发生变化，请读取最新任务后重试") }
        guard old.status != .completed, old.status != .cancelled else { throw ReminderSchedule.InvalidRule(message: "已结束任务不能修改，请新建任务") }
        var saved = reminder
        saved.createdAt = old.createdAt
        saved.status = old.status
        saved.syncReceived = old.syncReceived
        saved.revision = old.revision + 1
        saved.activity = old.activity + [ReminderActivity(kind: "updated", detail: "修改提醒规则：\(reminder.whenLabel)")]
        try save(reminders.map { $0.id == saved.id ? saved : $0 })
        rescheduleAll()
    }

    func complete(_ id: UUID) throws { try transition(id, to: .completed, kind: "completed", detail: "标记为已完成") }
    func pause(_ id: UUID) throws { try transition(id, to: .paused, kind: "paused", detail: "暂停提醒") }
    func resume(_ id: UUID) throws { try transition(id, to: .active, kind: "resumed", detail: "恢复提醒") }
    func remove(_ id: UUID) throws { try transition(id, to: .cancelled, kind: "cancelled", detail: "取消任务") }

    /// Explicit deletion, unlike cancellation. Persist first, then remove its scheduled notifications.
    func delete(_ id: UUID, expectedRevision: Int) throws {
        guard let task = reminder(id: id), task.revision == expectedRevision else {
            throw ReminderSchedule.InvalidRule(message: "任务已改变或不存在，请重新查看后删除")
        }
        try save(reminders.filter { $0.id != id })
        rescheduleAll()
    }

    /// Explicit correction from task management; normal resume still only resumes paused tasks.
    func reopen(_ id: UUID, now: Date = .now) throws {
        guard var reminder = reminder(id: id) else { throw ReminderSchedule.InvalidRule(message: "任务不存在") }
        guard reminder.status == .completed || reminder.status == .cancelled else { return }
        reminder.status = .active
        reminder.revision += 1
        let expiredAutomatic = reminder.autoCompleteAt.map { $0 <= now } ?? false
        if expiredAutomatic { reminder.autoCompleteAt = nil }
        reminder.activity.append(ReminderActivity(date: now, kind: "reopened",
            detail: "重新标记为未完成" + (expiredAutomatic ? "；清除已过期的自动完成时间" : "")))
        try save(reminders.map { $0.id == id ? reminder : $0 })
        rescheduleAll()
    }

    private func transition(_ id: UUID, to status: TimedReminder.Status, kind: String, detail: String) throws {
        guard var reminder = reminder(id: id) else { throw ReminderSchedule.InvalidRule(message: "任务不存在") }
        guard reminder.status != status else { return }
        guard reminder.status != .completed, reminder.status != .cancelled else { return }
        if status == .active, reminder.status != .paused { return }
        reminder.status = status
        reminder.revision += 1
        reminder.activity.append(ReminderActivity(kind: kind, detail: detail))
        try save(reminders.map { $0.id == id ? reminder : $0 })
        rescheduleAll()
    }

    /// Called on foreground and before rebuilding. Auto-completion is an explicit user rule.
    func refresh(now: Date = .now) throws {
        var changed = false
        let next = reminders.map { original in
            var reminder = original
            if (reminder.status == .active || reminder.status == .paused),
               let automatic = reminder.autoCompleteAt, automatic <= now {
                reminder.status = .completed
                reminder.revision += 1
                reminder.activity.append(ReminderActivity(date: automatic, kind: "autoCompleted", detail: "按约定时间自动结束"))
                changed = true
            }
            return reminder
        }
        if changed { try save(next) }
    }

    func reload() {
        do {
            let data = try Data(contentsOf: file)
            reminders = try JSONDecoder().decode([TimedReminder].self, from: data)
            loadFailed = false
            rescheduleAll()
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
                // Restoring a backup made before reminders existed removes this file.
                reminders = []
                loadFailed = false
                rescheduleAll()
            } else {
                loadFailed = true
                scheduleWarning = "提醒记录暂时无法读取，未替换现有任务；暂不能覆盖保存。"
            }
        }
        if schedules { WidgetSnapshotPublisher.shared.refresh(); TaskDisplayService.reconcile() }
    }

    func rescheduleAll() {
        completionTask?.cancel()
        completionTask = nil
        guard !loadFailed else { return }
        do { try refresh() } catch { scheduleWarning = "任务状态未能保存：\(error.localizedDescription)"; return }
        guard schedules else { return }
        armAutoCompletion()
        scheduleGeneration += 1
        let previous = scheduleTask
        scheduleTask = Task { [weak self] in
            await previous?.value
            await self?.rebuildNotifications()
        }
    }

    /// Updates the visible task while the app remains open. The system may suspend this
    /// task in the background; pre-scheduled notifications already stop at the deadline,
    /// and foreground reconciliation remains the source of truth after suspension.
    private func armAutoCompletion() {
        let now = Date.now
        guard let next = reminders.filter({ $0.status == .active || $0.status == .paused })
            .compactMap(\.autoCompleteAt).min() else { return }
        let delay = min(max(0, next.timeIntervalSince(now)), 24 * 3600)
        completionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(100)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.rescheduleAll()
        }
    }

    /// Notification actions wait for cancellation before releasing their background callback.
    func waitForScheduling() async { await scheduleTask?.value }

    /// Notification buttons supply a revision so an old notification cannot mutate a newer plan.
    func completeFromNotification(id: UUID, revision: Int) throws {
        guard let reminder = reminder(id: id), reminder.status == .active, reminder.revision == revision else { return }
        try complete(id)
    }

    func snooze(id: UUID, revision: Int, minutes: Int = 10) async throws {
        guard let reminder = reminder(id: id), reminder.syncReceived != true, reminder.status == .active, reminder.revision == revision else { return }
        let fire = Date.now.addingTimeInterval(Double(minutes) * 60)
        guard minutes >= 1, reminder.endDate.map({ fire <= $0 }) ?? true,
              reminder.autoCompleteAt.map({ fire < $0 }) ?? true else {
            throw ReminderSchedule.InvalidRule(message: "稍后提醒会超过任务结束时间")
        }
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        guard !loadFailed else { throw ReminderSchedule.InvalidRule(message: "原提醒记录无法读取，暂不能添加稍后提醒") }
        guard pending.filter({ $0.identifier.hasPrefix(Self.prefix) }).count < Self.notificationBudget else {
            scheduleWarning = "待发提醒已达到本应用的 \(Self.notificationBudget) 条预算，暂时无法添加稍后提醒。"
            throw ReminderSchedule.InvalidRule(message: scheduleWarning!)
        }
        guard self.reminder(id: id)?.revision == revision else { return }
        let request = datedRequest(reminder, fire: fire, suffix: "snooze.\(UUID().uuidString)")
        try await center.add(request)
        guard self.reminder(id: id)?.revision == revision, self.reminder(id: id)?.status == .active else {
            center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
            return
        }
        var updated = self.reminder(id: id) ?? reminder
        updated.activity.append(ReminderActivity(kind: "snoozed", detail: "\(minutes) 分钟后再提醒"))
        do { try save(reminders.map { $0.id == id ? updated : $0 }) }
        catch {
            center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
            throw error
        }
    }

    private func save(_ next: [TimedReminder]) throws {
        guard !loadFailed else { throw ReminderSchedule.InvalidRule(message: "原提醒记录无法读取，暂不能覆盖保存") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        reminders = next
        if schedules { WidgetSnapshotPublisher.shared.refresh(); TaskDisplayService.reconcile() }
    }

    private func content(_ reminder: TimedReminder) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "小当家提醒"
        content.body = reminder.text
        content.sound = .default
        content.categoryIdentifier = NotificationManager.reminderCategory
        content.userInfo = ["reminderID": reminder.id.uuidString, "reminderRevision": reminder.revision]
        return content
    }

    private func datedRequest(_ reminder: TimedReminder, fire: Date, suffix: String? = nil) -> UNNotificationRequest {
        let calendar = ReminderSchedule.calendar(for: reminder)
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let suffix = suffix ?? "date.\(Int(fire.timeIntervalSince1970))"
        return UNNotificationRequest(identifier: "\(Self.prefix)\(reminder.id).r\(reminder.revision).\(suffix)",
                                     content: content(reminder), trigger: trigger)
    }

    private func rebuildNotifications() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        guard !loadFailed else { return }
        let generation = scheduleGeneration
        let snapshot = reminders.filter { $0.syncReceived != true }
        let now = Date.now
        var candidates: [(Date, UNNotificationRequest)] = []
        var limited = Set<String>()
        // Preserve only snoozes still belonging to the current active revision.
        for request in pending where request.identifier.hasPrefix(Self.prefix) && request.identifier.contains(".snooze.") {
            guard let raw = request.content.userInfo["reminderID"] as? String, let id = UUID(uuidString: raw),
                  let reminder = snapshot.first(where: { $0.id == id }), reminder.status == .active,
                  request.content.userInfo["reminderRevision"] as? Int == reminder.revision,
                  let date = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() else { continue }
            candidates.append((date, request))
        }
        for reminder in snapshot where reminder.status == .active {
            guard (try? ReminderSchedule.validate(reminder)) != nil else { limited.insert("\(reminder.text)：规则无效"); continue }
            if let phase = ReminderSchedule.nativeRepeatPhase(reminder, now: now) {
                let calendar = ReminderSchedule.calendar(for: reminder)
                var components = calendar.dateComponents([.hour, .minute, .second], from: phase.startDate)
                if phase.repeats == .weekly { components.weekday = calendar.component(.weekday, from: phase.startDate) }
                components.timeZone = calendar.timeZone
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                let request = UNNotificationRequest(identifier: "\(Self.prefix)\(reminder.id).r\(reminder.revision).repeat",
                                                     content: content(reminder), trigger: trigger)
                candidates.append((trigger.nextTriggerDate() ?? .distantFuture, request))
            } else {
                let dates = ReminderSchedule.preview(reminder, now: now, limit: Self.notificationBudget + 1)
                if dates.count > Self.notificationBudget { limited.insert(reminder.text) }
                candidates += dates.prefix(Self.notificationBudget).map { ($0, datedRequest(reminder, fire: $0)) }
            }
        }
        candidates.sort { $0.0 < $1.0 }
        if candidates.count > Self.notificationBudget { limited.insert("多个任务的后续提醒") }
        let desired = Array(candidates.prefix(Self.notificationBudget))
        let ids = Set(desired.map { $0.1.identifier })
        let stale = pending.filter { request in
            (request.identifier.hasPrefix(Self.prefix) ||
             (request.identifier.hasPrefix("butler.snooze.") && request.content.categoryIdentifier == NotificationManager.reminderCategory)) &&
                !ids.contains(request.identifier)
        }.map(\.identifier)
        // Cancel obsolete rules before submitting new ones, including all linked snoozes.
        center.removePendingNotificationRequests(withIdentifiers: stale)
        func removeStaleSubmission() -> Bool {
            guard generation != scheduleGeneration || loadFailed else { return false }
            let obsolete = desired.map(\.1).filter { request in
                guard let raw = request.content.userInfo["reminderID"] as? String,
                      let id = UUID(uuidString: raw), let current = reminder(id: id) else { return true }
                return current.status != .active || (request.content.userInfo["reminderRevision"] as? Int) != current.revision
            }.map(\.identifier)
            center.removePendingNotificationRequests(withIdentifiers: obsolete)
            return true
        }
        var failures = false
        for (_, request) in desired {
            // A user may complete/edit while the notification center processes an add.
            if removeStaleSubmission() { return }
            do { try await center.add(request) } catch { failures = true }
            if removeStaleSubmission() { return }
        }
        let accepted = Set(await center.pendingNotificationRequests().map(\.identifier))
        if removeStaleSubmission() { return }
        if desired.contains(where: { date, request in date > .now && !accepted.contains(request.identifier) }) { failures = true }
        let delivered = await center.deliveredNotifications()
        if removeStaleSubmission() { return }
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter {
            guard let raw = $0.request.content.userInfo["reminderID"] as? String,
                  let id = UUID(uuidString: raw), let saved = snapshot.first(where: { $0.id == id }) else { return false }
            return saved.status != .active || ($0.request.content.userInfo["reminderRevision"] as? Int) != saved.revision
        }.map { $0.request.identifier })
        let status = await center.notificationSettings().authorizationStatus
        if removeStaleSubmission() { return }
        var warnings: [String] = []
        if status == .denied { warnings.append("系统通知权限已关闭，到点不会显示通知。") }
        if !limited.isEmpty {
            let coverage = desired.last?.0.formatted(date: .abbreviated, time: .shortened) ?? "稍后"
            warnings.append("当前仅预排最近 \(desired.count) 条（至 \(coverage)）；\(limited.sorted().joined(separator: "、"))尚未全部排入。请在覆盖结束前打开应用补排，未排入的提醒不能保证送达。")
        }
        if failures { warnings.append("部分通知未能加入系统队列，请重新打开应用重试。") }
        scheduleWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
    }
}
