import SwiftUI
import SwiftData

/// Opens the store once at launch. A store that cannot be opened (damaged file, failed migration,
/// full disk) leaves every file in place and shows a retry page instead of crashing on each launch.
@MainActor @Observable
final class AppLaunch {
    private(set) var container: ModelContainer?
    private(set) var failure: String?
    private let makeContainer: () throws -> ModelContainer
    private let configuresServices: Bool

    init(makeContainer: @escaping () throws -> ModelContainer, configuresServices: Bool) {
        self.makeContainer = makeContainer
        self.configuresServices = configuresServices
        open()
    }

    func open() {
        guard container == nil else { return }
        let container: ModelContainer
        do {
            container = try makeContainer()
        } catch {
            failure = String(describing: error)
            ChatDiagnostics.log("store open failed: \(error)")
            return
        }
        failure = nil
        self.container = container
        guard configuresServices else { return }
        NotificationManager.shared.container = container
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--seed-sample-inventory") {
            SampleInventory.seed(into: container)
        }
        #endif
        WidgetSnapshotPublisher.shared.configure(container: container)
        TaskDisplayService.reconcile()
        SyncService.shared.configure(container: container)
        BriefRefreshController.shared.configure(container: container)
    }
}

@main
struct ButlerApp: App {
    @State private var launch: AppLaunch

    init() {
        UserDefaults.standard.register(defaults: [
            "notificationsEnabled": true,
            "expiryWarningDays": 2,
            "reminderMinutes": 9 * 60,
        ])
        AppTheme.migrateLegacyGlow()
        FontRegistry.registerBundledFonts()
        if !Self.isRunningTests { NotificationManager.shared.installDelegate() }
        let testing = Self.isRunningTests
        _launch = State(initialValue: AppLaunch(
            makeContainer: testing ? ButlerStore.makePreviewContainer : ButlerStore.makeContainer,
            configuresServices: !testing))
    }

    /// Hosted unit tests use their own temporary stores and must never open user data.
    private static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }

    var body: some Scene {
        WindowGroup {
            if let container = launch.container {
                app.modelContainer(container)
            } else {
                StoreUnavailableView(detail: launch.failure ?? "", onRetry: launch.open)
            }
        }
    }

    private var app: some View {
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
}
