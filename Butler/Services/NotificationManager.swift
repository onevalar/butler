import Foundation
import Observation
import UserNotifications

extension Notification.Name {
    static let butlerNotificationAuthorizationChanged = Notification.Name("butler.notificationAuthorizationChanged")
}

/// Pure reminder policy. The recorded fire date also acts as a durable receipt:
/// an elapsed reminder is never recreated by an inventory resync.
enum LotReminderPolicy {
    /// `leadDays` 0 means on the day itself. `minutes` is the time of day (default 9:00).
    static func fireDate(date: Date, isMedicine: Bool, leadDays: Int, now: Date,
                         calendar: Calendar, recordedFireDate: Date?, minutes: Int = 9 * 60) -> Date? {
        if let recordedFireDate, recordedFireDate <= now { return nil }
        guard let day = calendar.date(byAdding: .day, value: -(max(0, leadDays) + (isMedicine ? 4 : 0)), to: date),
              let scheduled = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) else { return nil }
        // A newly added due-soon/today/overdue lot gets one catch-up, not one per sync.
        if scheduled > now { return scheduled }
        let catchup = now.addingTimeInterval(60)
        return min(recordedFireDate ?? catchup, catchup)
    }

    static func receiptKey(for lot: LotFacts, calendar: Calendar) -> String? {
        guard let date = lot.governingDate, let kind = lot.governingDateKind else { return nil }
        return "\(lot.id.uuidString).\(kind.rawValue).\(date.timeIntervalSince1970)"
    }
}

/// Retained at app launch. Parent observes pendingLotID and clears it after routing.
@MainActor @Observable
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    private(set) var pendingLotID: UUID?
    private var syncTask: Task<Void, Never>?
    private let identifierPrefix = "butler.lot."
    private let receiptsKey = "butler.reminderReceipts.v1"

    private override init() { super.init() }

    func installDelegate() { UNUserNotificationCenter.current().delegate = self }
    func clearPendingRoute() { pendingLotID = nil }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let raw = response.notification.request.content.userInfo["lotID"] as? String,
           let id = UUID(uuidString: raw) {
            Task { @MainActor in self.pendingLotID = id }
        }
        completionHandler()
    }

    /// Asks once, the first time there is something worth reminding about.
    func requestAuthorizationIfUndecided() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if status == .notDetermined { await requestAuthorization() }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        if granted {
            NotificationCenter.default.post(name: .butlerNotificationAuthorizationChanged, object: nil)
        }
        return granted
    }

    func resync(_ lots: [LotFacts], now: Date = Date(), calendar: Calendar = .current) async {
        // Actor isolation alone does not serialize across await points.
        let previous = syncTask
        let task = Task {
            await previous?.value
            await rebuild(lots, now: now, calendar: calendar)
        }
        syncTask = task
        await task.value
    }

    private func rebuild(_ lots: [LotFacts], now: Date, calendar: Calendar) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let defaults = UserDefaults.standard
        let settings = await center.notificationSettings()
        let enabled = defaults.bool(forKey: "notificationsEnabled") &&
            [UNAuthorizationStatus.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
        var receipts = (defaults.dictionary(forKey: receiptsKey) as? [String: Double]) ?? [:]
        var desired = Set<String>()
        if enabled {
            for lot in lots {
                guard let date = lot.governingDate,
                      let key = LotReminderPolicy.receiptKey(for: lot, calendar: calendar),
                      let fire = LotReminderPolicy.fireDate(
                        date: date, isMedicine: lot.isMedicine, leadDays: defaults.integer(forKey: "expiryWarningDays"),
                        now: now, calendar: calendar,
                        recordedFireDate: receipts[key].map { Date(timeIntervalSince1970: $0) },
                        minutes: defaults.integer(forKey: "reminderMinutes")
                      ) else { continue }
                let identifier = identifierPrefix + key
                desired.insert(identifier)
                let content = UNMutableNotificationContent()
                let days = LotFacts.days(from: fire, to: date, calendar: calendar)
                let when = days <= 0 ? "今天" : days == 1 ? "明天" : "还有 \(days) 天"
                content.title = lot.governingDateKind == .plannedUseBy ? "\(lot.name) 该吃掉了" : "\(lot.name) 快到期了"
                content.body = "\(lot.dateKindLabel) \(date.monthDay)，\(when)。家里还有 \(lot.quantity) \(lot.unit)。"
                content.sound = .default
                content.userInfo = ["lotID": lot.id.uuidString]
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire),
                    repeats: false
                )
                do {
                    try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
                    receipts[key] = fire.timeIntervalSince1970
                    defaults.set(receipts, forKey: receiptsKey)
                } catch {
                    // No receipt on failure; a later sync may retry.
                }
            }
        }
        let cancelled = pending.map(\.identifier).filter {
            $0.hasPrefix(identifierPrefix) && !desired.contains($0)
        }
        center.removePendingNotificationRequests(withIdentifiers: cancelled)
        for identifier in cancelled {
            let key = String(identifier.dropFirst(identifierPrefix.count))
            // A pending future reminder removed on close/permission loss was not delivered.
            if let fire = receipts[key], fire > now.timeIntervalSince1970 { receipts.removeValue(forKey: key) }
        }
        defaults.set(receipts, forKey: receiptsKey)
    }
}
