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
    /// The user described finishing or discarding something; that is done on the item itself for now.
    case usingUpNotSupported
    case invalidProviderPlan(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput: return "请输入物品信息。"
        case .unsupportedLanguage: return "本地解析器目前只支持中文输入。"
        case .tooManyClauses(let maximum): return "一次最多可处理 \(maximum) 件物品。"
        case .noInventoryItems: return "没听出买了什么，换个说法试试，比如“买了牛奶和两包方便面”。"
        case .usingUpNotSupported: return "吃完、丢掉的东西，请在那件东西的页面里点一下；一句话处理家里已有的东西还在做。"
        case .invalidProviderPlan(let reason): return "生成的操作计划无效：\(reason)"
        }
    }
}

enum InventoryPlanningQuestion: Hashable, Sendable {
    case field(UnresolvedInventoryField)
    case productChoice(operationID: UUID, proposedProductID: UUID, candidates: [CatalogProductCandidate])
}
