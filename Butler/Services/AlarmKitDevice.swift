import AlarmKit
import ActivityKit
import Foundation
import SwiftUI

@MainActor final class AlarmKitDevice: AlarmDevice {
    private var manager: AlarmManager { .shared }

    var authorization: String {
        switch manager.authorizationState {
        case .authorized: "authorized"
        case .denied: "denied"
        case .notDetermined: "not_determined"
        @unknown default: "unknown"
        }
    }

    func authorize() async throws -> Bool {
        if manager.authorizationState == .notDetermined { return try await manager.requestAuthorization() == .authorized }
        return manager.authorizationState == .authorized
    }

    func read() throws -> [SystemAlarm] {
        let activities = Activity<AlarmAttributes<ButlerAlarmMetadata>>.activities
        return try manager.alarms.map { alarm in
            let state: SystemAlarm.State
            switch alarm.state {
            case .scheduled: state = .scheduled
            case .countdown: state = .countdown
            case .paused: state = .paused
            case .alerting: state = .alerting
            @unknown default: state = .unknown
            }
            var value = SystemAlarm(id: alarm.id, state: state)
            if let activity = activities.first(where: { $0.content.state.alarmID == alarm.id }),
               activity.activityState == .active,
               activity.content.staleDate.map({ $0 > .now }) ?? true {
                switch activity.content.state.mode {
                case .countdown(let countdown) where state == .countdown:
                    value.remainingSeconds = max(0, countdown.fireDate.timeIntervalSinceNow)
                case .paused(let paused) where state == .paused:
                    value.remainingSeconds = max(0, paused.totalCountdownDuration - paused.previouslyElapsedDuration)
                default: break
                }
            }
            return value
        }
    }

    func schedule(id: UUID, title: String, rule: ButlerAlarm.Rule) async throws {
        try rule.validate(now: .now)
        // iOS 26.1+ supplies the stop control; our deployment target is iOS 26.2.
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title))
        var presentation = AlarmPresentation(alert: alert)
        let schedule: Alarm.Schedule?
        let duration: Alarm.CountdownDuration?
        switch rule {
        case .once(let date): schedule = .fixed(date); duration = nil
        case .weekly(let hour, let minute, let days):
            let weekdays: [Locale.Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
            schedule = .relative(.init(time: .init(hour: hour, minute: minute),
                                       repeats: .weekly(days.sorted().map { weekdays[$0 - 1] })))
            duration = nil
        case .timer(let seconds):
            schedule = nil
            duration = .init(preAlert: TimeInterval(seconds), postAlert: nil)
            presentation = AlarmPresentation(alert: alert,
                countdown: .init(title: LocalizedStringResource(stringLiteral: title)),
                paused: .init(title: "倒计时已暂停",
                              resumeButton: AlarmButton(text: "继续", textColor: .white, systemImageName: "play.circle")))
        }
        let attributes = AlarmAttributes(presentation: presentation,
            metadata: ButlerAlarmMetadata(title: title), tintColor: Color.accentColor)
        let configuration = AlarmManager.AlarmConfiguration(countdownDuration: duration, schedule: schedule, attributes: attributes)
        _ = try await manager.schedule(id: id, configuration: configuration)
    }

    func cancel(id: UUID) throws { try manager.cancel(id: id) }
    func stop(id: UUID) throws { try manager.stop(id: id) }
    func pause(id: UUID) throws { try manager.pause(id: id) }
    func resume(id: UUID) throws { try manager.resume(id: id) }
}

extension AlarmStore {
    static let shared: AlarmStore = {
        // Keep the journal out of cloud/portable backup paths: AlarmKit IDs belong to this device.
        let directory = URL.applicationSupportDirectory.appendingPathComponent("DeviceAlarms", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
        } catch {
            return AlarmStore(file: directory.appendingPathComponent("alarms.json"), device: AlarmKitDevice(),
                              preparationError: "无法建立仅限本设备的闹钟记录，没有设置响铃：\(error.localizedDescription)")
        }
        return AlarmStore(file: directory.appendingPathComponent("alarms.json"), device: AlarmKitDevice())
    }()
}
