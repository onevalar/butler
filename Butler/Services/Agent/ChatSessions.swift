import Foundation
import Observation
import SwiftData

struct RelatedChatTurn: Identifiable {
    let scope: ChatScope
    let turn: ChatTurn
    var id: String { scope.key + "/" + turn.id.uuidString }
}

/// Keeps independent conversations alive while sharing account, preferences and phone data.
@MainActor @Observable
final class ChatSessions {
    let connection: SubscriptionConnection
    let jev: JevClient
    private let container: ModelContainer
    private let reminders: ReminderStore
    private let directory: URL?
    private let defaults: UserDefaults
    private let notes: LocalMemoryStore?
    private var cache: [ChatScope: ButlerChat] = [:]

    init(container: ModelContainer, reminders: ReminderStore? = nil,
         connection: SubscriptionConnection? = nil, jev: JevClient? = nil,
         directory: URL? = BackupService.supportDirectory, defaults: UserDefaults = .standard) {
        self.container = container
        self.reminders = reminders ?? .openOnDevice()
        self.connection = connection ?? SubscriptionConnection()
        self.jev = jev ?? JevClient(defaults: defaults)
        self.directory = directory
        self.defaults = defaults
        self.notes = directory.flatMap { try? LocalMemoryStore(file: $0.appendingPathComponent("agent-test-memory.json")) }
    }

    nonisolated deinit {}

    func chat(for scope: ChatScope) -> ButlerChat {
        if let existing = cache[scope] { return existing }
        let chat = ButlerChat(container: container, reminders: reminders, scope: scope,
                              connection: connection, jev: jev, directory: directory, defaults: defaults, notes: notes)
        cache[scope] = chat
        if case .lot = scope { connectObjectHistory(chat) }
        if case .task = scope { connectObjectHistory(chat) }
        return chat
    }

    var allChats: [ButlerChat] { Array(cache.values) }
    var working: Bool { cache.values.contains(where: \.working) }

    func reloadFromDisk() {
        cache.values.forEach { $0.reloadFromDisk() }
        reloadSettings()
    }

    /// Keeps cached settings screens and shared judgment preferences in sync after tools or restore.
    func reloadSettings() {
        cache.values.forEach { $0.reloadProfile() }
        jev.isEnabled = defaults.object(forKey: "jevEnabled") as? Bool ?? true
        jev.prefetchEnabled = defaults.object(forKey: "jevPrefetchEnabled") as? Bool ?? true
    }

    var allTurns: [ChatTurn] {
        knownScopes.flatMap { storedTurns(for: $0) }.sorted { $0.date < $1.date }
    }

    /// Cross-scope references preserve the original turn instead of copying conversations.
    /// Only explicit scope ownership and tool-recorded references are indexed; old text is never guessed.
    func relatedTurns(for scope: ChatScope) -> [RelatedChatTurn] {
        return knownScopes.flatMap { source -> [RelatedChatTurn] in
            return storedTurns(for: source).filter { source == scope || $0.relatedScopeKeys?.contains(scope.key) == true }
                .map { RelatedChatTurn(scope: source, turn: $0) }
        }.sorted { $0.turn.date < $1.turn.date }
    }

    private var knownScopes: Set<ChatScope> {
        Set(directory.map(ChatSessionFiles.savedScopes(in:)) ?? [.general]).union(cache.keys)
    }

    private func connectObjectHistory(_ chat: ButlerChat) {
        let scope = chat.scope
        chat.tools?.conversation = { [weak self, weak chat] in
            guard let self else { return chat?.archive ?? ConversationArchive(turns: [], recentStart: nil, summaryThrough: nil) }
            let inProgress = Set(self.cache.values.filter(\.working).compactMap { $0.turns.last?.id })
            var seen = Set<UUID>()
            let references = self.relatedTurns(for: scope).filter {
                !inProgress.contains($0.turn.id) && seen.insert($0.turn.id).inserted
            }
            return ConversationArchive(turns: references.map(\.turn), recentStart: nil, summaryThrough: nil,
                scopeDescription: "当前对象 \(scope.key) 的会话，以及其他会话中明确关联此对象的原文；不包含无关会话。source_scope 标识原始来源。",
                sources: Dictionary(uniqueKeysWithValues: references.map { ($0.turn.id, $0.scope) }))
        }
    }

    private func storedTurns(for scope: ChatScope) -> [ChatTurn] {
        if let loaded = cache[scope] { return loaded.turns }
        guard let directory,
              let data = try? Data(contentsOf: ChatSessionFiles(scope: scope, root: directory).transcript),
              let decoded = try? JSONDecoder().decode([ChatTurn].self, from: data) else { return [] }
        return decoded
    }
}
