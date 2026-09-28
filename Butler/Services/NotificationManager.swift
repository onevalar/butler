import Foundation
import Observation
import SwiftData
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
    private(set) var pendingReminderID: UUID?
    private(set) var reminderActionError: String?
    weak var reminderStore: ReminderStore?
    private var syncTask: Task<Void, Never>?
    private let identifierPrefix = "butler.lot."
    private let receiptsKey = "butler.reminderReceipts.v1"

    private override init() { super.init() }

    /// Where "用完了" on a notification writes to. Set at launch.
    var container: ModelContainer?

    static let lotCategory = "butler.lot"
    static let reminderCategory = "butler.reminder"
    static let usedUpAction = "butler.lot.usedUp"
    static let snoozeLotAction = "butler.lot.tomorrow"
    static let snoozeReminderAction = "butler.reminder.later"
    static let doneReminderAction = "butler.reminder.done"
    private let snoozePrefix = "butler.snooze."

    func installDelegate() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Buttons shown when the owner long-presses or pulls down a notification.
        let lot = UNNotificationCategory(identifier: Self.lotCategory, actions: [
            UNNotificationAction(identifier: Self.usedUpAction, title: "用完了", options: [.authenticationRequired],
                                 icon: UNNotificationActionIcon(systemImageName: "checkmark.circle")),
            UNNotificationAction(identifier: Self.snoozeLotAction, title: "明天再提醒", options: [],
                                 icon: UNNotificationActionIcon(systemImageName: "clock.arrow.circlepath")),
        ], intentIdentifiers: [])
        let reminder = UNNotificationCategory(identifier: Self.reminderCategory, actions: [
            UNNotificationAction(identifier: Self.doneReminderAction, title: "完成", options: [],
                                 icon: UNNotificationActionIcon(systemImageName: "checkmark")),
            UNNotificationAction(identifier: Self.snoozeReminderAction, title: "10 分钟后再提醒", options: [],
                                 icon: UNNotificationActionIcon(systemImageName: "clock")),
        ], intentIdentifiers: [])
        center.setNotificationCategories([lot, reminder])
    }

    func clearPendingRoute() { pendingLotID = nil; pendingReminderID = nil }

    /// Show reminders even while the app is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let content = response.notification.request.content
        let lotID = (content.userInfo["lotID"] as? String).flatMap(UUID.init)
        let reminderID = (content.userInfo["reminderID"] as? String).flatMap(UUID.init)
            ?? Self.legacyReminderID(response.notification.request.identifier)
        let reminderRevision = content.userInfo["reminderRevision"] as? Int ?? 1
        nonisolated(unsafe) let copy = content.mutableCopy() as? UNMutableNotificationContent
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor in
            // A notification action can arrive before the first view has bound its store.
            let tasks = reminderID == nil ? nil : (self.reminderStore ?? ReminderStore.openOnDevice())
            if let tasks { self.reminderStore = tasks }
            switch action {
            case UNNotificationDefaultActionIdentifier:
                if let lotID { self.pendingLotID = lotID }
                if let reminderID { self.pendingReminderID = reminderID }
            case Self.usedUpAction:
                if let lotID { self.markUsedUp(lotID) }
            case Self.snoozeLotAction:
                if let lotID, let copy { await self.snooze(copy, id: self.snoozePrefix + lotID.uuidString, after: .tomorrow) }
            case Self.snoozeReminderAction:
                if let reminderID {
                    do { try await self.reminderStore?.snooze(id: reminderID, revision: reminderRevision) }
                    catch { self.reminderActionError = error.localizedDescription }
                }
            case Self.doneReminderAction:
                if let reminderID { self.completeReminder(reminderID, revision: reminderRevision) }
            default:
                break
            }
            await tasks?.waitForScheduling()
            done()
        }
    }

    /// Old installations used the task UUID directly in the request identifier.
    nonisolated static func legacyReminderID(_ identifier: String) -> UUID? {
        let prefix = "butler.reminder."
        guard identifier.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(prefix.count).prefix(36)))
    }

    func completeReminder(_ id: UUID, revision: Int) {
        do { try reminderStore?.completeFromNotification(id: id, revision: revision) }
        catch { reminderActionError = error.localizedDescription }
    }

    /// The owner confirmed on the notification itself (after unlocking): the whole lot is used up.
    func markUsedUp(_ lotID: UUID) {
        guard let container else { return }
        let context = ModelContext(container)
        guard let lot = try? context.fetch(FetchDescriptor<InventoryLot>(predicate: #Predicate { $0.id == lotID })).first,
              lot.state == .active else { return }
        let productID = lot.productID
        let product = try? context.fetch(FetchDescriptor<CatalogProduct>(predicate: #Predicate { $0.id == productID })).first
        try? InventoryActions(modelContainer: container).close(LotFacts(lot: lot, product: product), as: .depleted)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [snoozePrefix + lotID.uuidString])
    }

    enum SnoozeDelay { case tomorrow, minutes(Int) }

    private func snooze(_ content: UNMutableNotificationContent, id: String, after delay: SnoozeDelay) async {
        let calendar = Calendar.current
        let fire: Date
        switch delay {
        case .minutes(let minutes):
            fire = Date().addingTimeInterval(Double(minutes) * 60)
        case .tomorrow:
            let minutes = UserDefaults.standard.integer(forKey: "reminderMinutes")
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
            fire = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: tomorrow) ?? tomorrow
        }
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire), repeats: false)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
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
                content.categoryIdentifier = Self.lotCategory
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
        // A "明天再提醒" for something that has since been used up or thrown away is dropped.
        let activeSnoozes = Set(lots.map { snoozePrefix + $0.id.uuidString })
        let staleSnoozes = pending
            .filter { $0.content.categoryIdentifier == Self.lotCategory && $0.identifier.hasPrefix(snoozePrefix) }
            .map(\.identifier)
            .filter { !activeSnoozes.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: staleSnoozes)
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
