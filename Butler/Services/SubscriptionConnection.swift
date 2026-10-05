import Foundation
import Observation
import Security

enum SubscriptionError: LocalizedError {
    case signInRequired, invalidResponse, unavailable(Int), expiredCode, keychain, accountChanged
    /// chatgpt.com could not be reached at all (no network, or a proxy/VPN that is off).
    case unreachable
    /// The service refused the request and said why.
    case rejected(Int, String?)
    /// The model started but stopped with an error.
    case failed(String?)

    var errorDescription: String? {
        switch self {
        case .signInRequired: return "登录已失效，请重新登录订阅。手机里的记忆仍然保留。"
        case .invalidResponse: return "模型服务的返回格式暂不兼容，本次没有保存修改。"
        case .unavailable(let code):
            if code == 429 { return "当前订阅额度或请求频率受限，请稍后再试；不会转为额外付费。" }
            return "服务暂未接受请求（\(code)）。请稍后重试，本次没有保存修改。"
        case .expiredCode: return "登录码已过期，请重新获取。"
        case .keychain: return "无法访问系统钥匙串，请重新打开 App 后再试。"
        case .accountChanged: return "登录账号发生变化，请重新登录后再继续。"
        case .unreachable: return "连不上模型服务（chatgpt.com）。如果你平时通过代理或 VPN 使用，请确认它开着。你说的话已放回输入框。"
        case .rejected(let code, let message):
            if code == 429 { return "订阅额度或请求频率受限，请稍后再试。" + (message.map { "（\($0)）" } ?? "") }
            return "模型服务拒绝了请求（\(code)）" + (message.map { "：\($0)" } ?? "。")
        case .failed(let message):
            return "模型这次没能完成回答" + (message.map { "：\($0)" } ?? "，请重试。")
        }
    }
}

struct SubscriptionCredentials: Codable {
    var accessToken: String
    var refreshToken: String
    var accountID: String
    var expiresAt: Date
}

struct SubscriptionDeviceCode: Identifiable {
    var id: String
    var code: String
    var interval: TimeInterval
    var deadline: Date
}

/// Direct device authorization; no callback server, CLI, or shared application secret.
@MainActor @Observable
final class SubscriptionConnection {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let verificationURL = URL(string: "https://auth.openai.com/codex/device")!
    private let network: URLSession
    private let keychainAccount: String
    private var credentials: SubscriptionCredentials?
    private(set) var deviceCode: SubscriptionDeviceCode?
    private(set) var signingIn = false
    var error: String?
    var isLoggedIn: Bool { credentials != nil }
    var accountIdentifier: String? { credentials?.accountID }

    // Match other observable services: avoid iOS 26's isolated-deinit runtime crash.
    nonisolated deinit {}

    init(network: URLSession = .shared, keychainAccount: String = "personal") {
        self.network = network
        self.keychainAccount = keychainAccount
        reloadStoredCredentials()
    }

    /// A background launch may happen while the keychain is locked. Retry locally after unlock.
    func reloadStoredCredentials() {
        let previous = accountIdentifier
        var query = vaultQuery
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            do { credentials = try JSONDecoder().decode(SubscriptionCredentials.self, from: data); error = nil }
            catch { self.error = "登录记录无法读取，请重新登录。" }
        } else if status == errSecItemNotFound { credentials = nil }
        else { error = SubscriptionError.keychain.localizedDescription }
        if previous != accountIdentifier { NotificationCenter.default.post(name: .init("butlerBriefSourcesChanged"), object: nil) }
    }

    private var vaultQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "butler.subscription", kSecAttrAccount as String: keychainAccount]
    }

    private func save(_ value: SubscriptionCredentials) throws {
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(vaultQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(vaultQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SubscriptionError.keychain }
        let changedAccount = credentials?.accountID != value.accountID
        credentials = value
        if changedAccount { NotificationCenter.default.post(name: .init("butlerBriefSourcesChanged"), object: nil) }
    }

    func signOut() throws {
        let status = SecItemDelete(vaultQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SubscriptionError.keychain }
        credentials = nil
        deviceCode = nil
        error = nil
        NotificationCenter.default.post(name: .init("butlerBriefSourcesChanged"), object: nil)
    }

    func beginLogin() async {
        guard !signingIn else { return }
        signingIn = true; error = nil; deviceCode = nil
        defer { signingIn = false }
        do {
            let result = try await jsonRequest(path: "/api/accounts/deviceauth/usercode", body: ["client_id": Self.clientID])
            guard let id = result["device_auth_id"] as? String,
                  let code = (result["user_code"] ?? result["usercode"]) as? String,
                  !id.isEmpty, !code.isEmpty else { throw SubscriptionError.invalidResponse }
            let interval = Double((result["interval"] as? String ?? "5").trimmingCharacters(in: .whitespaces)) ?? 5
            deviceCode = SubscriptionDeviceCode(id: id, code: code, interval: max(1, interval), deadline: Date().addingTimeInterval(900))
        } catch is CancellationError { }
        catch { self.error = Self.message(error) }
    }

    func cancelLogin() { deviceCode = nil }

    func awaitApproval() async {
        guard let code = deviceCode else { return }
        do {
            while deviceCode?.id == code.id {
                try Task.checkCancellation()
                guard Date() < code.deadline else { throw SubscriptionError.expiredCode }
                var request = Self.authRequest(path: "/api/accounts/deviceauth/token")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["device_auth_id": code.id, "user_code": code.code])
                let (data, response) = try await network.data(for: request)
                try Task.checkCancellation()
                guard deviceCode?.id == code.id else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 403 || status == 404 {
                    try await Task.sleep(for: .seconds(min(code.interval, max(0, code.deadline.timeIntervalSinceNow))))
                    continue
                }
                guard (200..<300).contains(status) else { throw SubscriptionError.unavailable(status) }
                guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let authorization = body["authorization_code"] as? String,
                      let verifier = body["code_verifier"] as? String else { throw SubscriptionError.invalidResponse }
                var exchange = Self.authRequest(path: "/oauth/token")
                exchange.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                exchange.httpBody = Self.form(["grant_type": "authorization_code", "client_id": Self.clientID,
                    "code": authorization, "code_verifier": verifier,
                    "redirect_uri": "https://auth.openai.com/deviceauth/callback"])
                let (tokens, tokenResponse) = try await network.data(for: exchange)
                try Task.checkCancellation()
                guard deviceCode?.id == code.id else { return }
                let tokenStatus = (tokenResponse as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(tokenStatus) else { throw SubscriptionError.unavailable(tokenStatus) }
                let result = try Self.decodeCredentials(tokens)
                try save(result)
                deviceCode = nil; error = nil
                return
            }
        } catch is CancellationError { }
        catch {
            if deviceCode?.id == code.id { deviceCode = nil; self.error = Self.message(error) }
        }
    }

    func authorizedCredentials(preserveOnFailure: Bool = false) async throws -> SubscriptionCredentials {
        guard let current = credentials else { throw SubscriptionError.signInRequired }
        if current.expiresAt.timeIntervalSinceNow > 300 { return current }
        do {
            let response = try await jsonRequest(path: "/oauth/token", body: ["grant_type": "refresh_token",
                "client_id": Self.clientID, "refresh_token": current.refreshToken])
            let data = try JSONSerialization.data(withJSONObject: response)
            let updated = try Self.decodeCredentials(data, previous: current)
            guard updated.accountID == current.accountID else { throw SubscriptionError.accountChanged }
            try save(updated)
            return updated
        } catch SubscriptionError.unavailable(let status) where status == 400 || status == 401 {
            if !preserveOnFailure { try signOut() }
            throw SubscriptionError.signInRequired
        }
    }

    private func jsonRequest(path: String, body: [String: String]) async throws -> [String: Any] {
        var request = Self.authRequest(path: path)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await network.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw SubscriptionError.unavailable(status) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SubscriptionError.invalidResponse }
        return json
    }

    private static func authRequest(path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://auth.openai.com" + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }

    static func claims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func decodeCredentials(_ data: Data, previous: SubscriptionCredentials? = nil) throws -> SubscriptionCredentials {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String ?? previous?.accessToken,
              let refresh = json["refresh_token"] as? String ?? previous?.refreshToken,
              !access.isEmpty, !refresh.isEmpty else { throw SubscriptionError.invalidResponse }
        let account = (json["id_token"] as? String).flatMap { claims($0)?["https://api.openai.com/auth"] as? [String: Any] }?["chatgpt_account_id"] as? String
        guard let accountID = account ?? previous?.accountID, !accountID.isEmpty else { throw SubscriptionError.invalidResponse }
        let expiry = (claims(access)?["exp"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date().addingTimeInterval(3600)
        return SubscriptionCredentials(accessToken: access, refreshToken: refresh, accountID: accountID, expiresAt: expiry)
    }

    static func message(_ error: Error) -> String {
        if let known = error as? SubscriptionError { return known.localizedDescription }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return "已停止，本次没有保存修改。" }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut:
                return "模型太久没有回应，已停止等待（自动重试过一次）。你说的话已放回输入框，可以直接再发。"
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return "网络断开了，本次没有保存修改。连上网后再发一次，你说的话已放回输入框。"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed:
                return "连不上模型服务，请稍后再试。你说的话已放回输入框。"
            default:
                return "网络出错（\(url.code.rawValue)），本次没有保存修改。你说的话已放回输入框。"
            }
        }
        return "出错了：\(error.localizedDescription)。本次没有保存修改，你说的话已放回输入框。"
    }
}
