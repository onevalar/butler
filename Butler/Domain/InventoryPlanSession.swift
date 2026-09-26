import Foundation

/// Applies only allowlisted UI answers to a frozen provider result.
struct InventoryPlanSession: Sendable {
    let basePlan: InventoryOperationPlan
    private(set) var localRevision = 0
    private var answers: [UnresolvedInventoryField: InventoryClarificationAnswer] = [:]
    private var productChoices: [UUID: InventoryProductChoice] = [:]
    private var reviewedLots: [UUID: AddLotOperation] = [:]
    private var reviewedProducts: [UUID: PlannedInventoryOperation] = [:]

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

    @discardableResult
    mutating func edit(lotID: UUID, currentName: String, draft: InventoryReviewEdit) -> Bool {
        guard draft.isValid,
              let planned = materialize().plan.operations.first(where: {
                  if case .addLot(let lot) = $0.operation { return lot.lotID == lotID }; return false
              }), case .addLot(let lot) = planned.operation else { return false }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var productID = lot.productID
        if name != currentName {
            // Reuse the frozen proposed identity for a single-lot product. Shared products
            // need a new, stable identity so editing one row cannot rename another row.
            let original = basePlan.operations.first {
                if case .addLot(let value) = $0.operation { return value.lotID == lotID }; return false
            }
            guard let original, case .addLot(let baseLot) = original.operation else { return false }
            let siblings = basePlan.operations.filter {
                if case .addLot(let value) = $0.operation { return value.productID == baseLot.productID }; return false
            }
            guard let create = basePlan.operations.first(where: {
                if case .createProduct(let value) = $0.operation { return value.productID == baseLot.productID }; return false
            }) else { return false }
            let previous = reviewedProducts[lotID]
            let createID = previous?.operationID ?? (siblings.count == 1 ? create.operationID : UUID())
            if let previous, case .createProduct(let value) = previous.operation {
                productID = value.productID
            } else { productID = siblings.count == 1 ? baseLot.productID : UUID() }
            reviewedProducts[lotID] = .init(operationID: createID, operation: .createProduct(.init(
                productID: productID, canonicalName: name, brand: nil, categoryRawValue: nil,
                defaultUnit: nil, evidence: [.init(fieldKey: .canonicalName, source: .userEdited,
                                                 confidence: 1, rawText: name)])))
        }
        var evidence = lot.evidence
        func changed<T: Equatable>(_ key: InventoryFieldKey, _ old: T, _ new: T) {
            guard old != new else { return }
            evidence.removeAll { $0.fieldKey == key }
            evidence.append(.init(fieldKey: key, source: .userEdited, confidence: 1, rawText: nil))
        }
        let quantity = Int(draft.quantity)!
        let unit = draft.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let storageText = draft.storage.trimmingCharacters(in: .whitespacesAndNewlines)
        let storage: String? = storageText.isEmpty ? nil : storageText
        // Renaming must not carry a different product's guessed shelf life into the new item.
        func reviewedDate(_ key: InventoryFieldKey, old: Date?, proposed: Date?) -> Date? {
            if name != currentName, old == proposed,
               lot.evidence.first(where: { $0.fieldKey == key })?.source.isInference == true { return nil }
            return proposed
        }
        let estimated = reviewedDate(.estimatedExpiryDate, old: lot.estimatedExpiryDate, proposed: draft.estimatedExpiry)
        let plannedDate = reviewedDate(.plannedUseByDate, old: lot.plannedUseByDate, proposed: draft.plannedUseBy)
        changed(.quantity, lot.quantity, quantity)
        changed(.unit, lot.unit, unit)
        changed(.storageLocation, lot.storageLocation, storage)
        changed(.purchasedAt, lot.purchasedAt, draft.purchasedAt)
        changed(.packageExpiryDate, lot.packageExpiryDate, draft.packageExpiry)
        changed(.estimatedExpiryDate, lot.estimatedExpiryDate, estimated)
        changed(.plannedUseByDate, lot.plannedUseByDate, plannedDate)
        reviewedLots[lotID] = .init(lotID: lotID, productID: productID, quantity: quantity, unit: unit,
            purchasedAt: draft.purchasedAt, packageExpiryDate: draft.packageExpiry,
            estimatedExpiryDate: estimated, plannedUseByDate: plannedDate,
            storageLocation: storage, evidence: evidence)
        localRevision += 1
        return true
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
        var operations = basePlan.operations.compactMap { planned -> PlannedInventoryOperation? in
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
        operations = operations.map { planned in
            guard case .addLot(let lot) = planned.operation, let edited = reviewedLots[lot.lotID] else { return planned }
            let revised = AddLotOperation(lotID: edited.lotID,
                productID: reviewedProducts[lot.lotID] == nil ? lot.productID : edited.productID,
                quantity: edited.quantity, unit: edited.unit, purchasedAt: edited.purchasedAt,
                packageExpiryDate: edited.packageExpiryDate, estimatedExpiryDate: edited.estimatedExpiryDate,
                plannedUseByDate: edited.plannedUseByDate, storageLocation: edited.storageLocation,
                evidence: edited.evidence)
            return .init(operationID: planned.operationID, operation: .addLot(revised))
        }
        for lotID in reviewedProducts.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let product = reviewedProducts[lotID] else { continue }
            operations.removeAll { $0.operationID == product.operationID }
            operations.insert(product, at: 0)
        }
        let unresolved = basePlan.unresolvedFields.filter { answers[$0] == nil }
        return .init(plan: .init(schemaVersion: basePlan.schemaVersion, planID: basePlan.planID,
                                 inputID: basePlan.inputID, operations: operations, unresolvedFields: unresolved),
                     localRevision: localRevision)
    }
}
