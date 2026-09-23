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

    init(modelContainer: ModelContainer) {
        repository = InventoryRepository(modelContainer: modelContainer)
    }

    func close(_ lot: LotFacts, as state: InventoryLotState) throws {
        let evidence = [ProposedFieldEvidence(fieldKey: .state, source: .userStated, confidence: 1, rawText: state.rawValue)]
        try run(.closeLot(.init(lotID: lot.id, state: state, expectedRevision: lot.revision, evidence: evidence)))
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

    func move(_ lot: LotFacts, to location: String) throws {
        let evidence = [ProposedFieldEvidence(fieldKey: .storageLocation, source: .userStated, confidence: 1, rawText: location)]
        try run(.moveLot(.init(lotID: lot.id, storageLocation: location,
                               expectedRevision: lot.revision, evidence: evidence)))
    }

    private func run(_ operation: InventoryOperation) throws {
        let plan = InventoryOperationPlan(
            schemaVersion: InventoryOperationPlan.currentSchemaVersion,
            planID: UUID(), inputID: UUID(),
            operations: [.init(operationID: UUID(), operation: operation)],
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
