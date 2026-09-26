import Foundation
import Observation

struct OnDeviceChatTurn: Identifiable {
    let id = UUID()
    var question: String
    var answer: String = ""
    var failed = false
}

@MainActor @Observable
final class OnDeviceChat {
    let connection = SubscriptionConnection()
    private(set) var agent: LocalAgent?
    private(set) var turns: [OnDeviceChatTurn] = []
    var draft = UserDefaults.standard.string(forKey: "onDeviceAgentDraft") ?? "" {
        didSet { UserDefaults.standard.set(draft, forKey: "onDeviceAgentDraft") }
    }
    var error: String?
    var notice: String?
    private var task: Task<Void, Never>?
    private(set) var working = false
    private(set) var fixture = false
    var available: Bool { fixture || connection.isLoggedIn }
    var canSend: Bool { available && agent != nil && !working && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.count <= 8000 }

    init() {
        do {
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--local-agent-fixture") || args.contains("--local-agent-offline") {
                fixture = true
                let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let file = directory.appendingPathComponent("local-agent-ui-fixture.json")
                if args.contains("--local-agent-reset-fixture"), FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
                agent = LocalAgent(memory: try LocalMemoryStore(file: file), model: OnDeviceFixtureModel(offline: args.contains("--local-agent-offline")))
                return
            }
            #endif
            agent = LocalAgent(memory: try LocalMemoryStore.openOnDevice(), model: SubscriptionModel(connection: connection))
        } catch { self.error = "无法读取本机记忆。原文件已保留，请勿清空 App 数据。" }
    }

    func send() {
        guard canSend, let agent else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        working = true; error = nil; notice = nil
        turns.append(OnDeviceChatTurn(question: text))
        let index = turns.count - 1
        task = Task {
            defer { working = false; task = nil }
            do {
                turns[index].answer = try await agent.send(text)
                draft = ""
            } catch {
                let message = SubscriptionConnection.message(error)
                turns[index].failed = true
                turns[index].answer = message
                self.error = message
                // Keep the draft; no local write can happen during a model turn.
            }
        }
    }

    func stop() { task?.cancel() }

    func didSignIn() {
        guard !working, let memory = agent?.memory else { return }
        memory.discard()
        agent = LocalAgent(memory: memory, model: SubscriptionModel(connection: connection))
        turns = []; error = nil; notice = "已登录。新对话可以查询本机已保存的记忆。"
    }

    func confirm() {
        guard !working, let id = agent?.memory.preview?.id else { return }
        do {
            try agent?.confirm(id)
            error = nil; notice = "已保存到这台 iPhone。"
        } catch { self.error = "保存失败，尚未写入本机。请保留预览并重试。" }
    }

    func discard() {
        guard !working else { return }
        do { try agent?.discard(); notice = "已取消，本机记忆没有改变。"; error = nil }
        catch { self.error = "操作未完成，请稍后重试。" }
    }

    func signOut() {
        guard !working else { return }
        do {
            try connection.signOut()
            try agent?.discard()
            // Do not send a previous account's conversation to a new account.
            if let memory = agent?.memory { agent = LocalAgent(memory: memory, model: SubscriptionModel(connection: connection)) }
            turns = []; notice = "已退出登录。本机记忆仍可查看。"
        } catch { self.error = SubscriptionConnection.message(error) }
    }
}

#if DEBUG
/// Explicit UI-test substitute. Never selected by login failure or production code.
@MainActor
private final class OnDeviceFixtureModel: LocalAgentModel {
    let offline: Bool
    init(offline: Bool) { self.offline = offline }

    func reply(to messages: [LocalAgentMessage]) async throws -> LocalModelReply {
        let slow = ProcessInfo.processInfo.arguments.contains("--local-agent-slow")
        try await Task.sleep(for: .milliseconds(slow ? 5000 : 300))
        if offline { throw URLError(.notConnectedToInternet) }
        switch messages.last {
        case .user(let text):
            if text.contains("剩") {
                return LocalModelReply(text: "", calls: [.init(id: UUID().uuidString, name: "search_memory", arguments: #"{"query":"盒马麻薯"}"#)])
            }
            return LocalModelReply(text: "", calls: [.init(id: UUID().uuidString, name: "propose_memory",
                arguments: #"{"id":null,"title":"盒马麻薯","text":"放冰箱上层；到期日未提供。","quantity":6}"#)])
        case .tool(_, let result):
            if let data = result.data(using: .utf8), let records = try? JSONDecoder().decode([LocalMemory].self, from: data), let record = records.first {
                return LocalModelReply(text: "", calls: [.init(id: UUID().uuidString, name: "set_remaining", arguments: "{\"id\":\"\(record.id)\",\"quantity\":2}")])
            }
            return LocalModelReply(text: "界面测试替身：请核对下面的预览，确认后才保存。", calls: [])
        default: return LocalModelReply(text: "界面测试替身，没有调用真实模型。", calls: [])
        }
    }
}
#endif
