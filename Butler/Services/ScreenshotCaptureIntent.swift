import AppIntents
import Foundation
import UniformTypeIdentifiers

enum CaptureInputMode: String, AppEnum {
    case typing, voice
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "录入方式"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.typing: "打字", .voice: "语音"]
}

/// System Shortcuts supplies an explicitly captured image. This action never sends a message.
struct ReceiveButlerScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "接收截图并与小当家对话"
    static var description = IntentDescription("把截图加入通用对话草稿，补充要求后再发送。不会自动识别用途或执行任务。")
    static var supportedModes: IntentModes = .foreground
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "截图", supportedContentTypes: [.image]) var screenshot: IntentFile
    @Parameter(title: "录入方式", default: .typing) var mode: CaptureInputMode
    static var parameterSummary: some ParameterSummary { Summary("接收\(\.$screenshot)并以\(\.$mode)对话") }

    @MainActor func perform() async throws -> some IntentResult {
        guard ShortcutNavigation.shared.request == nil else {
            throw ShortcutNavigation.NavigationError("上一条快捷指令尚未打开，请先回到小当家")
        }
        let jpeg = try ShareContentReader.image(screenshot.data)
        try Task.checkCancellation()
        let inbox = try ShareInbox.onDevice()
        let record = try ScreenshotHandoff.save(jpeg, inbox: inbox)
        try ShortcutNavigation.shared.open(.screenshot(record.id, mode))
        return .result()
    }
}

/// Keep a recoverable local original before requesting navigation; draft import records its receipt atomically.
nonisolated enum ScreenshotHandoff {
    static func save(_ jpeg: Data, inbox: ShareInbox) throws -> ShareInbox.Record {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: source) }
        try jpeg.write(to: source, options: .atomic)
        let id = UUID()
        try inbox.begin(id: id)
        do {
            let attachment = try inbox.copyFile(source, name: "截图.jpg", type: UTType.jpeg.identifier, id: id, existing: [])
            try Task.checkCancellation()
            return try inbox.publish(id: id, text: "", attachments: [attachment])
        } catch {
            inbox.cancel(id: id)
            throw error
        }
    }
}
