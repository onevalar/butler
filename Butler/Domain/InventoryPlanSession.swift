import Foundation

/// Applies only allowlisted UI answers to a frozen provider result.
struct InventoryPlanSession: Sendable {
    let basePlan: InventoryOperationPlan
    private(set) var localRevision = 0
    private var answers: [UnresolvedInventoryField: InventoryClarificationAnswer] = [:]
    private var productChoices: [UUID: InventoryProductChoice] = [:]

    private let referenceDate: Date
    private let calendar: Calendar

    init(basePlan: InventoryOperationPlan, referenceDate: Date = Date(), calendar: Calendar = .current) {
        self.basePlan = basePlan
        self.referenceDate = referenceDate
        self.calendar = calendar
    }

    mutating func answer(_ field: UnresolvedInventoryField, with answer: InventoryClarificationAnswer) {
        answers[field] = answer; localRevision += 1
    }

    mutating func choose(forCreateOperation operationID: UUID, _ choice: InventoryProductChoice) {
        productChoices[operationID] = choice; localRevision += 1
    }

    func materialize() -> InventoryPlanRevision {
        var removedCreateOperationIDs: Set<UUID> = []
        var replacementProducts: [UUID: UUID] = [:]
        for planned in basePlan.operations {
            guard case .createProduct(let create) = planned.operation,
                  case .existing(let existing)? = productChoices[planned.operationID] else { continue }
            removedCreateOperationIDs.insert(planned.operationID)
            replacementProducts[create.productID] = existing
        }
        let operations = basePlan.operations.compactMap { planned -> PlannedInventoryOperation? in
            if case .createProduct = planned.operation {
                return removedCreateOperationIDs.contains(planned.operationID) ? nil : planned
            }
            guard case .addLot(let lot) = planned.operation else { return planned }
            let storageField = basePlan.unresolvedFields.first {
                $0.operationID == planned.operationID && $0.entityID == lot.lotID && $0.fieldKey == .storageLocation
            }
            let storage: String?
            let storageSource: EvidenceSourceKind
            switch storageField.flatMap({ answers[$0] }) {
            case .storageLocation(let value)?: storage = value.rawValue; storageSource = .userEdited
            case .postponedStorage(let stated)?: storage = stated; storageSource = .userStated
            case nil: storage = lot.storageLocation; storageSource = .userEdited
            }
            var evidence = lot.evidence
            if storage != lot.storageLocation {
                evidence.removeAll { $0.fieldKey == .storageLocation }
                evidence.append(.init(fieldKey: .storageLocation, source: storageSource, confidence: 1, rawText: storage))
            }
            // The compartment question promised a horizon ("冷冻 · 60 天内吃完"); record it as a personal
            // plan estimate, never as a package date, and only when nothing better is known.
            var plannedUseBy = lot.plannedUseByDate
            if plannedUseBy == nil, lot.packageExpiryDate == nil, lot.estimatedExpiryDate == nil,
               let storageField, case .storageLocation(let choice)? = answers[storageField],
               let horizon = calendar.date(byAdding: .day, value: choice.planHorizonDays, to: referenceDate) {
                plannedUseBy = horizon
                evidence.removeAll { $0.fieldKey == .plannedUseByDate }
                evidence.append(.init(fieldKey: .plannedUseByDate, source: .systemEstimate, confidence: 0.6,
                                      rawText: "\(choice.rawValue)约 \(choice.planHorizonDays) 天"))
            }
            let revised = AddLotOperation(lotID: lot.lotID,
                productID: replacementProducts[lot.productID] ?? lot.productID,
                quantity: lot.quantity, unit: lot.unit, purchasedAt: lot.purchasedAt,
                packageExpiryDate: lot.packageExpiryDate, estimatedExpiryDate: lot.estimatedExpiryDate,
                plannedUseByDate: plannedUseBy, storageLocation: storage, evidence: evidence)
            return .init(operationID: planned.operationID, operation: .addLot(revised))
        }
        let unresolved = basePlan.unresolvedFields.filter { answers[$0] == nil }
        return .init(plan: .init(schemaVersion: basePlan.schemaVersion, planID: basePlan.planID,
                                 inputID: basePlan.inputID, operations: operations, unresolvedFields: unresolved),
                     localRevision: localRevision)
    }
}
