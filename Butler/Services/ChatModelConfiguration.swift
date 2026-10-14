import Foundation

/// User choices travel with each request. The server remains authoritative about account access.
struct ChatModelConfiguration: Equatable {
    var model = "gpt-6-sol"
    var effort = "low"
    static let modelKey = "chatModelID"
    static let effortKey = "chatReasoningEffort"
    static let models = ["gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna", "gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-luna"]
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    static func load(_ defaults: UserDefaults) -> Self {
        Self(model: defaults.string(forKey: modelKey) ?? "gpt-6-sol",
             effort: defaults.string(forKey: effortKey) ?? "low")
    }

    static func name(_ model: String) -> String {
        model.replacingOccurrences(of: "gpt-", with: "GPT-")
            .replacingOccurrences(of: "-sol", with: " Sol")
            .replacingOccurrences(of: "-luna", with: " Luna")
            .replacingOccurrences(of: "-astra", with: " Astra")
    }
    static func effortLabel(_ effort: String) -> String {
        switch effort {
        case "low": "轻量"; case "medium": "标准"; case "high": "深入"
        case "xhigh": "更深入"; case "max": "最高"; default: effort
        }
    }
}
