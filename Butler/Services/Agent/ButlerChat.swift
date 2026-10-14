import Foundation
import Observation
import SwiftData
import UIKit
import UserNotifications

struct ChatTurn: Identifiable, Codable, Equatable {
    enum ReplyState: String, Codable { case answering, completed, failed, stopped, interrupted }
    var id = UUID()
    var question: String
    var answer: String = ""
    var failed = false
    /// What was actually written after the owner confirmed, one line per change.
    var receipts: [String] = []
    var date = Date()
    /// File names of photos sent with this question (in the chat-photos folder).
    var photos: [String]?
    /// Explicit object references recorded by tools; absent in legacy history.
    var relatedScopeKeys: [String]?
    var collection: ItemCollection?
    /// Receipt identities, never executable authorizations. Also prevents duplicate recovery text.
    var confirmationIDs: [UUID]?
    /// Device-local associations and evidence; omitted by the chat sync allow-list.
    var confirmationResults: [ConfirmationResult]?
    var confirmationFinished: Bool?
    var replyState: ReplyState?
    /// Incomplete model text retained after a handled stop/error, never fed back
    /// as an answer or exported through the chat sync allow-list.
    var partialReply: String?
    /// Native health results exist only in the visible in-memory turn, never in its serialization.
    var localHealthResults: [String] = []
    var displayReceipts: [String] { receipts + localHealthResults }
    enum CodingKeys: String, CodingKey {
        case id, question, answer, failed, receipts, date, photos, relatedScopeKeys, collection, confirmationIDs
        case confirmationResults, confirmationFinished, replyState, partialReply
    }

    func displayedReply(using progress: ChatReplyProgress) -> String {
        if replyState == .answering, progress.turnID == id { return progress.text }
        return partialReply ?? answer
    }

    var collectionNotice: String {
        switch replyState {
        case .answering: "说明仍在整理，清单可能继续调整；未修改库存。"
        case .failed, .stopped, .interrupted: "本轮回复未完成，已保留查到的清单；未修改库存。"
        default: "只读清单 · 数量和状态以当前记录为准。"
        }
    }

    /// Remove only matching structured messages, never "the first N lines": a
    /// late warning can precede a result, and local health is a separate surface.
    var additionalReceipts: [String] {
        var remaining = receipts
        for result in confirmationResults ?? [] {
            if let index = remaining.firstIndex(of: result.message) { remaining.remove(at: index) }
        }
        return remaining
    }

    /// Update only the identified execution record and explicitly linked requests.
    /// Missing/legacy owners are not replaced with the newest turn.
    static func updateConfirmation(_ id: UUID, results: [ConfirmationResult], in turns: inout [ChatTurn]) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        let additional = turns[index].additionalReceipts
        turns[index].confirmationResults = results
        turns[index].receipts = results.map(\.message) + additional
        let keys = Set(results.flatMap { $0.relatedScopeKeys ?? [] })
        turns[index].relatedScopeKeys = keys.isEmpty ? nil : keys.sorted()
        for result in results {
            guard let owner = result.requestTurnID, let source = turns.firstIndex(where: { $0.id == owner }) else { continue }
            let related = Set(turns[source].relatedScopeKeys ?? []).union(result.relatedScopeKeys ?? [])
            turns[source].relatedScopeKeys = related.isEmpty ? nil : related.sorted()
        }
    }
}

/// Older conversation condensed by the model. `throughTurnID` is the last turn it covers.
struct ConversationSummary: Codable, Equatable {
    var text = ""
    var throughTurnID: UUID?
    var updatedAt: Date?
}

/// The conversation with the butler: cloud model for understanding, phone tools for doing.
@MainActor @Observable
final class ButlerChat {
    let connection: SubscriptionConnection
    let jev: JevClient
    let scope: ChatScope
    /// What was visible when the home input opened. Never replaces the general chat or its draft.
    var homeBrief: BriefConversation?
    private(set) var tools: ButlerTools?
    var turns: [ChatTurn] = []
    var working = false
    var workingStage = ""
    let replyProgress = ChatReplyProgress()
    /// Kept with this cached conversation, never serialized or synchronized.
    var scrollPolicy = ChatScrollPolicy()
    var draft = "" {
        didSet { saveDraft() }
    }
    var error: String?
    /// Photos attached to the next message (JPEG).
    var photos: [Data] = [] { didSet { saveDraft() } }
    /// "关于我和家里": background the owner wants the butler to always know.
    var profile = "" {
        didSet {
            guard !loadingProfile, oldValue != profile else { return }
            defaults.set(profile, forKey: "butlerProfile")
            NotificationCenter.default.post(name: .butlerSettingsChanged, object: nil)
        }
    }

    static let photoPrompt = "帮我看看这些图片。先说明内容；如果我的用途不明确，请问我想做什么，不要直接记录物品或安排任务。"

    var messages: [LocalAgentMessage] = []
    /// Older conversation condensed by the model, so nothing is simply cut off.
    var summary = ConversationSummary()
    var compacting = false
    var historyGeneration = UUID()
    var model: (any LocalAgentModel)?
    var task: Task<Void, Never>?
    @ObservationIgnored var replyStarted: ContinuousClock.Instant?
    let files: ChatSessionFiles?
    let confirmationJournal: ConfirmationJournal?
    var confirmationID: UUID?
    let defaults: UserDefaults
    let container: ModelContainer
    var loadingDraft = false
    var draftRevision = 0
    var loadingProfile = false
    var pendingReadable = true
    var historyReadable = true
    var draftReadable = true
    var canReadHistory: Bool { historyReadable }
    var receivedShareIDs: [UUID] = []
    var photoGeneration = 0
    var transcriptURL: URL? { files?.transcript }
    var summaryURL: URL? { files?.summary }

    var canSend: Bool {
        (connection.isLoggedIn || localDecision != nil || LocalInventoryQuery.isCandidate(draft) || ShownListEdit.isCandidate(draft)) && tools != nil && historyReadable && draftReadable && pendingReadable && !working
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty) && draft.count <= 8000
    }

    init(container: ModelContainer, reminders: ReminderStore? = nil, scope: ChatScope = .general,
         connection: SubscriptionConnection? = nil, jev: JevClient? = nil,
         directory: URL? = BackupService.supportDirectory, defaults: UserDefaults = .standard,
         notes: LocalMemoryStore? = nil) {
        self.container = container
        self.scope = scope
        self.connection = connection ?? SubscriptionConnection()
        self.jev = jev ?? JevClient(defaults: defaults)
        self.defaults = defaults
        files = directory.map { ChatSessionFiles(scope: scope, root: $0) }
        confirmationJournal = directory.map {
            ConfirmationJournal(file: $0.appendingPathComponent("device-operation-history")
                .appendingPathComponent(scope.key.utf8.map { String(format: "%02x", $0) }.joined() + ".json"))
        }
        profile = defaults.string(forKey: "butlerProfile") ?? ""
        do {
            try files?.prepare()
            let memory: LocalMemoryStore
            if let notes { memory = notes }
            else if directory == BackupService.supportDirectory { memory = try LocalMemoryStore.openNotes() }
            else if let directory { memory = try LocalMemoryStore(file: directory.appendingPathComponent("agent-test-memory.json")) }
            else { memory = try LocalMemoryStore.openNotes() }
            tools = ButlerTools(container: container, notes: memory,
                                reminders: reminders ?? .openOnDevice(), jev: self.jev)
            tools?.conversationScope = scope
            tools?.settingsDefaults = defaults
        } catch {
            self.error = "无法读取你的笔记文件。原文件已保留。"
        }
        loadHistory()
        loadPending()
        recoverConfirmations()
        tools?.pendingDidChange = { [weak self] _ in self?.savePending() }
        tools?.onLocalHealthResult = { [weak self] text in
            guard let self, UIApplication.shared.applicationState == .active, let id = confirmationID,
                  let index = turns.firstIndex(where: { $0.id == id }) else { return }
            turns[index].localHealthResults.append(text)
        }
        if let url = summaryURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(ConversationSummary.self, from: data) {
            summary = saved
        }
        tools?.conversation = { [weak self] in self?.archive ?? ConversationArchive(turns: [], recentStart: 0, summaryThrough: nil) }
        tools?.currentContext = { [weak self] in self?.scopeContext ?? "{}" }
        tools?.shownList = { [weak self] in self?.latestCollection }
        loadDraft()
        rebuildContext()
        makeModel()
    }

    nonisolated deinit {}
}

extension LocalAgentMessage {
    static func receipt(summary: String) -> LocalAgentMessage { .note(summary) }
}
