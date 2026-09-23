import SwiftUI
import SwiftData

@main
struct ButlerApp: App {
    private let modelContainer: ModelContainer

    init() {
        UserDefaults.standard.register(defaults: [
            "notificationsEnabled": true,
            "expiryWarningDays": 2,
        ])
        FontRegistry.registerBundledFonts()

        do {
            modelContainer = Self.isRunningTests
                ? try ButlerStore.makePreviewContainer()
                : try ButlerStore.makeContainer()
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--seed-sample-inventory") {
            SampleInventory.seed(into: modelContainer)
        }
        #endif
    }

    /// Hosted unit tests use their own temporary stores and must never open user data.
    private static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}
