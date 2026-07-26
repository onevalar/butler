import Foundation

/// Everything a planner may know. Inventory and persistence are deliberately absent.
struct InventoryPlanningInput: Sendable {
    let text: String
    let locale: Locale
    let referenceDate: Date
    let timeZone: TimeZone
    let inputID: UUID
    let planID: UUID
}

protocol InventoryPlanProvider: Sendable {
    func plan(for input: InventoryPlanningInput) async throws -> InventoryOperationPlan
}

enum InventoryPlanningError: Error, LocalizedError, Sendable {
    case emptyInput
    case unsupportedLanguage
    case tooManyClauses(maximum: Int)
    case noInventoryItems
    case invalidProviderPlan(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput: return "请输入物品信息。"
        case .unsupportedLanguage: return "本地解析器目前只支持中文输入。"
        case .tooManyClauses(let maximum): return "一次最多可处理 \(maximum) 件物品。"
        case .noInventoryItems: return "没有识别到“数量 + 单位 + 物品名”。"
        case .invalidProviderPlan(let reason): return "生成的操作计划无效：\(reason)"
        }
    }
}

enum InventoryPlanningQuestion: Hashable, Sendable {
    case field(UnresolvedInventoryField)
    case productChoice(operationID: UUID, proposedProductID: UUID, candidates: [CatalogProductCandidate])
}
