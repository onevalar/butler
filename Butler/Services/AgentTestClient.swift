import Foundation
import Observation
import Security

struct AgentMemory: Codable, Identifiable {
    var id: String?
    var kind: String
    var subject: String
    var shop: String
    var text: String?
    var quantity: Int?
    var unit: String?
    var location: String?
    var expiryDate: String?

    var title: String { [shop, subject].filter { !$0.isEmpty }.joined(separator: " · ") }
    var detail: String {
        if kind == "note" { return text ?? "" }
        return [quantity.map { "\($0)\(unit ?? "")" }, location,
                "到期日：\(expiryDate ?? "未提供")"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct AgentProposal: Decodable {
    var id: String
    var before: AgentMemory?
    var after: AgentMemory?
}

struct AgentMessage: Decodable, Identifiable {
    var id: String
    var text: String
    var status: String
    var answer: String
    var error: String?
}

struct AgentTestState: Decodable {
    var model: String
    var reasoningEffort: String
    var fictional: Bool
    var busy: Bool
    var records: [AgentMemory]
    var proposal: AgentProposal?
    var messages: [AgentMessage]
}

@MainActor @Observable
final class AgentTestClient {
    struct Pending: Codable {
        var id: String
        var text: String
        var endpoint: String
    }
    var endpoint = UserDefaults.standard.string(forKey: "agentTestEndpoint") ?? ""
    var token = ""
    var draft = ""
    var state: AgentTestState?
    var error: String?
    var notice: String?
    var working = false
    var connected = false
    var pending: Pending?
    private let network: URLSession

    init(network: URLSession = .shared) {
        self.network = network
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "butler.agent-test", kSecAttrAccount as String: "access-token",
            kSecReturnData as String: true]
        var value: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
           let data = value as? Data { token = String(data: data, encoding: .utf8) ?? "" }
        if let data = UserDefaults.standard.data(forKey: "agentTestPending") {
            pending = try? JSONDecoder().decode(Pending.self, from: data)
        }
        #if DEBUG
        // Simulator validation only; never ship credentials in the app bundle.
        if let url = ProcessInfo.processInfo.environment["BUTLER_AGENT_URL"] { endpoint = url }
        if let key = ProcessInfo.processInfo.environment["BUTLER_AGENT_TOKEN"] { token = key }
        #endif
    }

    static func baseURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        // Unencrypted access is permitted only on the same machine for simulator testing.
        guard url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)) else { return nil }
        return url
    }

    func connect(endpoint: String, token: String) async {
        guard !working else { return }
        guard Self.baseURL(endpoint) != nil, token.count >= 32 else {
            error = "请输入 HTTPS 服务地址和至少32位的访问密钥。模拟器也可连接本机服务。"; return
        }
        if pending != nil && self.endpoint != endpoint {
            error = "还有发送状态未知的消息，请先连接原服务核对，避免重复记录。"; return
        }
        self.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        state = nil; connected = false
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "butler.agent-test", kSecAttrAccount as String: "access-token"]
        let values: [String: Any] = [kSecValueData as String: Data(self.token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { error = "无法安全保存访问密钥，请重试。"; return }
        UserDefaults.standard.set(self.endpoint, forKey: "agentTestEndpoint")
        await refresh()
    }

    func refresh() async { await perform(path: "state") }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard connected, !working, state?.busy == false, pending == nil, !text.isEmpty, text.count <= 2000 else { return }
        pending = Pending(id: UUID().uuidString, text: text, endpoint: endpoint)
        notice = nil
        UserDefaults.standard.set(try? JSONEncoder().encode(pending), forKey: "agentTestPending")
        draft = ""
        await retryPending()
    }

    func retryPending() async {
        guard let pending, pending.endpoint == endpoint else { return }
        await perform(path: "messages", body: ["id": pending.id, "text": pending.text])
    }

    func confirm() async {
        guard connected, !working, state?.busy == false, let proposal = state?.proposal else { return }
        await perform(path: "confirm", body: ["id": proposal.id])
        if connected && error == nil { notice = "已保存。可在右上角查看记忆，也可以继续说话修改。" }
    }

    func discard() async {
        guard connected, !working, state?.busy == false, let proposal = state?.proposal else { return }
        await perform(path: "discard", body: ["id": proposal.id])
        if connected && error == nil { notice = "已取消，没有保存这次修改。" }
    }

    private func perform(path: String, body: [String: String]? = nil) async {
        guard !working, let base = Self.baseURL(endpoint), !token.isEmpty else { return }
        working = true
        defer { working = false }
        var request = URLRequest(url: base.appendingPathComponent("v1").appendingPathComponent(path))
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(body)
        }
        do {
            let (data, response) = try await network.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(http.statusCode) else {
                connected = false
                error = http.statusCode == 401 ? "访问密钥不正确，请在连接设置中更新。"
                    : "服务未接受这次操作。请刷新状态，核对是否仍需确认；不要重复新建记录。"
                return
            }
            let result = try JSONDecoder().decode(AgentTestState.self, from: data)
            guard result.fictional else { throw URLError(.badServerResponse) }
            state = result; connected = true; error = nil
            if let pending, result.messages.contains(where: { $0.id == pending.id }) {
                self.pending = nil
                UserDefaults.standard.removeObject(forKey: "agentTestPending")
            }
        } catch {
            connected = false
            self.error = "连接中断，操作结果可能尚未收到。请恢复连接后刷新状态，已保存的记录不会因关闭页面而丢失。"
        }
    }
}
