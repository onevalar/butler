import Foundation
import Observation
import SwiftData

/// Where the brief's sentence and buttons come from when a model is available.
@MainActor
protocol BriefModel {
    var isAvailable: Bool { get }
    var cacheIdentity: String { get }
    func snapshot(now: Date) -> BriefContext
    /// The model's raw reply to a request built by `BriefModelReply.request`.
    func answer(_ request: String, context: BriefContext) async throws -> String
    func generate(_ request: String, context: BriefContext) async throws -> BriefAnswer
    func validate(_ dependencies: [BriefReadDependency]) async throws -> Bool
}

extension BriefModel {
    var cacheIdentity: String { "local" }
    func snapshot(now: Date) -> BriefContext { BriefContext() }
    func generate(_ request: String, context: BriefContext) async throws -> BriefAnswer {
        BriefAnswer(text: try await answer(request, context: context))
    }
    func validate(_ dependencies: [BriefReadDependency]) async throws -> Bool { dependencies.isEmpty }
}

/// The same model and read APIs as chat, with a separate, strictly read-only session.
@MainActor
struct CloudBriefModel: BriefModel {
    let connection: SubscriptionConnection
    let tools: ButlerTools
    var isAvailable: Bool { connection.isLoggedIn }
    var cacheIdentity: String { connection.accountIdentifier ?? "signed-out" }

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
        try await generate(request, context: context).text
    }

    func validate(_ dependencies: [BriefReadDependency]) async throws -> Bool {
        for dependency in dependencies {
            try Task.checkCancellation()
            guard BriefReadSession.allowed.contains(dependency.name) else { return false }
            if dependency.name.hasPrefix("get_calendar") || dependency.name == "get_system_calendars" {
                guard tools.systemCalendar.conversationAllowed, tools.systemCalendar.systemAuthorized else { return false }
            }
            let output = await tools.execute(LocalToolCall(id: UUID().uuidString, name: dependency.name, arguments: dependency.arguments))
            if let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any], json["error"] != nil {
                throw BriefReadError.sourceUnavailable
            }
            guard BriefReadDependency.fingerprint(output) == dependency.fingerprint else { return false }
        }
        return true
    }

    func generate(_ request: String, context: BriefContext) async throws -> BriefAnswer {
        let reads = BriefReadSession(context: context)
        let definitions = try BriefReadSession.toolJSON(from: tools.toolJSON)
        let identity = cacheIdentity
        let checkSources = {
            guard cacheIdentity == identity, isAvailable else { throw BriefReadError.permissionChanged }
            try validateSources(for: context)
        }
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
        return BriefAnswer(text: result, dependencies: reads.dependencies)
    }
}

/// Keeps the butler's sentence on home current. A local sentence is ready at once; when the cloud model is
/// available it is asked, once per situation, to pick what to raise and which buttons fit, and its answer
/// (checked against the closed set of effects) replaces the local one.
@MainActor @Observable
final class BriefService {
    private(set) var brief: ButlerBrief
    /// A model request, not a local cache check.
    private(set) var isThinking = false
    private(set) var nextCheckAt: Date?

    @ObservationIgnored private var model: BriefModel?
    @ObservationIgnored private var signature = ""
    @ObservationIgnored private var displayedSignature = ""
    @ObservationIgnored private var interactionStarted = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var checking = false
    /// The owner rebuilds current inputs, rather than replaying launch-time candidates and time.
    @ObservationIgnored var onNeedsUpdate: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar: Calendar

    private static let cacheKey = "briefCache"
    private static let failureKey = "briefFailure"
    private static let retryAfter: TimeInterval = 10 * 60
    @ObservationIgnored private let timeout: Double

    init(defaults: UserDefaults = .standard, calendar: Calendar = .autoupdatingCurrent, timeout: Double = 90) {
        self.defaults = defaults
        self.calendar = calendar
        self.timeout = timeout
        brief = ButlerBrief(greeting: "", text: "", basis: "", target: nil, actions: [], source: .local)
    }

    nonisolated deinit {}

    func beginInteraction() { interactionStarted = true }
    func endInteraction() {
        interactionStarted = false
        // Ask the owner to validate again before publishing a result held during interaction.
        onNeedsUpdate?()
    }

    var actionsAreCurrent: Bool { displayedSignature == signature && !displayedSignature.isEmpty }
    var isUpdating: Bool { checking || isThinking }

    func updateGreeting(now: Date) {
        brief.greeting = DailyBrief.greeting(hour: calendar.component(.hour, from: now))
    }

    func sourcesUnavailable(now: Date) {
        cancel()
        signature = "unavailable"
        displayedSignature = ""
        nextCheckAt = now.addingTimeInterval(60)
        guard !interactionStarted else { return }
        brief = ButlerBrief(greeting: DailyBrief.greeting(hour: calendar.component(.hour, from: now)),
            text: "部分资料暂时无法读取，请稍后再看。", basis: "资料尚未核实", target: nil, actions: [], source: .local)
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isThinking = false
        checking = false
    }

    func attach(model: BriefModel) {
        cancel()
        self.model = model
        onNeedsUpdate?()
    }

    func update(candidates: [BriefCandidate], lotCount: Int, taskCount: Int, usesCalendar: Bool, now: Date,
                weather: WeatherSnapshot? = nil, allowGeneration: Bool = true) {
        let basis = BriefLocal.basis(lotCount: lotCount, taskCount: taskCount, usesCalendar: usesCalendar)
        let base = BriefCandidates.signature(candidates, now: now, calendar: calendar)
        let context = model?.snapshot(now: now) ?? BriefContext()
        let unavailable = context.metadata["unavailable"] as? [String: String] ?? [:]
        guard !unavailable.keys.contains(where: { $0 != "calendar" || context.metadata["calendar_allowed"] as? Bool == true }) else {
            sourcesUnavailable(now: now)
            return
        }
        let identity = model?.cacheIdentity ?? "local"
        let scope = BriefContext.fingerprint(["account": identity, "calendar_allowed": context.metadata["calendar_allowed"] as? Bool ?? false])
        let sig = "overview-v6|" + base + "|" + context.signature + "|" + BriefModelReply.weatherSignature(weather, now: now)
            + "|" + BriefContext.fingerprint(["account": identity])
        let local = BriefLocal.compose(candidates: candidates, lotCount: lotCount, basis: basis, now: now, calendar: calendar)
        let stored = loadCache()
        let previous = stored?.scope == scope ? stored?.brief.text : nil
        let cached = cachedBrief(for: sig, now: now)
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86400)
        nextCheckAt = (context.boundaries + (cached?.dependencies.flatMap(\.boundaries) ?? []) + [midnight] + [cached?.reviewAfter, weather?.fetchedAt.addingTimeInterval(1800),
            weather?.observedAt.addingTimeInterval(7200)].compactMap { $0 })
            .filter { $0 > now }.min()
        brief.greeting = local.greeting
        brief.basis = basis
        if sig == signature, checking || isThinking { return }
        cancel()
        signature = sig
        if let cached, cached.dependencies.isEmpty {
            publish(cached.brief, signature: sig, local: local)
            ChatDiagnostics.log("brief reuse: unchanged")
            return
        }
        if cached == nil {
            displayedSignature = ""
            publish(local, signature: sig, local: local)
        }
        guard let model, model.isAvailable else {
            if cached != nil { publish(local, signature: sig, local: local) }
            return
        }
        guard allowGeneration || cached != nil else { return }
        if let failure = failure(), failure.signature == sig, now < failure.at.addingTimeInterval(Self.retryAfter) {
            nextCheckAt = min(nextCheckAt ?? midnight, failure.at.addingTimeInterval(Self.retryAfter))
            return
        }
        let requestGeneration = generation
        checking = true
        isThinking = cached == nil
        task = Task { [weak self] in
            guard let self else { return }
            await self.ask(model, cached: cached, candidates: candidates, local: local, signature: sig,
                           generation: requestGeneration, context: context, now: now, weather: weather, midnight: midnight,
                           identity: identity, scope: scope, previous: previous, allowGeneration: allowGeneration)
        }
    }

    private func publish(_ value: ButlerBrief, signature: String, local: ButlerBrief) {
        var value = value
        value.greeting = local.greeting
        value.basis = local.basis
        if interactionStarted { return }
        brief = value
        displayedSignature = signature
    }

    /// Resolves when the current question has been answered, refused or given up on (for tests and previews).
    func settle() async { await task?.value }

    private func ask(_ model: BriefModel, cached: Cached?, candidates: [BriefCandidate], local: ButlerBrief,
                     signature sig: String, generation requestGeneration: UUID, context: BriefContext,
                     now: Date, weather: WeatherSnapshot?, midnight: Date, identity: String, scope: String,
                     previous: String?, allowGeneration: Bool) async {
        let started = Date.now
        let deadline = started.addingTimeInterval(timeout)
        var validatingCache = cached != nil
        defer {
            if generation == requestGeneration { isThinking = false; checking = false }
        }
        do {
            if let cached {
                let valid = try await Self.withTimeout(seconds: max(0, deadline.timeIntervalSinceNow)) { try await model.validate(cached.dependencies) }
                validatingCache = false
                guard generation == requestGeneration, !Task.isCancelled else { return }
                let checkedAt = now.addingTimeInterval(Date.now.timeIntervalSince(started))
                guard model.snapshot(now: checkedAt).signature == context.signature,
                      model.cacheIdentity == identity, cached.reviewAfter > checkedAt,
                      (nextCheckAt ?? midnight) > checkedAt else {
                    displayedSignature = ""
                    onNeedsUpdate?()
                    return
                }
                if valid {
                    publish(cached.brief, signature: sig, local: local)
                    return
                }
                defaults.removeObject(forKey: Self.cacheKey)
                displayedSignature = ""
                publish(local, signature: sig, local: local)
            }
            guard allowGeneration else { return }
            isThinking = true
            let request = BriefModelReply.request(candidates: candidates, greeting: local.greeting, now: now,
                                                  calendar: calendar, weather: weather, previous: previous)
            let answer = try await Self.withTimeout(seconds: max(0, deadline.timeIntervalSinceNow)) { try await model.generate(request, context: context) }
            guard !Task.isCancelled, generation == requestGeneration else { return }
            let dependenciesValid = try await Self.withTimeout(seconds: max(0, deadline.timeIntervalSinceNow)) { try await model.validate(answer.dependencies) }
            guard !Task.isCancelled, generation == requestGeneration else { return }
            let completedAt = now.addingTimeInterval(Date.now.timeIntervalSince(started))
            // A source event may not have reached the view yet. Validate before both display and cache writes.
            guard dependenciesValid, model.cacheIdentity == identity, model.snapshot(now: completedAt).signature == context.signature,
                  (nextCheckAt ?? midnight) > completedAt else {
                displayedSignature = ""
                ChatDiagnostics.log("brief discard: sources or time changed during request")
                onNeedsUpdate?()
                return
            }
            if let parsed = BriefModelReply.parse(answer.text, candidates: candidates) {
                var actions = parsed.actions
                if actions.isEmpty, let target = parsed.target, let mine = candidates.first(where: { $0.target == target }) {
                    // A sentence without usable buttons still gets sensible ones.
                    actions = BriefLocal.compose(candidates: [mine], lotCount: 1, basis: local.basis, now: now, calendar: calendar).actions
                }
                let result = ButlerBrief(greeting: local.greeting, text: parsed.text, basis: local.basis,
                                         target: parsed.target, actions: actions, source: .model, hasSubject: true,
                                         rationale: parsed.rationale)
                if let review = parsed.reviewAfter, review <= completedAt { throw BriefReadError.incomplete }
                let deadline = min(parsed.reviewAfter ?? midnight, midnight)
                publish(result, signature: sig, local: local)
                defaults.removeObject(forKey: Self.failureKey)
                store(Cached(signature: sig, scope: scope, brief: result, at: completedAt, reviewAfter: deadline, dependencies: answer.dependencies))
                nextCheckAt = (answer.dependencies.flatMap(\.boundaries) + [nextCheckAt ?? midnight, deadline])
                    .filter { $0 > completedAt }.min()
                ChatDiagnostics.log("brief model ok \(String(format: "%.1f", Date.now.timeIntervalSince(started)))s chars=\(parsed.text.count) actions=\(actions.count)")
            } else {
                throw BriefReadError.incomplete
            }
        } catch {
            guard generation == requestGeneration, !Task.isCancelled else { return }
            if validatingCache {
                sourcesUnavailable(now: now)
                return
            }
            if case BriefReadError.sourceUnavailable = error {
                sourcesUnavailable(now: now)
                return
            }
            if let data = try? JSONEncoder().encode(Failure(signature: sig, at: now)) { defaults.set(data, forKey: Self.failureKey) }
            nextCheckAt = min(nextCheckAt ?? midnight, now.addingTimeInterval(Self.retryAfter))
            ChatDiagnostics.log("brief failed: deferred retry")
        }
    }

    /// The deadline releases the waiter even if the transport ignores cooperative cancellation.
    private final class Deadline<T: Sendable> {
        var continuation: CheckedContinuation<T, Error>?
        var job: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        func finish(_ result: Result<T, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            job?.cancel(); watchdog?.cancel()
            self.job = nil; self.watchdog = nil
            continuation.resume(with: result)
        }
    }

    private static func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let deadline = Deadline<T>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                deadline.continuation = continuation
                deadline.job = Task {
                    do { deadline.finish(.success(try await work())) }
                    catch { deadline.finish(.failure(error)) }
                }
                deadline.watchdog = Task {
                    do { try await Task.sleep(for: .seconds(seconds)) }
                    catch { return }
                    deadline.finish(.failure(URLError(.timedOut)))
                }
            }
        } onCancel: { Task { @MainActor in deadline.finish(.failure(CancellationError())) } }
    }

    // MARK: Cache

    private struct Cached: Codable {
        var signature: String
        var scope: String
        var brief: ButlerBrief
        var at: Date
        var reviewAfter: Date
        var dependencies: [BriefReadDependency]
    }
    private struct Failure: Codable { var signature: String; var at: Date }
    private func failure() -> Failure? {
        defaults.data(forKey: Self.failureKey).flatMap { try? JSONDecoder().decode(Failure.self, from: $0) }
    }

    private func loadCache() -> Cached? {
        defaults.data(forKey: Self.cacheKey).flatMap { try? JSONDecoder().decode(Cached.self, from: $0) }
    }

    private func cachedBrief(for sig: String, now: Date) -> Cached? {
        guard let cached = loadCache(),
              cached.signature == sig, now >= cached.at.addingTimeInterval(-1), now < cached.reviewAfter else { return nil }
        return cached
    }

    private func store(_ cached: Cached) {
        guard let data = try? JSONEncoder().encode(cached) else { return }
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
