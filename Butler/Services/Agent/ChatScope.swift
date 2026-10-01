import Foundation
import CryptoKit

/// The exact reminder the user opened, not the single object used by its quick-action buttons.
/// Reopening identical content on the same day resumes its history; later reminders cannot
/// silently replace the context of an existing conversation.
struct BriefConversation: Hashable, Codable {
    let day: String
    let text: String
    let actionTarget: BriefTarget?
    let actions: [BriefAction]

    init(brief: ButlerBrief, day: String) {
        self.day = day
        text = brief.text
        actionTarget = brief.target
        actions = brief.actions
    }

    var key: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // All stored fields are plain Codable values. Hashing prevents reminder text from
        // entering a path, and stays stable across launches (unlike Swift's randomized hash).
        let data = try! encoder.encode(self)
        return "brief-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A stable conversation owner. Names and navigation paths never identify stored history.
enum ChatScope: Hashable, Codable {
    case general
    case inventory
    case lot(UUID)
    case task(UUID)
    case settings
    case day(String)
    case brief(BriefConversation)

    var key: String {
        switch self {
        case .general: "general"
        case .inventory: "inventory"
        case .lot(let id): "lot-" + id.uuidString.lowercased()
        case .task(let id): "task-" + id.uuidString.lowercased()
        case .settings: "settings"
        // Encoding also keeps arbitrary day strings from becoming filesystem paths.
        case .day(let day): "day-" + day.utf8.map { String(format: "%02x", $0) }.joined()
        case .brief(let reminder): reminder.key
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
        case .brief: "关于这条管家提醒"
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
    var pending: URL { directory.appendingPathComponent("pending-changes.json") }
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

    /// Sync must not turn an unreadable scope into a remote deletion.
    static func syncScopes(in root: URL) throws -> [ChatScope] {
        let directory = root.appendingPathComponent("chat-sessions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [.general] }
        let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return [.general] + (try folders.map { folder in
            let scope = try JSONDecoder().decode(ChatScope.self, from: Data(contentsOf: folder.appendingPathComponent("scope.json")))
            guard scope != .general, scope.key.utf8.count <= 200, folder.lastPathComponent == scope.key else {
                throw SyncFailure("会话目录与内容不匹配，停止聊天同步。")
            }
            return scope
        })
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
    /// Stored with the draft in one atomic write; survives sending and app relaunch.
    var receivedShareIDs: [UUID]?
}
