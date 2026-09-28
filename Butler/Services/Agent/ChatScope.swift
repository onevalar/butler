import Foundation

/// A stable conversation owner. Names and navigation paths never identify stored history.
enum ChatScope: Hashable, Codable {
    case general
    case inventory
    case lot(UUID)
    case task(UUID)
    case settings
    case day(String)

    var key: String {
        switch self {
        case .general: "general"
        case .inventory: "inventory"
        case .lot(let id): "lot-" + id.uuidString.lowercased()
        case .task(let id): "task-" + id.uuidString.lowercased()
        case .settings: "settings"
        // Encoding also keeps arbitrary day strings from becoming filesystem paths.
        case .day(let day): "day-" + day.utf8.map { String(format: "%02x", $0) }.joined()
        }
    }

    var title: String {
        switch self {
        case .general: "和管家聊聊"
        case .inventory: "关于家里的东西"
        case .lot: "关于这件物品"
        case .task: "关于这个任务"
        case .settings: "管家与设置"
        case .day(let day): "关于 \(day)"
        }
    }
}

/// Legacy general history keeps its original location; new scopes have independent folders.
struct ChatSessionFiles {
    let scope: ChatScope
    let root: URL

    var directory: URL {
        scope == .general ? root : root.appendingPathComponent("chat-sessions", isDirectory: true)
            .appendingPathComponent(scope.key, isDirectory: true)
    }
    var transcript: URL { directory.appendingPathComponent(scope == .general ? "butler-chat.json" : "chat.json") }
    var summary: URL { directory.appendingPathComponent(scope == .general ? "butler-chat-summary.json" : "summary.json") }
    var draft: URL { directory.appendingPathComponent(scope == .general ? "butler-chat-draft.json" : "draft.json") }
    var photos: URL { directory.appendingPathComponent(scope == .general ? "chat-photos" : "photos", isDirectory: true) }

    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if scope != .general {
            try JSONEncoder().encode(scope).write(to: directory.appendingPathComponent("scope.json"), options: .atomic)
        }
    }

    func saveTurns(_ turns: [ChatTurn]) throws {
        try prepare()
        try JSONEncoder().encode(turns).write(to: transcript, options: .atomic)
    }

    static func savedScopes(in root: URL) -> [ChatScope] {
        let directory = root.appendingPathComponent("chat-sessions", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return [.general] + folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("scope.json")),
                  let scope = try? JSONDecoder().decode(ChatScope.self, from: data),
                  scope != .general, folder.lastPathComponent == scope.key else { return nil }
            return scope
        }
    }
}

struct ChatDraft: Codable, Equatable {
    var text = ""
    var photos: [Data] = []
}
