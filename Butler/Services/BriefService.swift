import Foundation
import Observation
import SwiftData

/// Where the brief's sentence and buttons come from when a model is available.
@MainActor
protocol BriefModel {
    var isAvailable: Bool { get }
    func snapshot(now: Date) -> BriefContext
    /// The model's raw reply to a request built by `BriefModelReply.request`.
    func answer(_ request: String, context: BriefContext) async throws -> String
}

extension BriefModel {
    func snapshot(now: Date) -> BriefContext { BriefContext() }
}

/// The same model and read APIs as chat, with a separate, strictly read-only session.
@MainActor
struct CloudBriefModel: BriefModel {
    let connection: SubscriptionConnection
    let tools: ButlerTools
    var isAvailable: Bool { connection.isLoggedIn }

    func snapshot(now: Date) -> BriefContext { BriefSources.snapshot(tools: tools, now: now) }

    func validateSources(for context: BriefContext) throws {
        let allowed = tools.systemCalendar.conversationAllowed && tools.systemCalendar.systemAuthorized
        guard allowed == (context.metadata["calendar_allowed"] as? Bool ?? false) else {
            throw BriefReadError.permissionChanged
        }
        // Conversation tools use numbered turns. A sync/import can insert older turns between
        // requests; stop rather than resolve the old numbers against a different archive.
        let revision = tools.conversation.map { BriefSources.historyRevision($0()) }
        guard revision == context.metadata["history_revision"] as? String else {
            throw BriefReadError.incomplete
        }
    }

    func answer(_ request: String, context: BriefContext) async throws -> String {
        let reads = BriefReadSession(context: context)
        let definitions = try BriefReadSession.toolJSON(from: tools.toolJSON)
        let checkSources = { try validateSources(for: context) }
        let model = SubscriptionModel(connection: connection, instructions: { BriefModelReply.instructions() },
            tools: { definitions }, beforeRequest: checkSources)
        let data = try JSONSerialization.data(withJSONObject: reads.overview(), options: [.sortedKeys])
        let call = LocalToolCall(id: "home-overview", name: "get_brief_overview", arguments: "{}")
        var messages: [LocalAgentMessage] = [.user(request)]
        let result = try await ToolConversationLoop.run(model: model, messages: &messages,
            prefetched: [PrefetchedToolResult(call: call, output: String(decoding: data, as: UTF8.self))],
            execute: { call in
                try checkSources()
                return await reads.execute(call, readTool: tools.execute)
            }, completionFeedback: reads.completionFeedback)
        try checkSources()
        guard let result, reads.missingPages.isEmpty else { throw BriefReadError.incomplete }
        return result
    }
}

/// Keeps the butler's sentence on home current. A local sentence is ready at once; when the cloud model is
/// available it is asked, once per situation, to pick what to raise and which buttons fit, and its answer
/// (checked against the closed set of effects) replaces the local one.
@MainActor @Observable
final class BriefService {
    private(set) var brief: ButlerBrief
    /// Background update; the visible card remains usable.
    private(set) var isThinking = false

    @ObservationIgnored private var model: BriefModel?
    @ObservationIgnored private var signature = ""
    @ObservationIgnored private var interactionStarted = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var failedAt: [String: Date] = [:]
    /// The last situation seen, so a model that connects later (at launch, or after signing in) is still asked.
    @ObservationIgnored private var lastUpdate: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar: Calendar

    private static let cacheKey = "briefCache"
    private static let cacheLife: TimeInterval = 30 * 60
    private static let retryAfter: TimeInterval = 10 * 60
    @ObservationIgnored private let timeout: Double

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current, timeout: Double = 90) {
        self.defaults = defaults
        self.calendar = calendar
        self.timeout = timeout
        brief = ButlerBrief(greeting: "", text: "", basis: "", target: nil, actions: [], source: .local)
    }

    nonisolated deinit {}

    func beginInteraction() { interactionStarted = true }
    func endInteraction() { interactionStarted = false }

    func attach(model: BriefModel) {
        self.model = model
        // Home computes the card before the conversation services exist; ask again now that the model is here.
        if brief.source == .local, let lastUpdate {
            signature = ""
            lastUpdate()
        }
    }

    func update(candidates: [BriefCandidate], lotCount: Int, taskCount: Int, usesCalendar: Bool, now: Date, weather: WeatherSnapshot? = nil) {
        lastUpdate = { [weak self] in
            self?.update(candidates: candidates, lotCount: lotCount, taskCount: taskCount, usesCalendar: usesCalendar, now: now, weather: weather)
        }
        let basis = BriefLocal.basis(lotCount: lotCount, taskCount: taskCount, usesCalendar: usesCalendar)
        let base = BriefCandidates.signature(candidates, now: now, calendar: calendar)
        let context = model?.snapshot(now: now) ?? BriefContext()
        let weatherSignature = BriefContext.fingerprint(BriefModelReply.weatherContext(weather, now: now) ?? [:])
        let sig = "overview-v5|" + base + "|" + context.signature + "|" + weatherSignature
        if sig == signature {
            if brief.basis != basis { brief.basis = basis }
            if isThinking { return }
            // A failed request must reach the retry gate; elapsed time alone does not change the signature.
        } else {
            generation = UUID()
            task?.cancel()
        }
        signature = sig
        isThinking = false
        let local = BriefLocal.compose(candidates: candidates, lotCount: lotCount, basis: basis, now: now, calendar: calendar)
        if var cached = cachedBrief(for: sig, now: now) {
            cached.basis = basis
            cached.greeting = local.greeting
            if !interactionStarted { brief = cached }
            return
        }
        if !interactionStarted { brief = local }
        guard let model, model.isAvailable else {
            ChatDiagnostics.log("brief local only: \(self.model == nil ? "model not attached yet" : "not signed in")")
            return
        }
        if let failed = failedAt[sig], now.timeIntervalSince(failed) < Self.retryAfter { return }
        generation = UUID()
        let requestGeneration = generation
        isThinking = true
        task = Task { [weak self] in
            await self?.ask(model, candidates: candidates, local: local, signature: sig, generation: requestGeneration,
                            context: context, now: now, weather: weather)
        }
    }

    /// Resolves when the current question has been answered, refused or given up on (for tests and previews).
    func settle() async { await task?.value }

    private func ask(_ model: BriefModel, candidates: [BriefCandidate], local: ButlerBrief,
                     signature sig: String, generation requestGeneration: UUID, context: BriefContext,
                     now: Date, weather: WeatherSnapshot?) async {
        let request = BriefModelReply.request(candidates: candidates, greeting: local.greeting, now: now, calendar: calendar, weather: weather)
        let started = Date.now
        do {
            let reply = try await Self.withTimeout(seconds: timeout) { try await model.answer(request, context: context) }
            guard !Task.isCancelled, generation == requestGeneration else { return }
            if let parsed = BriefModelReply.parse(reply, candidates: candidates) {
                var actions = parsed.actions
                if actions.isEmpty, let target = parsed.target, let mine = candidates.first(where: { $0.target == target }) {
                    // A sentence without usable buttons still gets sensible ones.
                    actions = BriefLocal.compose(candidates: [mine], lotCount: 1, basis: local.basis, now: now, calendar: calendar).actions
                }
                let result = ButlerBrief(greeting: local.greeting, text: parsed.text, basis: local.basis,
                                         target: parsed.target, actions: actions, source: .model, hasSubject: true,
                                         rationale: parsed.rationale)
                if !interactionStarted { brief = result }
                failedAt.removeValue(forKey: sig)
                store(result, signature: sig, now: now)
                ChatDiagnostics.log("brief model ok \(String(format: "%.1f", Date.now.timeIntervalSince(started)))s chars=\(parsed.text.count) actions=\(actions.count)")
            } else {
                failedAt[sig] = now
                ChatDiagnostics.log("brief model reply unusable chars=\(reply.count)")
            }
        } catch {
            guard generation == requestGeneration else { return }
            failedAt[sig] = now
            ChatDiagnostics.log("brief model failed \(ChatDiagnostics.describe(error))")
        }
        if generation == requestGeneration { isThinking = false }
    }

    /// Gives up after `seconds` so the buttons never wait on a slow network.
    private static func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let job = Task { @MainActor in try await work() }
        let watchdog = Task { try await Task.sleep(for: .seconds(seconds)); job.cancel() }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await job.value
        } onCancel: { job.cancel() }
    }

    // MARK: Cache

    private struct Cached: Codable { var signature: String; var brief: ButlerBrief; var at: Date }

    private func cachedBrief(for sig: String, now: Date) -> ButlerBrief? {
        guard let data = defaults.data(forKey: Self.cacheKey), let cached = try? JSONDecoder().decode(Cached.self, from: data),
              cached.signature == sig, now.timeIntervalSince(cached.at) < Self.cacheLife else { return nil }
        return cached.brief
    }

    private func store(_ brief: ButlerBrief, signature: String, now: Date) {
        guard let data = try? JSONEncoder().encode(Cached(signature: signature, brief: brief, at: now)) else { return }
        defaults.set(data, forKey: Self.cacheKey)
    }
}

/// Carries out what a brief button says. Runs only from a tap, the same trust as pressing the button on the item's own page.
@MainActor
struct BriefActionRunner {
    enum Outcome: Equatable {
        case done
        /// Open the item's or task's detail page.
        case open
        case failed(String)
    }

    let container: ModelContainer
    let reminders: ReminderStore
    var defaults: UserDefaults = .standard

    func run(_ action: BriefAction, target: BriefTarget, facts: [LotFacts], now: Date = .now) async -> Outcome {
        switch (action.effect, target) {
        case (.openDetail, _):
            return .open
        case (.closeLot(let state), .lot(let id)):
            guard let lot = facts.first(where: { $0.id == id }) else { return .failed("这件东西已经不在家里了。") }
            return attempt { try InventoryActions(modelContainer: container).close(lot, as: state) }
        case (.usedSome(let count), .lot(let id)):
            guard let lot = facts.first(where: { $0.id == id }) else { return .failed("这件东西已经不在家里了。") }
            let left = lot.quantity - count
            guard left >= 1 else { return .failed("用掉的数量比现有的多，请到详情里改。") }
            return attempt { try InventoryActions(modelContainer: container).adjustQuantity(lot, to: left) }
        case (.snooze(let days), _):
            BriefSnoozes.snooze(target, days: days, now: now, defaults: defaults)
            return .done
        case (.completeTask, .task(let id)):
            return attempt { try reminders.complete(id) }
        case (.remindLater(let minutes), .task(let id)):
            guard let task = reminders.reminder(id: id) else { return .failed("这个任务已经不在了。") }
            do {
                try await reminders.snooze(id: id, revision: task.revision, minutes: minutes)
                BriefSnoozes.snooze(target, until: now.addingTimeInterval(Double(minutes) * 60), defaults: defaults)
                return .done
            } catch { return .failed(error.localizedDescription) }
        default:
            return .failed("这个按钮现在做不了。")
        }
    }

    private func attempt(_ work: () throws -> Void) -> Outcome {
        do { try work(); return .done } catch { return .failed(error.localizedDescription) }
    }
}
