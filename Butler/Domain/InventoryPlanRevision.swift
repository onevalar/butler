import Foundation

enum InventoryStorageChoice: String, CaseIterable, Hashable, Sendable {
    case refrigerated = "冷藏"
    case frozen = "冷冻"
}

enum InventoryClarificationAnswer: Hashable, Sendable {
    case storageLocation(InventoryStorageChoice)
}

enum InventoryProductChoice: Hashable, Sendable {
    case existing(productID: UUID)
    case createSeparate
}

struct InventoryPlanRevision: Sendable {
    let plan: InventoryOperationPlan
    let localRevision: Int
}
