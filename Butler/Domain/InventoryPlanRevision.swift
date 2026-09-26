import Foundation

enum InventoryStorageChoice: String, CaseIterable, Hashable, Sendable {
    case refrigerated = "冷藏"
    case frozen = "冷冻"

    /// Default "eat it within" horizon shown on the choice and recorded as a plan estimate.
    var planHorizonDays: Int {
        switch self {
        case .frozen: 60
        case .refrigerated: 1
        }
    }
}

enum InventoryClarificationAnswer: Hashable, Sendable {
    case storageLocation(InventoryStorageChoice)
    /// The user postponed the question; keep exactly what they said ("冰箱") and ask again later.
    case postponedStorage(statedLocation: String)
}

enum InventoryProductChoice: Hashable, Sendable {
    case existing(productID: UUID)
    case createSeparate
}

struct InventoryPlanRevision: Sendable {
    let plan: InventoryOperationPlan
    let localRevision: Int
}

/// A local review draft, never a repository mutation or a confirmation receipt.
struct InventoryReviewEdit: Sendable {
    var name: String
    var quantity: String
    var unit: String
    var storage: String
    var purchasedAt: Date?
    var packageExpiry: Date?
    var estimatedExpiry: Date?
    var plannedUseBy: Date?

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !quantity.isEmpty && quantity.allSatisfy { $0 >= "0" && $0 <= "9" } &&
        (Int(quantity) ?? 0) > 0 &&
        [purchasedAt, packageExpiry, estimatedExpiry, plannedUseBy].compactMap { $0 }
            .allSatisfy { $0.timeIntervalSince1970.isFinite }
    }
}
