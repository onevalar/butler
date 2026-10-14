import Foundation

/// The shared conversation loop. Storage, confirmation and summarization belong to its caller.
@MainActor
enum ToolConversationLoop {
    static func run(model: any LocalAgentModel, messages: inout [LocalAgentMessage],
                    prefetched: [PrefetchedToolResult] = [],
                    rounds: Int = 30, execute: (LocalToolCall) async throws -> String,
                    completionFeedback: (String) -> String? = { _ in nil },
                    progress: (String) -> Void = { _ in },
                    log: (String) -> Void = ChatDiagnostics.log) async throws -> String? {
        try Task.checkCancellation()
        // These reads were executed by the phone, before the first model request. Keep their
        // contents at tool-data priority, never splice a user's note into developer instructions.
        if !prefetched.isEmpty {
            messages.append(.assistant(LocalModelReply(text: "", calls: prefetched.map(\.call))))
            for item in prefetched { messages.append(.tool(id: item.call.id, result: item.output)) }
        }
        var completed: [String: String] = [:]
        for round in 0..<rounds {
            try Task.checkCancellation()
            let asked = Date.now
            progress(round == 0 ? "正在理解你的安排…" : "正在整理结果…")
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
            for (index, call) in reply.calls.enumerated() {
                // Every advertised call needs a response, even when a batched request
                // exceeds the execution budget. Never leave unmatched calls in history.
                guard index < 12 else {
                    messages.append(.tool(id: call.id, result: #"{"error":"本轮工具数量超过12项，此项未执行；请拆分到下一轮。"}"#))
                    continue
                }
                try Task.checkCancellation()
                let output: String
                if let previous = completed[call.id] {
                    output = previous
                } else {
                    progress(status(for: call.name))
                    let began = Date.now
                    output = try await execute(call)
                    log("tool \(call.name) \(String(format: "%.1f", Date.now.timeIntervalSince(began)))s")
                    completed[call.id] = output
                }
                messages.append(.tool(id: call.id, result: output))
            }
        }
        return nil
    }

    private static func status(for name: String) -> String {
        switch name {
        case "get_tasks", "list_reminders": "正在查看任务和提醒…"
        case "search_inventory", "get_item_profile", "get_item_history": "正在查找家里的物品…"
        case "get_weather": "正在查询天气…"
        case "get_settings": "正在查看设置…"
        case "judge_with_jev": "正在核对匹配结果…"
        case let value where value.hasPrefix("propose_"): "正在准备修改，请稍后确认…"
        default: "正在读取相关资料…"
        }
    }
}
