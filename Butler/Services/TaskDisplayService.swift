import ActivityKit
import Foundation
import UIKit

@MainActor final class TaskActivityDevice: TaskDisplayDevice {
    var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    func read() -> [SystemTaskDisplay] {
        Activity<TaskDisplayAttributes>.activities.map {
            .init(id: $0.id, sessionID: $0.attributes.sessionID, taskID: $0.attributes.taskID,
                  active: $0.activityState == .active || $0.activityState == .stale)
        }
    }
    func start(_ record: TaskDisplayRecord) throws -> String {
        guard UIApplication.shared.applicationState == .active else {
            throw TaskDisplayStore.Failure("请保持小当家在前台，再重新确认开启展示。")
        }
        return try Activity.request(attributes: TaskDisplayAttributes(sessionID: record.id, taskID: record.taskID),
            content: ActivityContent(state: .init(deadline: record.deadline, ended: false), staleDate: record.deadline),
            pushType: nil).id
    }
    func end(_ id: String) async {
        guard let activity = Activity<TaskDisplayAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.end(ActivityContent(state: .init(deadline: activity.content.state.deadline, ended: true), staleDate: nil),
                           dismissalPolicy: .immediate)
    }
}

@MainActor enum TaskDisplayService {
    static let store = TaskDisplayStore(file: URL.applicationSupportDirectory.appendingPathComponent("task-display-journal.json"),
                                       device: TaskActivityDevice())
    private static var worker: Task<Void, Never>?
    private static var requested = false

    static func tasks(_ reminders: ReminderStore) throws -> [TaskDisplayTask] {
        try reminders.taskSnapshot().map {
            .init(id: $0.id, revision: $0.revision, active: $0.status == .active, automaticEnd: $0.autoCompleteAt)
        }
    }

    /// Coalesces lifecycle changes. A revision change ends the old session even after rapid reopen.
    static func reconcile() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] == nil, environment["XCTestBundlePath"] == nil else { return }
        requested = true
        guard worker == nil else { return }
        worker = Task { @MainActor in
            defer { worker = nil }
            while requested {
                requested = false
                do { try await store.reconcile(tasks: tasks(ReminderStore.openOnDevice())) }
                catch { /* Queries expose journal/device failures; don't overwrite unreadable task data. */ }
            }
        }
    }
}
