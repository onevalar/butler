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

    /// Complete, validated read results may outlive the model's final prose.
    /// Publish only after saving, and never attach to whichever turn is newest.
    func saveReadOnlyCollections(for requestID: UUID, displayed: ItemCollection?, edited: ItemCollection?,
                                 history: [ChatTurn]) throws -> [ChatTurn] {
        guard displayed != nil || edited != nil else { return history }
        guard let request = history.firstIndex(where: { $0.id == requestID }),
              history[request].replyState == .answering else { throw CancellationError() }
        var next = history
        if let displayed { next[request].collection = displayed }
        if let edited {
            guard let owner = next.firstIndex(where: { $0.collection?.id == edited.id }) else { throw CancellationError() }
            next[owner].collection = edited
        }
        let keys = [displayed, edited].compactMap { $0 }.flatMap { $0.items.map { ChatScope.lot($0.id).key } }
        let related = Set(next[request].relatedScopeKeys ?? []).union(keys)
        next[request].relatedScopeKeys = related.isEmpty ? nil : related.sorted()
        guard next != history else { return history }
        try saveTurns(next)
        return next
    }

    /// The transcript is the commit point. Until then the entire input remains
    /// recoverable in the draft; a marked draft never authorizes a resend.
    func saveSendingTurn(_ turn: ChatTurn, history: [ChatTurn], draft input: ChatDraft) throws -> ChatTurn {
        try prepare()
        var marked = input
        marked.sendingTurnID = turn.id
        try JSONEncoder().encode(marked).write(to: draft, options: .atomic)
        var saved = turn
        var created: [URL] = []
        do {
            if !input.photos.isEmpty {
                try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
                var names: [String] = []
                for (index, data) in input.photos.enumerated() {
                    let name = "\(turn.id.uuidString)-\(index).jpg"
                    let file = photos.appendingPathComponent(name)
                    // Never replace an existing attachment. These files are not referenced
                    // by history until every write has succeeded.
                    try data.write(to: file, options: .withoutOverwriting)
                    created.append(file)
                    names.append(name)
                }
                saved.photos = names
            }
            try saveTurns(history + [saved])
            return saved
        } catch {
            // Only our completed writes, never a pre-existing attachment.
            for file in created { try? FileManager.default.removeItem(at: file) }
            throw error
        }
    }

    func loadDraft() throws -> ChatDraft {
        var saved = try JSONDecoder().decode(ChatDraft.self, from: Data(contentsOf: draft))
        if let id = saved.sendingTurnID {
            // A corrupt/unreadable transcript is not evidence that a send failed.
            let turns = FileManager.default.fileExists(atPath: transcript.path)
                ? try JSONDecoder().decode([ChatTurn].self, from: Data(contentsOf: transcript)) : []
            if turns.contains(where: { $0.id == id }) {
                return ChatDraft(receivedShareIDs: saved.receivedShareIDs)
            }
            saved.sendingTurnID = nil
        }
        return saved
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
    /// Local recovery marker only; absent in legacy drafts and never synced.
    var sendingTurnID: UUID?
}
