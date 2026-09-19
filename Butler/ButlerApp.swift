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

    /// Lazily initialized so the debug UI prototype never opens the production store.
    private static let productionModelContainer: ModelContainer = {
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

    private var sharedModelContainer: ModelContainer { Self.productionModelContainer }

    private static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil
    }

    var body: some Scene {
        if Self.isRunningTests {
            // Hosted tests use their own temporary containers and must never open user data.
            WindowGroup { EmptyView() }
        } else {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--v2-ui-prototype") {
                WindowGroup {
                    V2UIPrototypeView()
                }
            } else {
                productionScene
            }
        #else
            productionScene
        #endif
        }
    }

    private var productionScene: some Scene {
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
