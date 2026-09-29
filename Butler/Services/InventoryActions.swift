import Foundation
import SwiftData

enum InventoryActionError: LocalizedError {
    case policyRejected([String])
    case needsClarification

    var errorDescription: String? {
        switch self {
        case .policyRejected(let messages): return messages.joined(separator: "\n")
        case .needsClarification: return "这个操作还缺信息。"
        }
    }
}

/// Direct user commands from buttons. The tap that calls these is the trusted confirmation,
/// so every confirmation requirement the policy raises for this exact plan is receipted here.
@MainActor
struct InventoryActions {
    let repository: InventoryRepository
    private let container: ModelContainer

    init(modelContainer: ModelContainer) {
        repository = InventoryRepository(modelContainer: modelContainer)
        container = modelContainer
    }

    /// Switches a product between "track dates" and "only count how many are left" (water, tissues).
    /// A product preference, not an inventory fact, so it doesn't go through the lot ledger.
    func setQuantityOnly(_ quantityOnly: Bool, productID: UUID) throws {
        let context = ModelContext(container)
        guard let product = try context.fetch(FetchDescriptor<CatalogProduct>(
            predicate: #Predicate { $0.id == productID })).first else { return }
        let medicine = product.categoryRawValue == "medicine"
        product.categoryRawValue = quantityOnly ? LotFacts.quantityOnlyCategory : (medicine ? "medicine" : nil)
        product.revision += 1
        product.updatedAt = .now
        try context.save()
    }

    func close(_ lot: LotFacts, as state: InventoryLotState) throws {
        let evidence = [ProposedFieldEvidence(fieldKey: .state, source: .userStated, confidence: 1, rawText: state.rawValue)]
        try run(.closeLot(.init(lotID: lot.id, state: state, expectedRevision: lot.revision,
                               evidence: evidence, quantityBeforeClosing: lot.quantity)))
    }

    func adjustQuantity(_ lot: LotFacts, to quantity: Int) throws {
        guard quantity >= 0 else { throw InventoryActionError.policyRejected(["数量不能小于零。"] ) }
        let delta = quantity.subtractingReportingOverflow(lot.quantity)
        guard !delta.overflow else { throw InventoryActionError.policyRejected(["数量超出范围。"] ) }
        guard delta.partialValue != 0 else { return }
        try run(.adjustQuantity(.init(lotID: lot.id, delta: delta.partialValue,
            expectedRevision: lot.revision,
            evidence: [.init(fieldKey: .quantity, source: .userEdited, confidence: 1, rawText: "改为 \(quantity)")])))
    }

    func undo(_ event: InventoryEvent, for lot: LotFacts) throws {
        try run(.undoLot(.init(lotID: lot.id, originalOperationID: event.operationID,
            expectedRevision: lot.revision,
            evidence: [InventoryFieldKey.state, .quantity].map {
                .init(fieldKey: $0, source: .userEdited, confidence: 1, rawText: "撤销上一次处理")
            })))
    }

    func setPackageExpiry(_ date: Date, for lot: LotFacts, source: EvidenceSourceKind, rawText: String?) throws {
        let evidence = [ProposedFieldEvidence(fieldKey: .packageExpiryDate, source: source, confidence: 1, rawText: rawText)]
        try run(.setLotDate(.init(lotID: lot.id, kind: .packageExpiry, date: date,
                                  expectedRevision: lot.revision, evidence: evidence)))
    }

    func setPlannedUseBy(_ date: Date, for lot: LotFacts) throws {
        let evidence = [ProposedFieldEvidence(fieldKey: .plannedUseByDate, source: .userEdited, confidence: 1, rawText: nil)]
        try run(.setLotDate(.init(lotID: lot.id, kind: .plannedUseBy, date: date,
                                  expectedRevision: lot.revision, evidence: evidence)))
    }

    func setDate(_ date: Date?, kind: LotDateKind, for lot: LotFacts) throws {
        try run(.setLotDate(.init(lotID: lot.id, kind: kind, date: date, expectedRevision: lot.revision,
            evidence: [.init(fieldKey: kind.fieldKey, source: .userEdited, confidence: 1, rawText: nil)])))
    }

    func move(_ lot: LotFacts, to location: String) throws {
        let evidence = [ProposedFieldEvidence(fieldKey: .storageLocation, source: .userStated, confidence: 1, rawText: location)]
        try run(.moveLot(.init(lotID: lot.id, storageLocation: location,
                               expectedRevision: lot.revision, evidence: evidence)))
    }

    func setProfile(_ profile: ItemProfile, for lot: LotFacts) throws {
        try profile.validate()
        try run(.setItemProfile(.init(lotID: lot.id, profile: profile, expectedRevision: lot.revision,
            evidence: [.init(fieldKey: .itemProfile, source: .userEdited, confidence: 1, rawText: profile.searchText)])))
    }

    /// One new purchase, as the assistant understood it. Dates are only what the user said.
    struct NewItem: Equatable, Sendable, Codable {
        var name: String
        var quantity: Int
        var unit: String
        var storage: String?
        var packageExpiry: Date?
        var plannedUseBy: Date?
        /// Link to this existing product instead of creating a new one.
        var existingProductID: UUID?
        /// Only count how many are left; no expiry questions or reminders.
        var quantityOnly = false
        var profile: ItemProfile?
    }

    /// Adds several purchases in one transaction (all or nothing).
    @discardableResult
    func add(_ items: [NewItem], sourceText: String) throws -> [UUID] {
        guard !items.isEmpty else { return [] }
        var createdLotIDs: [UUID] = []
        var operations: [PlannedInventoryOperation] = []
        for item in items {
            let kind = ProductLexicon.lookup(item.name)?.kind ?? .unknown
            let quantityOnly = item.quantityOnly || kind == .household || item.profile?.category.durable == true
            let category = quantityOnly ? LotFacts.quantityOnlyCategory : kind.categoryRawValue
            let productID = item.existingProductID ?? UUID()
            if item.existingProductID == nil {
                var evidence = [ProposedFieldEvidence(fieldKey: .canonicalName, source: .modelInference, confidence: 0.9, rawText: sourceText)]
                if category != nil {
                    evidence.append(.init(fieldKey: .category, source: .modelInference, confidence: 0.8, rawText: item.name))
                }
                operations.append(.init(operationID: UUID(), operation: .createProduct(.init(
                    productID: productID, canonicalName: item.name, brand: nil,
                    categoryRawValue: category, defaultUnit: nil, evidence: evidence))))
            }
            var evidence: [ProposedFieldEvidence] = [
                .init(fieldKey: .quantity, source: .modelInference, confidence: 0.9, rawText: sourceText),
                .init(fieldKey: .unit, source: .modelInference, confidence: 0.9, rawText: item.unit),
            ]
            if item.storage != nil {
                evidence.append(.init(fieldKey: .storageLocation, source: .modelInference, confidence: 0.9, rawText: item.storage))
            }
            if item.packageExpiry != nil {
                // The user tapped confirm on a card that showed this exact date.
                evidence.append(.init(fieldKey: .packageExpiryDate, source: .userStated, confidence: 1, rawText: sourceText))
            }
            var planned = item.plannedUseBy
            if planned != nil {
                evidence.append(.init(fieldKey: .plannedUseByDate, source: .modelInference, confidence: 0.8, rawText: sourceText))
            } else if item.packageExpiry == nil, !quantityOnly, let horizon = kind.suggestedPlan,
                      let date = horizon.date(from: .now, calendar: .current) {
                planned = date
                evidence.append(.init(fieldKey: .plannedUseByDate, source: .systemEstimate, confidence: 0.7,
                                      rawText: "本地默认：\(horizon.phrase)内用完"))
            }
            let lotID = UUID()
            createdLotIDs.append(lotID)
            operations.append(.init(operationID: UUID(), operation: .addLot(.init(
                lotID: lotID, productID: productID, quantity: item.quantity, unit: item.unit,
                purchasedAt: nil, packageExpiryDate: item.packageExpiry, estimatedExpiryDate: nil,
                plannedUseByDate: planned, storageLocation: item.storage, evidence: evidence))))
            if let profile = item.profile {
                try profile.validate()
                operations.append(.init(operationID: UUID(), operation: .setItemProfile(.init(lotID: lotID,
                    profile: profile, expectedRevision: 0, evidence: [.init(fieldKey: .itemProfile, source: .userStated,
                    confidence: 1, rawText: sourceText)]))))
            }
        }
        try run(operations)
        return createdLotIDs
    }

    private func run(_ operation: InventoryOperation) throws {
        try run([.init(operationID: UUID(), operation: operation)])
    }

    private func run(_ operations: [PlannedInventoryOperation]) throws {
        let plan = InventoryOperationPlan(
            schemaVersion: InventoryOperationPlan.currentSchemaVersion,
            planID: UUID(), inputID: UUID(),
            operations: operations,
            unresolvedFields: []
        )
        let receipts: [TrustedInventoryConfirmation]
        switch InventoryPolicy.evaluate(plan) {
        case .execute: receipts = []
        case .requiresConfirmation(let requirements): receipts = requirements.map { InventoryConfirmationAuthority.issue(for: $0) }
        case .requiresClarification: throw InventoryActionError.needsClarification
        case .reject(let violations): throw InventoryActionError.policyRejected(violations.map(\.message))
        }
        _ = try repository.execute(plan, trustedConfirmations: receipts, actor: .user)
    }
}
