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
        let schema = Schema([
            Item.self,
        ])
        
        let modelConfiguration: ModelConfiguration
        if let sharedURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.butler") {
            let databaseURL = sharedURL.appendingPathComponent("Butler.sqlite")
            modelConfiguration = ModelConfiguration(schema: schema, url: databaseURL)
        } else {
            modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, allowsSave: true)
        }

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    // Request notification permission on first launch
                    await NotificationManager.shared.requestAuthorization()
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
