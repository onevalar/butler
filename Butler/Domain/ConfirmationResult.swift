import Foundation

/// Local evidence, not executable authorization. Never infer a state from receipt text.
struct ConfirmationResult: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case notStarted, running, succeeded, failed, needsVerification, awaitingUser, reported

        var label: String {
            switch self {
            case .notStarted: "未开始"
            case .running: "执行中"
            case .succeeded: "已完成"
            case .failed: "未完成"
            case .needsVerification: "结果待核实"
            case .awaitingUser: "等你操作"
            case .reported: "收到系统回执"
            }
        }
    }

    let proposalID: UUID
    let requestTurnID: UUID?
    let title: String
    var state: State
    var message: String
    var relatedScopeKeys: [String]?
    var id: UUID { proposalID }

    /// An interrupted call may already have changed a device. Absence of a final
    /// receipt proves neither failure nor success and must never enable a retry.
    var recovered: Self {
        guard state == .running || state == .awaitingUser else { return self }
        var value = self
        value.state = .needsVerification
        value.message = state == .awaitingUser
            ? "\(title)：上次选择流程已结束，最终授权结果没有保存。请先核对已有授权；没有自动继续选择。"
            : "\(title)：执行曾开始，但最终结果没有保存。请先核查；没有自动重试或撤销。"
        return value
    }
}

/// Removes only an exact repeated title, never an execution warning or a distinct result.
enum ConfirmationPresentation {
    static func detail(_ message: String?, title: String) -> String? {
        guard var text = message?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("✓") || text.hasPrefix("✗") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == title { return nil }
        for separator in ["：", ":", " · ", "\n"] where !title.isEmpty && text.hasPrefix(title + separator) {
            text = String(text.dropFirst(title.count + separator.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return text.isEmpty ? nil : text
    }
}
