import Foundation

/// On-device planner: reads everyday Chinese with `ChineseInventoryParser`, then turns what was heard
/// into an operation plan. Everything the user didn't say is recorded as Butler's own estimate
/// (shown with a dashed underline), and package dates are only ever what the user stated.
struct LocalInventoryPlanProvider: InventoryPlanProvider {
    private let maximumItems = 20

    func plan(for input: InventoryPlanningInput) async throws -> InventoryOperationPlan {
        try makePlan(for: input)
    }

    /// Synchronous core: parsing does no waiting, so tests and live previews can call it directly.
    func makePlan(for input: InventoryPlanningInput) throws -> InventoryOperationPlan {
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw InventoryPlanningError.emptyInput }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = input.timeZone
        let heard = ChineseInventoryParser.parse(text, referenceDate: input.referenceDate, calendar: calendar)
        guard !heard.items.isEmpty else {
            throw heard.mentionsUsingUp ? InventoryPlanningError.usingUpNotSupported : .noInventoryItems
        }
        guard heard.items.count <= maximumItems else {
            throw InventoryPlanningError.tooManyClauses(maximum: maximumItems)
        }

        var operations: [PlannedInventoryOperation] = []
        var unresolved: [UnresolvedInventoryField] = []
        for item in heard.items {
            let productID = UUID(), lotID = UUID(), addOperationID = UUID()

            var productEvidence = [ProposedFieldEvidence(
                fieldKey: .canonicalName, source: .heuristicParser, confidence: 1, rawText: item.name)]
            let category = item.kind.categoryRawValue
            if category != nil {
                productEvidence.append(.init(fieldKey: .category, source: .heuristicParser, confidence: 0.8, rawText: item.name))
            }
            operations.append(.init(operationID: UUID(), operation: .createProduct(.init(
                productID: productID, canonicalName: item.name, brand: nil, categoryRawValue: category,
                defaultUnit: nil, evidence: productEvidence))))

            var evidence: [ProposedFieldEvidence] = [
                item.quantityRaw.map { .init(fieldKey: .quantity, source: .heuristicParser, confidence: 1, rawText: $0) }
                    ?? .init(fieldKey: .quantity, source: .systemEstimate, confidence: 0.5,
                             rawText: item.amountNote.map { "说的是\($0)，先记 1 份" } ?? "没说数量，先记 1"),
                .init(fieldKey: .unit, source: item.unitStated ? .heuristicParser : .systemEstimate,
                      confidence: item.unitStated ? 1 : 0.6, rawText: item.unit),
            ]

            var storage: String?
            if let hint = item.storage {
                if hint.location != StorageLocation.ambiguousFridge {
                    storage = hint.location
                    evidence.append(.init(fieldKey: .storageLocation, source: .heuristicParser, confidence: 1, rawText: hint.raw))
                } else if item.kind == .freezable {
                    // "放冰箱" for ice cream or meat: 冷冻 vs 冷藏 changes days into months, so ask.
                    unresolved.append(.init(operationID: addOperationID, entityID: lotID,
                                            fieldKey: .storageLocation, reason: "storage.coldAmbiguous", isRequired: true))
                } else {
                    storage = "冷藏"
                    evidence.append(.init(fieldKey: .storageLocation, source: .systemEstimate, confidence: 0.8,
                                          rawText: "说放\(hint.raw)，按冷藏记"))
                }
            }

            if let heardDate = item.packageExpiry {
                evidence.append(.init(fieldKey: .packageExpiryDate, source: .heuristicParser, confidence: 1, rawText: heardDate.raw))
            }
            if let heardDate = item.estimatedExpiry {
                evidence.append(.init(fieldKey: .estimatedExpiryDate, source: .heuristicParser, confidence: 0.9, rawText: heardDate.raw))
            }

            var plannedUseBy = item.plannedUseBy?.date
            if let heardDate = item.plannedUseBy {
                evidence.append(.init(fieldKey: .plannedUseByDate,
                                      source: heardDate.isGuess ? .systemEstimate : .heuristicParser,
                                      confidence: heardDate.isGuess ? 0.6 : 1, rawText: heardDate.raw))
            } else if item.packageExpiry == nil, item.estimatedExpiry == nil,
                      let horizon = item.kind.suggestedPlan,
                      let date = horizon.date(from: input.referenceDate, calendar: calendar) {
                plannedUseBy = date
                evidence.append(.init(fieldKey: .plannedUseByDate, source: .systemEstimate, confidence: 0.7,
                                      rawText: "本地默认：\(horizon.phrase)内用完"))
            }

            operations.append(.init(operationID: addOperationID, operation: .addLot(.init(
                lotID: lotID, productID: productID, quantity: item.quantity, unit: item.unit,
                purchasedAt: nil,
                packageExpiryDate: item.packageExpiry?.date,
                estimatedExpiryDate: item.estimatedExpiry?.date,
                plannedUseByDate: plannedUseBy,
                storageLocation: storage, evidence: evidence))))
        }
        return .init(schemaVersion: InventoryOperationPlan.currentSchemaVersion, planID: input.planID,
                     inputID: input.inputID, operations: operations, unresolvedFields: unresolved)
    }
}
