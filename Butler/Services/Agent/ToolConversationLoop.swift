import Foundation

/// The shared conversation loop. Storage, confirmation and summarization belong to its caller.
@MainActor
enum ToolConversationLoop {
    static func run(model: any LocalAgentModel, messages: inout [LocalAgentMessage],
                    prefetched: [PrefetchedToolResult] = [],
                    rounds: Int = 30, readPolicy: ToolReadExecutionPolicy? = nil,
                    execute: @escaping @MainActor (LocalToolCall) async throws -> String,
                    completionFeedback: (String) -> String? = { _ in nil },
                    progress: @escaping (String) -> Void = { _ in },
                    log: @escaping (String) -> Void = ChatDiagnostics.log,
                    onMetrics: (ToolLoopMetrics) -> Void = { _ in }) async throws -> String? {
        let execution = ToolLoopExecution(policy: readPolicy ?? .serial, execute: execute, progress: progress, log: log)
        defer {
            let value = execution.metrics
            log("loop model_rounds=\(value.modelRounds) executed_tools=\(value.executedTools) cache_hits=\(value.cacheHits) prefetched_hits=\(value.prefetchedHits) parallel_groups=\(value.parallelGroups) max_parallel=\(value.maximumParallel)")
            onMetrics(value)
        }
        try Task.checkCancellation()
        // These reads were executed by the phone, before the first model request. Keep their
        // contents at tool-data priority, never splice a user's note into developer instructions.
        if !prefetched.isEmpty {
            messages.append(.assistant(LocalModelReply(text: "", calls: prefetched.map(\.call))))
            for item in prefetched { messages.append(.tool(id: item.call.id, result: item.output)) }
        }
        execution.seed(prefetched)
        for round in 0..<rounds {
            try Task.checkCancellation()
            let asked = Date.now
            progress(round == 0 ? "正在理解你的安排…" : "正在整理结果…")
            execution.metrics.modelRounds += 1
            let reply = try await model.reply(to: messages)
            log("round \(round) \(String(format: "%.1f", Date.now.timeIntervalSince(asked)))s calls=\(reply.calls.map(\.name).joined(separator: ","))")
            try Task.checkCancellation()
            messages.append(.assistant(reply))
            if reply.calls.isEmpty {
                if let feedback = completionFeedback(reply.text) {
                    messages.append(.context(feedback))
                    continue
                }
                return reply.text.isEmpty ? "好的。" : reply.text
            }
            let results = try await execution.batch(Array(reply.calls.prefix(12)))
            for (index, call) in reply.calls.enumerated() {
                // Every advertised call needs a response, even when a batched request
                // exceeds the execution budget. Never leave unmatched calls in history.
                guard index < 12 else {
                    messages.append(.tool(id: call.id, result: #"{"error":"本轮工具数量超过12项，此项未执行；请拆分到下一轮。"}"#))
                    continue
                }
                messages.append(.tool(id: call.id, result: results[index]))
            }
        }
        return nil
    }

    fileprivate static func status(for name: String) -> String {
        switch name {
        case "get_tasks", "list_reminders": "正在查看任务和提醒…"
        case "search_inventory", "get_item_profile", "get_inventory_history": "正在查找家里的物品…"
        case "get_weather", "get_destination_weather": "正在查询天气…"
        case "get_settings": "正在查看设置…"
        case "judge_with_jev": "正在核对匹配结果…"
        case let value where value.hasPrefix("propose_"): "正在准备修改，请稍后确认…"
        default: "正在读取相关资料…"
        }
    }
}

/// One instance belongs to one run/user turn. Never retain it on the chat or model adapter.
@MainActor
private final class ToolLoopExecution {
    private struct CachedRead {
        let output: String
        let expires: Date
        let prefetched: Bool
    }
    private struct ReadResult: Sendable { let index: Int; let output: String }

    let policy: ToolReadExecutionPolicy
    let execute: @MainActor (LocalToolCall) async throws -> String
    let progress: (String) -> Void
    let log: (String) -> Void
    var metrics = ToolLoopMetrics()
    private var active = 0
    private var completed: [String: String] = [:]
    private var cache: [String: CachedRead] = [:]
    private var version: ToolReadCacheEpoch.Version?

    init(policy: ToolReadExecutionPolicy, execute: @escaping @MainActor (LocalToolCall) async throws -> String,
         progress: @escaping (String) -> Void, log: @escaping (String) -> Void) {
        self.policy = policy; self.execute = execute; self.progress = progress; self.log = log
        version = policy.epoch?.version
    }

    nonisolated deinit {}

    func seed(_ items: [PrefetchedToolResult]) {
        guard policy.enabled, policy.preparedVersion == policy.epoch?.version else { return }
        for item in items { remember(item.output, call: item.call, at: policy.preparedAt, prefetched: true) }
    }

    private func synchronize() {
        let current = policy.epoch?.version
        if current != version { cache.removeAll(); version = current }
    }

    private func cached(_ call: LocalToolCall) -> String? {
        synchronize()
        guard let key = policy.key(call), let entry = cache[key] else { return nil }
        guard entry.expires > policy.now() else { cache[key] = nil; return nil }
        metrics.cacheHits += 1
        if entry.prefetched { metrics.prefetchedHits += 1 }
        return entry.output
    }

    private func remember(_ output: String, call: LocalToolCall, at date: Date, prefetched: Bool = false) {
        guard let key = policy.key(call),
              let output = policy.reusableOutput(output, call: call, prefetched: prefetched) else { return }
        // Keep memory bounded even if a model repeatedly asks for distinct large snapshots.
        guard output.utf8.count <= 64_000 else { return }
        if cache.count >= 32 { cache.removeAll() }
        cache[key] = CachedRead(output: output, expires: policy.expiresAt(output: output, call: call, readAt: date), prefetched: prefetched)
    }

    private func perform(_ call: LocalToolCall) async throws -> String {
        try Task.checkCancellation()
        progress(ToolConversationLoop.status(for: call.name))
        metrics.executedTools += 1
        active += 1; metrics.maximumParallel = max(metrics.maximumParallel, active)
        let began = Date.now
        defer {
            active -= 1
            log("tool \(call.name) \(String(format: "%.1f", Date.now.timeIntervalSince(began)))s")
        }
        let result = try await execute(call)
        try Task.checkCancellation()
        return result
    }

    func batch(_ calls: [LocalToolCall]) async throws -> [String] {
        var outputs = Array(repeating: "", count: calls.count)
        var index = 0
        while index < calls.count {
            try Task.checkCancellation()
            let call = calls[index]
            if let previous = completed[call.id] {
                outputs[index] = previous; index += 1; continue
            }
            if let previous = cached(call) {
                outputs[index] = previous; completed[call.id] = previous; index += 1; continue
            }
            if !policy.canRunInParallel(call) {
                // A write or unknown tool may alter data, permissions, pending cards or the
                // active selection. Invalidate on both sides, even if execution throws.
                cache.removeAll()
                let startVersion = policy.epoch?.version
                let began = policy.now()
                let output: String
                do { output = try await perform(call) }
                catch { cache.removeAll(); throw error }
                cache.removeAll(); synchronize()
                completed[call.id] = output; outputs[index] = output
                if startVersion == version { remember(output, call: call, at: began) } // only get_tasks is eligible
                index += 1
                continue
            }

            // Only adjacent independent reads can overlap. Stop before a duplicate so it
            // can reuse the first result if successful, or retry it if it failed/incomplete.
            var end = index
            var keys = Set<String>()
            var ids = Set<String>()
            var hasInventoryQuery = false
            while end < calls.count, end - index < policy.maximumParallelReads {
                let next = calls[end]
                guard policy.canRunInParallel(next), completed[next.id] == nil,
                      !ids.contains(next.id), !(hasInventoryQuery && next.name == "search_inventory") else { break }
                if let key = policy.key(next), !keys.insert(key).inserted { break }
                ids.insert(next.id)
                hasInventoryQuery = hasInventoryQuery || next.name == "search_inventory"
                end += 1
            }
            let startVersion = policy.epoch?.version
            let readAt = policy.now()
            let start = index
            var results: [ReadResult] = []
            // Resolve already cached calls before allocating child tasks. Cache results
            // retain their original position, just like out-of-order network completions.
            var jobs: [Int] = []
            for position in start..<end {
                if position != start, let output = cached(calls[position]) {
                    results.append(ReadResult(index: position, output: output))
                } else { jobs.append(position) }
            }
            if jobs.count > 1 {
                metrics.parallelGroups += 1
                results += try await withThrowingTaskGroup(of: ReadResult.self) { group in
                    for position in jobs {
                        let job = calls[position]
                        group.addTask { @MainActor in
                            ReadResult(index: position, output: try await self.perform(job))
                        }
                    }
                    var values: [ReadResult] = []
                    do {
                        for try await result in group { values.append(result) }
                    } catch {
                        group.cancelAll()
                        throw error
                    }
                    return values
                }
            } else if let position = jobs.first {
                results.append(ReadResult(index: position, output: try await perform(calls[position])))
            }
            try Task.checkCancellation()
            synchronize()
            for result in results {
                let job = calls[result.index]
                outputs[result.index] = result.output
                completed[job.id] = result.output
                if startVersion == version, jobs.contains(result.index) { remember(result.output, call: job, at: readAt) }
            }
            index = end
        }
        return outputs
    }
}
