import Foundation
import Security

enum SpeechRecognitionProvider: String, CaseIterable {
    case apple, custom
    var title: String { self == .apple ? "苹果语音识别" : "自定义语音模型" }
}

struct CustomSpeechConfiguration: Sendable {
    let endpoint: URL
    let model: String
    let apiKey: String
    var usesRealtime: Bool { model == "gpt-live-transcribe" }
    var realtimeEndpoint: URL {
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        parts.scheme = "wss"
        parts.path = String(parts.path.dropLast("/audio/transcriptions".count)) + "/realtime"
        parts.queryItems = [.init(name: "intent", value: "transcription"), .init(name: "model", value: model)]
        return parts.url!
    }

    static func endpoint(for baseURL: String) throws -> URL {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: raw), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else {
            throw SpeechServiceError.invalidConfiguration("Base URL 须为 HTTPS 地址，不包含账号、密码、查询参数或片段。")
        }
        parts.scheme = "https"
        parts.host = host.lowercased()
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        // AiHubMix documents these hosts with a /v1 API prefix. Accept a bare host without
        // accidentally posting to its website path; do not guess paths for other providers.
        if ["aihubmix.com", "api.aihubmix.com", "api.inferera.com"].contains(host.lowercased()) {
            if path.isEmpty { path = "/v1" }
            if path == "/audio/transcriptions" { path = "/v1/audio/transcriptions" }
        }
        if !path.hasSuffix("/audio/transcriptions") { path += "/audio/transcriptions" }
        parts.path = path
        guard let url = parts.url else { throw SpeechServiceError.invalidConfiguration("Base URL 无效。") }
        return url
    }

    static func validated(baseURL: String, model: String, apiKey: String) throws -> Self {
        let endpoint = try endpoint(for: baseURL)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.count <= 200, !model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SpeechServiceError.invalidConfiguration("请填写服务商提供的语音模型名称。")
        }
        guard !key.isEmpty, !key.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains) else {
            throw SpeechServiceError.invalidConfiguration("请填写有效的 API Key。")
        }
        guard !key.lowercased().hasPrefix("bearer") else {
            throw SpeechServiceError.invalidConfiguration("API Key 只填写密钥本身，不要包含 Bearer 前缀。")
        }
        return Self(endpoint: endpoint, model: model, apiKey: key)
    }
}

enum SpeechServiceError: LocalizedError {
    case invalidConfiguration(String), keychain, invalidResponse, http(Int), rejected(Int, SpeechRejectionReason), emptyAudio, tooLong, realtime, audioBacklog
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): message
        case .keychain: "语音密钥无法保存到系统钥匙串，请重试。"
        case .invalidResponse: "语音服务未返回有效的识别文字，请检查接口格式和模型。"
        case .http(401): "语音服务鉴权失败（401），请检查 API Key 是否有效或已过期。"
        case .http(403): "语音服务拒绝访问（403），可能是模型权限、额度或 IP 限制，不一定是密钥错误。"
        case .rejected(let status, let reason): "\(reason.message)（\(status)）"
        case .http(404): "未找到语音识别接口，请检查 Base URL 和模型。"
        case .http(429): "语音服务限流或额度不足，请稍后重试。"
        case .http(let status): "语音服务返回错误（\(status)），请稍后重试。"
        case .emptyAudio: "没有录到有效语音，请再次按住说话。"
        case .tooLong: "自定义语音每次最多录制 2 分钟，请分段输入。"
        case .realtime: "实时语音连接中断或配置被服务端拒绝，请检查网络和模型权限后重试。"
        case .audioBacklog: "实时语音网络跟不上录音，已停止本次输入，请检查网络后重试。"
        }
    }
}

/// Classify provider errors locally, but never display or log arbitrary server text: it can
/// contain a credential suffix, account details or echoed audio/transcript content.
enum SpeechRejectionReason: String {
    case quota, modelPermission, ipRestriction, accountSuspended, invalidKey, modelUnavailable
    var message: String {
        switch self {
        case .quota: "语音服务账户余额或密钥额度不足，请检查服务商控制台"
        case .modelPermission: "此 API Key 没有当前语音模型的访问权限，请检查密钥的模型限制"
        case .ipRestriction: "当前网络 IP 不在 API Key 的允许范围内，请检查服务商的 IP 白名单"
        case .accountSuspended: "语音服务账户或密钥已停用，请检查服务商控制台"
        case .invalidKey: "语音服务返回密钥无效或已过期，请重新填写 API Key"
        case .modelUnavailable: "当前语音模型不存在或没有可用服务渠道，请核对模型和接口"
        }
    }
    static func parse(_ data: Data) -> Self? {
        guard data.count < 64_000, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let error = object["error"] as? [String: Any] ?? object
        let code = (error["code"] as? String ?? "").lowercased()
        let message = (error["message"] as? String ?? "").lowercased()
        if ["insufficient_user_quota", "insufficient_quota", "insufficient_token_quota"].contains(code)
            || message.contains("balance is insufficient") || message.contains("quota is insufficient") { return .quota }
        if message.contains("not authorized to access the requested model") || code == "model_not_allowed" { return .modelPermission }
        if message.contains("approved ip ranges") || code == "ip_not_allowed" { return .ipRestriction }
        if message.contains("account suspended") || code == "account_deactivated" { return .accountSuspended }
        if code == "invalid_api_key" || message.contains("access token is invalid or expired") { return .invalidKey }
        if code == "model_not_found" || message.contains("incorrect model id") { return .modelUnavailable }
        return nil
    }
}

/// Credentials are bound to the configured endpoint, never exported or exposed to model tools.
@MainActor
struct SpeechRecognitionSettings {
    static let providerKey = "speechRecognitionProvider"
    let defaults: UserDefaults
    let account: String
    init(defaults: UserDefaults = .standard, account: String = "custom-speech") {
        self.defaults = defaults
        self.account = account
    }
    var provider: SpeechRecognitionProvider {
        SpeechRecognitionProvider(rawValue: defaults.string(forKey: Self.providerKey) ?? "") ?? .apple
    }
    var baseURL: String { defaults.string(forKey: "speechRecognitionBaseURL") ?? "" }
    var model: String { defaults.string(forKey: "speechRecognitionModel") ?? "" }
    var hasSavedKey: Bool { credential != nil }

    func customConfiguration() throws -> CustomSpeechConfiguration {
        let endpoint = try CustomSpeechConfiguration.endpoint(for: baseURL)
        guard let credential, credential.matches(endpoint) else {
            throw SpeechServiceError.invalidConfiguration("请先在语音识别设置中保存此服务的 API Key。")
        }
        return try .validated(baseURL: baseURL, model: model, apiKey: credential.key)
    }

    func save(provider: SpeechRecognitionProvider, baseURL: String, model: String, newKey: String) throws {
        if provider == .custom {
            let endpoint = try CustomSpeechConfiguration.endpoint(for: baseURL)
            let entered = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = entered.isEmpty && credential?.matches(endpoint) == true ? credential?.key ?? "" : entered
            let config = try CustomSpeechConfiguration.validated(baseURL: baseURL, model: model, apiKey: key)
            let data = try JSONEncoder().encode(Credential(endpoint: config.endpoint.absoluteString, key: config.apiKey))
            let attributes: [String: Any] = [kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw SpeechServiceError.keychain }
            defaults.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "speechRecognitionBaseURL")
            defaults.set(config.model, forKey: "speechRecognitionModel")
        }
        defaults.set(provider.rawValue, forKey: Self.providerKey)
    }

    func removeCustomConfiguration() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SpeechServiceError.keychain }
        defaults.set(SpeechRecognitionProvider.apple.rawValue, forKey: Self.providerKey)
        defaults.removeObject(forKey: "speechRecognitionBaseURL")
        defaults.removeObject(forKey: "speechRecognitionModel")
    }

    private struct Credential: Codable {
        let endpoint: String
        let key: String
        func matches(_ url: URL) -> Bool {
            // Correct the old missing-/v1 path only on the same documented provider host.
            (try? CustomSpeechConfiguration.endpoint(for: endpoint)) == url
        }
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "butler.speech",
         kSecAttrAccount as String: account]
    }
    private var credential: Credential? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Credential.self, from: data)
    }
}
