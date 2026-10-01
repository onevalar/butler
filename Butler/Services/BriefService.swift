import Foundation
import Observation
import SwiftData

/// Where the brief's sentence and buttons come from when a model is available.
@MainActor
protocol BriefModel {
    var isAvailable: Bool { get }
    /// The model's raw reply to a request built by `BriefModelReply.request`.
    func answer(_ request: String) async throws -> String
}

/// The signed-in cloud model.
@MainActor
struct CloudBriefModel: BriefModel {
    let connection: SubscriptionConnection
    var isAvailable: Bool { connection.isLoggedIn }

    func answer(_ request: String) async throws -> String {
        let model = SubscriptionModel(connection: connection, instructions: { BriefModelReply.instructions() }, tools: { "[]" })
        return try await model.reply(to: [.user(request)]).text
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
    @ObservationIgnored private var candidateSignature = ""
    @ObservationIgnored private var interactionStarted = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var failedAt: [String: Date] = [:]
    /// The last situation seen, so a model that connects later (at launch, or after signing in) is still asked.
    @ObservationIgnored private var lastUpdate: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar: Calendar

    private static let cacheKey = "briefCache"
    private static let cacheLife: TimeInterval = 8 * 3600
    private static let retryAfter: TimeInterval = 10 * 60
    @ObservationIgnored private let timeout: Double

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current, timeout: Double = 15) {
        self.defaults = defaults
        self.calendar = calendar
        self.timeout = timeout
        brief = ButlerBrief(greeting: "", text: "", basis: "", target: nil, actions: [], source: .local)
    }

    nonisolated deinit {}

    func beginInteraction() { interactionStarted = true }

    func attach(_ connection: SubscriptionConnection) { attach(model: CloudBriefModel(connection: connection)) }
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
        let sig = "overview-v4|" + base + "|" + (weather?.briefSignature(at: now) ?? "")
        if sig == signature {
            if brief.basis != basis { brief.basis = basis }
            return
        }
        signature = sig
        if candidateSignature != base { interactionStarted = false }
        candidateSignature = base
        task?.cancel()
        isThinking = false
        let local = BriefLocal.compose(candidates: candidates, lotCount: lotCount, basis: basis, now: now, calendar: calendar)
        guard !candidates.isEmpty else { brief = local; return }
        if var cached = cachedBrief(for: sig, now: now) {
            cached.basis = basis
            if !interactionStarted { brief = cached }
            return
        }
        if !interactionStarted { brief = local }
        guard let model, model.isAvailable else {
            ChatDiagnostics.log("brief local only: \(self.model == nil ? "model not attached yet" : "not signed in")")
            return
        }
        if let failed = failedAt[sig], now.timeIntervalSince(failed) < Self.retryAfter { return }
        isThinking = true
        task = Task { [weak self] in
            await self?.ask(model, candidates: candidates, local: local, signature: sig, now: now, weather: weather)
        }
    }

    /// Resolves when the current question has been answered, refused or given up on (for tests and previews).
    func settle() async { await task?.value }

    private func ask(_ model: BriefModel, candidates: [BriefCandidate], local: ButlerBrief,
                     signature sig: String, now: Date, weather: WeatherSnapshot?) async {
        let request = BriefModelReply.request(candidates: candidates, greeting: local.greeting, now: now, calendar: calendar, weather: weather)
        let started = Date.now
        do {
            let reply = try await Self.withTimeout(seconds: timeout) { try await model.answer(request) }
            guard !Task.isCancelled, signature == sig else { return }
            if let parsed = BriefModelReply.parse(reply, candidates: candidates) {
                var actions = parsed.actions
                if actions.isEmpty, let target = parsed.target, let mine = candidates.first(where: { $0.target == target }) {
                    // A sentence without usable buttons still gets sensible ones.
                    actions = BriefLocal.compose(candidates: [mine], lotCount: 1, basis: local.basis, now: now, calendar: calendar).actions
                }
                let result = ButlerBrief(greeting: local.greeting, text: parsed.text, basis: local.basis,
                                         target: parsed.target, actions: actions, source: .model, hasSubject: true)
                if !interactionStarted { brief = result }
                store(result, signature: sig, now: now)
                ChatDiagnostics.log("brief model ok \(String(format: "%.1f", Date.now.timeIntervalSince(started)))s chars=\(parsed.text.count) actions=\(actions.count)")
            } else {
                failedAt[sig] = now
                ChatDiagnostics.log("brief model reply unusable chars=\(reply.count)")
            }
        } catch {
            guard signature == sig else { return }
            failedAt[sig] = now
            ChatDiagnostics.log("brief model failed \(ChatDiagnostics.describe(error))")
        }
        if signature == sig { isThinking = false }
    }

    /// Gives up after `seconds` so the buttons never wait on a slow network.
    private static func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let job = Task { @MainActor in try await work() }
        let watchdog = Task { try await Task.sleep(for: .seconds(seconds)); job.cancel() }
        defer { watchdog.cancel() }
        return try await job.value
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
