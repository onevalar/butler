#if DEBUG
import Foundation
import Observation
import SwiftData
import UIKit

enum JevEvaluationStop: String, Error { case budget, timeout, cancelled, rounds }

/// Consumed at the transport boundary, so retries count too. No tool may swallow a stop.
@MainActor
final class JevEvaluationBudget {
    static let modelPerCase = 6, jevPerCase = 8, modelTotal = 192, jevTotal = 128
    var model = 0, jev = 0, caseModel = 0, caseJev = 0
    var stop: JevEvaluationStop?
    let deadline: Date
    init(seconds: TimeInterval = 1200) { deadline = .now.addingTimeInterval(seconds) }
    nonisolated deinit {}
    func check() throws {
        try Task.checkCancellation()
        if Date.now >= deadline { stop = .timeout }
        if let stop { throw stop }
    }
    func consume(jev isJev: Bool) throws {
        try check()
        if isJev {
            guard jev < Self.jevTotal, caseJev < Self.jevPerCase else { stop = .budget; throw JevEvaluationStop.budget }
            jev += 1; caseJev += 1
        } else {
            guard model < Self.modelTotal, caseModel < Self.modelPerCase else { stop = .budget; throw JevEvaluationStop.budget }
            model += 1; caseModel += 1
        }
    }
}

struct JevEvaluationResult: Codable, Identifiable {
    struct Tool: Codable { let name: String; let arguments: String; let output: String }
    struct Attempt: Codable { let succeeded: Bool; let seconds: Double }
    let id: Int
    let scenario: JevEvaluationCase
    let expected: String
    let repetition: Int
    let jevEnabled: Bool
    var verdict = "error"
    var error: String?
    var answer = ""
    var tools: [Tool] = []
    var proposals: [String] = []
    var before: [JevEvaluationLot] = []
    var beforeConfirmation: [JevEvaluationLot] = []
    var after: [JevEvaluationLot] = []
    var receipts: [String] = []
    var assertions: [String: Bool] = [:]
    var modelRequests = 0
    var jevRequests = 0
    var jevAttempts: [Attempt] = []
    var seconds = 0.0
}

@MainActor @Observable
final class JevEvaluation {
    struct Entry { let scenario: JevEvaluationCase; let repetition: Int; let enabled: Bool }
    static var plan: [Entry] {
        (1...2).flatMap { repetition in
            JevEvaluationCase.all.enumerated().flatMap { index, scenario in
                ((index + repetition).isMultiple(of: 2) ? [true, false] : [false, true]).map {
                    Entry(scenario: scenario, repetition: repetition, enabled: $0)
                }
            }
        }
    }
    private(set) var results: [JevEvaluationResult] = []
    private(set) var running = false
    private(set) var status = "未开始"
    private(set) var current = ""
    private(set) var startedAt: Date?
    private var task: Task<Void, Never>?
    private let connection: SubscriptionConnection
    private let network: URLSession
    private let jevAccount: String
    private let defaults: UserDefaults
    private let root: URL
    private let caseSeconds: TimeInterval
    private let batchSeconds: TimeInterval
    private var previousIdleTimerDisabled: Bool?

    init(connection: SubscriptionConnection, network: URLSession = .shared,
         jevAccount: String = "api-key", defaults: UserDefaults = .standard,
         root: URL = FileManager.default.temporaryDirectory, caseSeconds: TimeInterval = 90,
         batchSeconds: TimeInterval = 1200) {
        self.connection = connection; self.network = network; self.jevAccount = jevAccount
        self.defaults = defaults; self.root = root; self.caseSeconds = caseSeconds; self.batchSeconds = batchSeconds
    }
    nonisolated deinit {}

    var ready: Bool {
        connection.isLoggedIn && JevClient(defaults: defaults, keychainAccount: jevAccount).isConfigured
    }
    func start() {
        guard !running else { return }
        guard ready else { status = "需要已有的主模型登录和 Jev 密钥，请在上一级设置中检查。"; return }
        results = []; startedAt = .now; running = true; status = "运行中"
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task { await run() }
    }
    func cancel() {
        task?.cancel()
        restoreIdleTimer()
        if running { status = "正在停止…" }
    }
    private func restoreIdleTimer() {
        if let previousIdleTimerDisabled { UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled }
        previousIdleTimerDisabled = nil
    }

    private func run() async {
        defer { restoreIdleTimer(); running = false; task = nil }
        let budget = JevEvaluationBudget(seconds: batchSeconds)
        for entry in Self.plan {
            if Task.isCancelled { status = "已取消，可导出已有结果"; return }
            current = "\(results.count + 1)/32 · \(entry.scenario.title) · Jev \(entry.enabled ? "开" : "关")"
            budget.caseModel = 0; budget.caseJev = 0
            let result = await sample(entry, id: results.count + 1, budget: budget)
            results.append(result)
            if result.error != nil {
                status = result.verdict == "cancelled" ? "已取消，可导出已有结果" : "已停止：\(result.error!)；可导出已有结果"
                return
            }
        }
        status = "已完成 32 个对话"
    }

    /// Owns every temporary resource. Never constructs ButlerChat or opens production stores.
    func sample(_ entry: Entry, id: Int, budget: JevEvaluationBudget) async -> JevEvaluationResult {
        let began = Date.now
        var result = JevEvaluationResult(id: id, scenario: entry.scenario, expected: entry.scenario.expected,
                                         repetition: entry.repetition, jevEnabled: entry.enabled)
        let directory = root.appendingPathComponent("butler-eval-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try budget.check()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let container = try ButlerStore.makePreviewContainer()
            try JevEvaluationCase.seed(container)
            let metrics = EvaluationAttempts()
            let judge = JevClient(network: network, defaults: defaults, keychainAccount: jevAccount,
                enabledOverride: entry.enabled, beforeRequest: { try budget.consume(jev: true) },
                observeAttempt: { metrics.jev.append(.init(succeeded: $0, seconds: $1)) })
            let tools = ButlerTools(container: container,
                notes: try LocalMemoryStore(file: directory.appendingPathComponent("notes.json")),
                reminders: ReminderStore(file: directory.appendingPathComponent("reminders.json"), schedules: false), jev: judge)
            tools.beginTurn(request: entry.scenario.input, previous: nil)
            result.before = try JevEvaluationLot.read(container)
            let model = SubscriptionModel(connection: connection, network: network,
                instructions: { ButlerChat.instructions(jev: entry.enabled) + "\n本次是隔离测试，工具中只有虚构库存，无任何真实用户资料。" },
                tools: { tools.toolJSON }, beforeRequest: { try budget.consume(jev: false) },
                diagnostics: { _ in }, preserveCredentials: true)
            let worker = Task { @MainActor () throws -> String in
                var messages: [LocalAgentMessage] = [.user(entry.scenario.input)]
                guard let answer = try await ToolConversationLoop.run(model: model, messages: &messages,
                    rounds: JevEvaluationBudget.modelPerCase, execute: { call in
                        try budget.check()
                        let output = await tools.execute(call)
                        metrics.tools.append(.init(name: call.name, arguments: call.arguments, output: output))
                        try budget.check()
                        return output
                    }, log: { _ in }) else { throw JevEvaluationStop.rounds }
                try budget.check()
                return answer
            }
            let timeout = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(max(0, min(caseSeconds, budget.deadline.timeIntervalSinceNow))))
                    budget.stop = .timeout
                    worker.cancel()
                } catch { }
            }
            let outcome = await withTaskCancellationHandler(operation: { await worker.result }, onCancel: { worker.cancel() })
            timeout.cancel()
            result.tools = metrics.tools
            result.jevAttempts = metrics.jev
            result.proposals = tools.pending.map { $0.title + ($0.detail.map { " · " + $0 } ?? "") }
            result.beforeConfirmation = try JevEvaluationLot.read(container)
            result.after = result.beforeConfirmation
            do {
                result.answer = try outcome.get()
                try budget.check()
                result.assertions["no_write_before_confirmation"] = result.before == result.beforeConfirmation
                result.assertions["proposal_matches_fixed_expectation"] = entry.scenario.proposalMatches(tools.pending)
                result.receipts = tools.confirmAll() // This container and all stores are disposable.
                result.after = try JevEvaluationLot.read(container)
                result.assertions["stored_state_matches_fixed_expectation"] = entry.scenario.stateMatches(before: result.before, after: result.after)
                result.assertions["no_unrequested_notes_or_reminders"] = tools.notes.records.isEmpty && tools.reminders.reminders.isEmpty
                result.assertions["confirmation_succeeded"] = !result.receipts.isEmpty && result.receipts.allSatisfy { $0.hasPrefix("✓") }
                if entry.enabled && metrics.jev.contains(where: { !$0.succeeded }) { result.verdict = "jev_fallback" }
                else if entry.enabled && metrics.jev.isEmpty { result.verdict = "jev_not_exercised" }
                else { result.verdict = result.assertions.values.allSatisfy { $0 } ? "pass" : "fail" }
            } catch {
                result.error = Self.safeError(budget.stop ?? error)
                result.verdict = Task.isCancelled ? "cancelled" : "error"
            }
            tools.clearPending()
        } catch {
            result.error = Self.safeError(error)
            result.verdict = Task.isCancelled ? "cancelled" : "error"
        }
        result.modelRequests = budget.caseModel
        result.jevRequests = budget.caseJev
        result.seconds = Date.now.timeIntervalSince(began)
        return result
    }

    /// Export only explicit fictional inputs/results and aggregate attempts, never messages' wireOutput,
    /// auth headers, service error bodies, account IDs, or production diagnostics.
    func export() throws -> Data {
        struct Report: Encodable {
            let schema = 1
            let mainModel = "gpt-6-sol"
            let jevModel = JevClient.model
            let plannedConversations = 32
            let requestLimits = ["model_per_case": 6, "jev_per_case": 8, "model_total": 192, "jev_total": 128]
            let accounting = "请求数含重试；不含连通性 HEAD 和授权刷新；非费用账单。Jev 回退/未使用样本不算有效开启样本。"
            let status: String
            let startedAt: Date?
            let results: [JevEvaluationResult]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Report(status: status, startedAt: startedAt, results: results))
    }

    private static func safeError(_ error: Error) -> String {
        if error is CancellationError { return "已取消" }
        if let stop = error as? JevEvaluationStop { return "\(stop.rawValue)：达到测试保护限制或已取消" }
        if let url = error as? URLError { return "网络错误 \(url.code.rawValue)" }
        if case SubscriptionError.signInRequired = error { return "订阅登录不可用（未删除登录记录）" }
        if case SubscriptionError.rejected(let code, _) = error { return "模型请求被拒绝 HTTP \(code)" }
        return "测试无法继续：\(String(describing: type(of: error)))"
    }
}

@MainActor private final class EvaluationAttempts {
    var jev: [JevEvaluationResult.Attempt] = []
    var tools: [JevEvaluationResult.Tool] = []
    nonisolated deinit {}
}
#endif
