import Foundation

/// A narrow, local authorization boundary. Model output never invokes a commit.
struct PendingDecision {
    let confirm: Bool
    let ids: Set<UUID>

    static func parse(_ text: String, pending: [PendingChange]) -> Self? {
        guard !pending.isEmpty else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "。！!")))
        if ["确认", "确认全部", "全部确认", "确认保存", "都确认", "好的，确认"].contains(value) {
            return Self(confirm: true, ids: Set(pending.map(\.id)))
        }
        if ["取消", "取消全部", "全部取消", "都不要了", "取消修改"].contains(value) {
            return Self(confirm: false, ids: Set(pending.map(\.id)))
        }
        for (prefix, confirm) in [("确认第", true), ("取消第", false)] {
            guard value.hasPrefix(prefix), value.hasSuffix("项") else { continue }
            let raw = String(value.dropFirst(prefix.count).dropLast())
            let numerals = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10]
            if let number = Int(raw) ?? numerals[raw], (1...pending.count).contains(number) {
                return Self(confirm: confirm, ids: [pending[number - 1].id])
            }
        }
        return nil
    }
}

extension PendingChange {
    var inventoryPreview: LotFacts? {
        switch kind {
        case .setQuantity(let lot, _), .close(let lot, _), .setDate(let lot, _, _), .move(let lot, _), .tracking(let lot, _): lot
        case .itemProfile(let lot, _): lot
        default: nil
        }
    }
}

extension ButlerTools {
    static let pendingTools = #"""
    {"type":"function","name":"get_pending_changes","description":"读取本会话尚未保存的修改，含稳定id、顺序和内容；不能把提案当作真实库存。","strict":true,"parameters":{"type":"object","properties":{},"required":[],"additionalProperties":false}},
    {"type":"function","name":"discard_pending_changes","description":"按用户要求移除或替换尚未保存的提案。ids须来自get_pending_changes；只移除指定项，替换时随后提出新版本；不修改真实数据，不执行确认。","strict":true,"parameters":{"type":"object","properties":{"ids":{"type":"array","minItems":1,"maxItems":100,"items":{"type":"string"}}},"required":["ids"],"additionalProperties":false}}
    """#

    var pendingContext: String {
        (try? encode(["saved": false, "changes": pending.enumerated().map { index, change in
            ["id": change.id.uuidString, "number": index + 1, "title": change.title, "detail": change.detail ?? ""] as [String: Any]
        }] as [String: Any])) ?? "{}"
    }

    func executePendingTool(_ name: String, data: Data) throws -> String? {
        if name == "get_pending_changes" { return pendingContext }
        guard name == "discard_pending_changes" else { return nil }
        struct Args: Decodable { let ids: [UUID] }
        let args = try JSONDecoder().decode(Args.self, from: data)
        guard !args.ids.isEmpty, Set(args.ids).isSubset(of: Set(pending.map(\.id))) else {
            throw ToolError("待确认项已改变，请重新读取")
        }
        args.ids.forEach { removePending($0) }
        return pendingContext
    }
}
