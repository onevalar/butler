import SwiftUI
import SwiftData

@main
struct ButlerApp: App {
    private let modelContainer: ModelContainer

    init() {
        UserDefaults.standard.register(defaults: [
            "notificationsEnabled": true,
            "expiryWarningDays": 2,
            "reminderMinutes": 9 * 60,
        ])
        AppTheme.migrateLegacyGlow()
        FontRegistry.registerBundledFonts()
        if !Self.isRunningTests { NotificationManager.shared.installDelegate() }

        do {
            modelContainer = Self.isRunningTests
                ? try ButlerStore.makePreviewContainer()
                : try ButlerStore.makeContainer()
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
        if !Self.isRunningTests { NotificationManager.shared.container = modelContainer }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--seed-sample-inventory") {
            SampleInventory.seed(into: modelContainer)
        }
        #endif
        if !Self.isRunningTests { WidgetSnapshotPublisher.shared.configure(container: modelContainer) }
        if !Self.isRunningTests { TaskDisplayService.reconcile() }
        if !Self.isRunningTests { SyncService.shared.configure(container: modelContainer) }
        if !Self.isRunningTests { BriefRefreshController.shared.configure(container: modelContainer) }
    }

    /// Hosted unit tests use their own temporary stores and must never open user data.
    private static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                #if DEBUG
                .task {
                    guard ProcessInfo.processInfo.arguments.contains("--check-speech-service") else { return }
                    do {
                        let config = try SpeechRecognitionSettings().customConfiguration()
                        guard config.usesRealtime else { return }
                        try await RealtimeSpeechClient(configuration: config).checkConnection(model: config.model)
                        ChatDiagnostics.log("speech probe: authenticated and session configuration accepted; no audio sent")
                        // Opt-in developer fixture, never the microphone or user recordings.
                        if ProcessInfo.processInfo.arguments.contains("--check-speech-sample") {
                            let file = FileManager.default.temporaryDirectory.appendingPathComponent("butler-speech-test.pcm")
                            let bytes = try Data(contentsOf: file)
                            guard bytes.count <= 480_000 else { return }
                            defer { try? FileManager.default.removeItem(at: file) }
                            let client = RealtimeSpeechClient(configuration: config)
                            defer { client.cancel() }
                            let (stream, input) = AsyncStream<Data>.makeStream()
                            var updates = 0
                            client.start(model: config.model, audio: stream, onText: { _ in updates += 1 }, onFailure: { _ in })
                            for offset in stride(from: 0, to: bytes.count, by: 4800) {
                                input.yield(bytes.subdata(in: offset..<min(offset + 4800, bytes.count)))
                                try await Task.sleep(for: .milliseconds(100))
                            }
                            input.finish()
                            let result = try await client.finish()
                            ChatDiagnostics.log("speech probe: synthetic audio completed, updates=\(updates), expectedPhrase=\(result.contains("语音识别测试"))")
                        }
                    } catch {
                        let message = (error as? SpeechServiceError)?.localizedDescription ?? "connection failed"
                        ChatDiagnostics.log("speech probe: \(message)")
                    }
                }
                #endif
        }
        .modelContainer(modelContainer)
    }
}
