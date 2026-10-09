import BackgroundTasks
import Combine
import EventKit
import Foundation
import SwiftData
import UIKit

/// App-owned, so opening a view is not required to maintain the saved overview.
@MainActor
final class BriefRefreshController {
    static let shared = BriefRefreshController()
    static let taskIdentifier = "com.anvalar.Butler.brief-refresh"
    let service = BriefService()
    private(set) var sessions: ChatSessions?
    private var model: CloudBriefModel?
    private var reminders: ReminderStore?
    private var subscriptions: Set<AnyCancellable> = []
    private var coalescing: Task<Void, Never>?
    private var batchStarted: Date?
    private var settling: Task<Void, Never>?
    private var boundary: Task<Void, Never>?
    private var continuation: UIBackgroundTaskIdentifier = .invalid
    private var continuationWatchdog: Task<Void, Never>?
    private var backgroundRun = false
    private var finishBackground: (() -> Void)?
    private var dirty = true

    private init() {}

    func configure(container: ModelContainer) {
        guard sessions == nil else { return }
        let reminders = ReminderStore.openOnDevice()
        self.reminders = reminders
        let sessions = ChatSessions(container: container, reminders: reminders)
        self.sessions = sessions
        SyncService.shared.attach(sessions)
        model = sessions.makeBriefModel()
        if let model { service.attach(model: model) }
        service.onNeedsUpdate = { [weak self] in self?.requestUpdate() }
        let changes: [Notification.Name] = [.init("butlerBriefSourcesChanged"), .butlerSettingsChanged,
            .EKEventStoreChanged, .NSSystemTimeZoneDidChange, UIApplication.significantTimeChangeNotification]
        for name in changes {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in self?.requestUpdate() }
            }.store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: .init("butlerBriefBatchFinished")).sink { [weak self] _ in
            Task { @MainActor in
                if let self, self.dirty { self.requestUpdate() }
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .butlerBackupRestored).sink { [weak self] _ in
            Task { @MainActor in
                self?.service.cancel()
                self?.sessions?.reloadFromDisk()
                self?.reminders?.reload()
                self?.requestUpdate()
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
            Task { @MainActor in self?.becameActive() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification).sink { [weak self] _ in
            Task { @MainActor in self?.enteredBackground() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification).sink { [weak self] _ in
            Task { @MainActor in
                self?.sessions?.connection.reloadStoredCredentials()
                self?.requestUpdate()
            }
        }.store(in: &subscriptions)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: .main) { task in
            Task { @MainActor in BriefRefreshController.shared.runBackground(task) }
        }
    }

    /// Trailing coalescing with a two-second ceiling; a batch never postpones evaluation indefinitely.
    func requestUpdate() {
        dirty = true
        // The bounded background run owns its sync → check order. Source writes during sync only mark dirty.
        guard !backgroundRun else { return }
        guard UIApplication.shared.applicationState == .active || continuation != .invalid else {
            scheduleBackground()
            return
        }
        if batchStarted == nil { batchStarted = .now }
        let remaining = max(0, 2 - Date.now.timeIntervalSince(batchStarted ?? .now))
        coalescing?.cancel()
        coalescing = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(min(0.4, remaining))) }
            catch { return }
            guard let self else { return }
            coalescing = nil; batchStarted = nil
            checkNow()
        }
    }

    /// Also used immediately before a card action, so a missed notification cannot authorize stale buttons.
    func checkNow(allowGeneration: Bool = true) {
        guard UIApplication.shared.isProtectedDataAvailable, let reminders else { return }
        let waitingForSources = WeatherStore.shared.isRefreshing || sessions?.working == true || SyncService.shared.isSyncingForBrief
        dirty = waitingForSources || !allowGeneration
        let now = Date.now
        do {
            if model == nil, let recovered = sessions?.makeBriefModel() {
                model = recovered
                service.attach(model: recovered)
            }
            guard let model else { throw BriefReadError.incomplete }
            try reminders.refresh(now: now)
            let facts = try model.tools.activeFacts()
            let tasks = try reminders.taskSnapshot()
            // Calendar display access is separate from permission to send events to the model.
            let agenda = HomeAgenda.build(lots: facts, reminders: tasks, events: [], now: now, dayCount: 7,
                                          household: HouseholdStore.shared.names)
            let candidates = BriefCandidates.make(facts: facts, agenda: agenda, now: now,
                snoozed: BriefSnoozes.active(now: now))
            service.update(candidates: candidates, lotCount: facts.count,
                taskCount: tasks.filter { $0.status == .active }.count,
                usesCalendar: model.tools.systemCalendar.conversationAllowed && model.tools.systemCalendar.systemAuthorized,
                now: now, weather: WeatherStore.shared.snapshot, allowGeneration: allowGeneration && !waitingForSources)
        } catch {
            service.sourcesUnavailable(now: now)
        }
        settling?.cancel()
        settling = Task { [weak self] in
            guard let self else { return }
            await service.settle()
            guard !Task.isCancelled else { return }
            armBoundary()
            if !backgroundRun { endContinuation() }
        }
    }

    func foregroundTick() {
        // Cheap recovery for a suspended timer; never rebuild full snapshots every 30 seconds.
        if dirty || service.nextCheckAt.map({ $0 <= Date.now }) == true { requestUpdate() }
        service.updateGreeting(now: .now)
    }

    private func becameActive() {
        finishBackground?()
        endContinuation()
        sessions?.connection.reloadStoredCredentials()
        reminders?.reload()
        Task { await WeatherStore.shared.refresh() }
        requestUpdate()
    }

    private func armBoundary() {
        boundary?.cancel()
        guard let next = service.nextCheckAt else { return }
        scheduleBackground()
        guard UIApplication.shared.applicationState == .active else { return }
        boundary = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.1, next.timeIntervalSinceNow))) }
            catch { return }
            self?.requestUpdate()
        }
    }

    private func enteredBackground() {
        boundary?.cancel()
        scheduleBackground()
        guard continuation == .invalid, dirty || service.isUpdating else { return }
        continuation = UIApplication.shared.beginBackgroundTask(withName: "Finish household brief") { [weak self] in
            Task { @MainActor in self?.expireContinuation() }
        }
        guard continuation != .invalid else { service.cancel(); return }
        continuationWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) }
            catch { return }
            self?.expireContinuation()
        }
        if dirty { requestUpdate() }
    }

    private func expireContinuation() {
        dirty = true
        coalescing?.cancel(); batchStarted = nil
        service.cancel()
        endContinuation()
    }

    private func endContinuation() {
        continuationWatchdog?.cancel(); continuationWatchdog = nil
        if continuation != .invalid {
            UIApplication.shared.endBackgroundTask(continuation)
            continuation = .invalid
        }
    }

    private func scheduleBackground() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        // An earliest date is a hint, not a promise. Dirty changes get the next available opportunity.
        request.earliestBeginDate = dirty ? Date.now.addingTimeInterval(60) : service.nextCheckAt
        do { try BGTaskScheduler.shared.submit(request) }
        catch { ChatDiagnostics.log("brief background scheduling unavailable; foreground validation retained") }
    }

    private func runBackground(_ task: BGTask) {
        guard !backgroundRun, UIApplication.shared.applicationState != .active,
              UIApplication.shared.isProtectedDataAvailable else {
            dirty = true
            scheduleBackground()
            task.setTaskCompleted(success: false)
            return
        }
        coalescing?.cancel(); batchStarted = nil
        backgroundRun = true
        var finished = false
        var work: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        let finish: @MainActor (Bool) -> Void = { [weak self] success in
            guard !finished, let self else { return }
            finished = true
            work?.cancel(); watchdog?.cancel()
            work = nil; watchdog = nil
            task.expirationHandler = nil
            finishBackground = nil
            if !success { dirty = true; service.cancel() }
            backgroundRun = false
            scheduleBackground()
            task.setTaskCompleted(success: success)
        }
        finishBackground = { finish(false) }
        task.expirationHandler = { Task { @MainActor in finish(false) } }
        // Leave room for the system completion callback. Cancellation must never strand it.
        watchdog = Task {
            do { try await Task.sleep(for: .seconds(20)) }
            catch { return }
            finish(false)
        }
        work = Task { [weak self] in
            guard let self else { finish(false); return }
            await SyncService.shared.refreshForBrief()
            guard !Task.isCancelled else { return }
            coalescing?.cancel(); batchStarted = nil
            checkNow()
            await service.settle()
            guard !Task.isCancelled else { return }
            finish(true)
        }
    }
}
