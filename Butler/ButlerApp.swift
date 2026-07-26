//
//  ButlerApp.swift
//  Butler
//
//  Created by 安宇佳 on 2026/1/6.
//

import SwiftUI
import SwiftData

@main
struct ButlerApp: App {

    init() {
        // Ensure AppStorage defaults are available from first launch
        UserDefaults.standard.register(defaults: [
            "notificationsEnabled": true,
            "expiryWarningDays": 3
        ])
    }

    /// Shared SwiftData container for the entire app
    var sharedModelContainer: ModelContainer = {
        do {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--m2-input-harness") {
                // The M2 harness must never leave V2 rows invisible in the normal legacy UI.
                return try ButlerStore.makePreviewContainer()
            }
            #endif
            return try ButlerStore.makeContainer()
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--m2-input-harness") {
                M2InputHarnessView(modelContainer: sharedModelContainer)
            } else {
                ContentView()
                    .task { await NotificationManager.shared.requestAuthorization() }
            }
            #else
            ContentView()
                .task {
                    // Request notification permission on first launch
                    await NotificationManager.shared.requestAuthorization()
                }
            #endif
        }
        .modelContainer(sharedModelContainer)
    }
}
