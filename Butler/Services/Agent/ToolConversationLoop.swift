import Foundation

/// The shared conversation loop. Storage, confirmation and summarization belong to its caller.
@MainActor
enum ToolConversationLoop {
    static func run(model: any LocalAgentModel, messages: inout [LocalAgentMessage],
                    prefetched: [PrefetchedToolResult] = [],
                    rounds: Int = 30, execute: (LocalToolCall) async throws -> String,
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
            let reply = try await model.reply(to: messages)
            log("round \(round) \(String(format: "%.1f", Date.now.timeIntervalSince(asked)))s calls=\(reply.calls.map(\.name).joined(separator: ","))")
            try Task.checkCancellation()
            messages.append(.assistant(reply))
            if reply.calls.isEmpty { return reply.text.isEmpty ? "好的。" : reply.text }
            for call in reply.calls.prefix(12) {
                try Task.checkCancellation()
                let output: String
                if let previous = completed[call.id] {
                    output = previous
                } else {
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
}
