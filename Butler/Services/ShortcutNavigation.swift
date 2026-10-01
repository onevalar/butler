import Foundation
import Observation

/// App Intents run in the app target, not a separate extension. The request survives scene setup.
/// This is navigation only: it cannot authorize an inventory or task write.
@MainActor @Observable final class ShortcutNavigation {
    struct Request: Identifiable, Equatable {
        enum Destination: Equatable { case task(UUID), inventory(String), lot(UUID), general }
        let id = UUID()
        let destination: Destination
    }
    static let shared = ShortcutNavigation()
    private(set) var request: Request?

    func open(_ destination: Request.Destination) throws {
        guard request == nil else { throw NavigationError("上一条快捷指令尚未打开，请先回到小当家") }
        if case .inventory(let text) = destination {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 10_000 else {
                throw NavigationError("物品描述须为1–10000字")
            }
        }
        request = Request(destination: destination)
    }

    func consume(_ id: UUID) {
        guard request?.id == id else { return }
        request = nil
    }

    func openWidgetURL(_ url: URL) throws {
        guard let destination = WidgetDestination(url: url) else { return }
        switch destination {
        case .overview: try open(.general)
        case .task(let id): try open(.task(id))
        case .lot(let id): try open(.lot(id))
        }
    }

    struct NavigationError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
