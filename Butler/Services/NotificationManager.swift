//
//  NotificationManager.swift
//  Butler
//
//  Created by 安宇佳 on 2026/1/6.
//

import Foundation
import UserNotifications

/// Schedules and cancels local expiry notifications for inventory items
final class NotificationManager {

    static let shared = NotificationManager()
    private init() {}

    // MARK: - Authorization

    /// Request notification permission from the user
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            print("Notification authorization error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Scheduling

    /// Schedule (or reschedule) an expiry warning notification for an item.
    /// Automatically cancels any existing notification for the same item first.
    /// Does nothing if notifications are disabled, item has no expiry, or item is archived.
    func scheduleExpiryNotification(for item: Item) {
        let notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
        guard notificationsEnabled, let expiryDate = item.expiryDate, !item.isArchived else {
            cancelNotification(for: item)
            return
        }

        let warningDays = UserDefaults.standard.integer(forKey: "expiryWarningDays")
        guard let notificationDate = Calendar.current.date(
            byAdding: .day,
            value: -warningDays,
            to: expiryDate
        ), notificationDate > Date() else {
            cancelNotification(for: item)
            return
        }

        // Cancel existing before rescheduling
        cancelNotification(for: item)

        let content = UNMutableNotificationContent()
        content.title = "物品即将过期"
        content.body = "\(item.name) 将在 \(warningDays) 天后过期，请尽快处理。"
        content.sound = .default
        content.userInfo = ["itemID": item.id.uuidString]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour],
            from: notificationDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: item.id.uuidString,
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("Notification scheduling error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Cancellation

    /// Cancel any pending notification for a specific item
    func cancelNotification(for item: Item) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [item.id.uuidString])
    }

    /// Cancel all pending Butler notifications
    func cancelAllNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
