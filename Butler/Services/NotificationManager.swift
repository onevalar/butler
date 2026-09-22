import Foundation
import UserNotifications

/// Local expiry reminders. Rebuilt from the current inventory whenever it changes,
/// so there is no per-item bookkeeping to drift out of sync.
final class NotificationManager {
    static let shared = NotificationManager()
    private init() {}

    private let identifierPrefix = "butler.lot."

    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    func resync(_ lots: [LotFacts], now: Date = Date(), calendar: Calendar = .current) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        )

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "notificationsEnabled") else { return }
        let leadDays = max(defaults.integer(forKey: "expiryWarningDays"), 1)

        for lot in lots {
            guard let date = lot.governingDate,
                  let remindDay = calendar.date(byAdding: .day, value: -(lot.isMedicine ? leadDays + 4 : leadDays), to: date),
                  let fireDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: remindDay),
                  fireDate > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = lot.governingDateKind == .plannedUseBy ? "该吃掉了" : "快到期了"
            let days = LotFacts.days(from: fireDate, to: date, calendar: calendar)
            content.body = "\(lot.name)还有 \(days) 天\(lot.governingDateKind == .plannedUseBy ? "到你定的日子" : "到期")。"
            content.sound = .default
            content.userInfo = ["lotID": lot.id.uuidString]

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
                repeats: false
            )
            try? await center.add(UNNotificationRequest(
                identifier: identifierPrefix + lot.id.uuidString, content: content, trigger: trigger
            ))
        }
    }
}
