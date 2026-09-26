import Foundation

enum InventoryPolicyReason: String, Sendable {
    case packageExpiryRequiresConfirmation
    case destructiveOperationRequiresConfirmation
    case existingStateMutationRequiresConfirmation
}

struct InventoryConfirmationRequirement: Sendable {
    let planID: UUID
    let operationID: UUID
    let entityID: UUID
    let fieldKey: InventoryFieldKey
    let reason: InventoryPolicyReason
    let proposedValueIdentity: String
    let expectedRevision: Int?
}

/// A trusted receipt is issued outside the AI-decodable operation plan.
struct TrustedInventoryConfirmation: Sendable {
    let receiptID: UUID
    let planID: UUID
    let operationID: UUID
    let entityID: UUID
    let fieldKey: InventoryFieldKey
    let proposedValueIdentity: String
    let expectedRevision: Int?

    fileprivate init(
        receiptID: UUID,
        requirement: InventoryConfirmationRequirement
    ) {
        self.receiptID = receiptID
        self.planID = requirement.planID
        self.operationID = requirement.operationID
        self.entityID = requirement.entityID
        self.fieldKey = requirement.fieldKey
        self.proposedValueIdentity = requirement.proposedValueIdentity
        self.expectedRevision = requirement.expectedRevision
    }

    func matches(_ requirement: InventoryConfirmationRequirement) -> Bool {
        planID == requirement.planID &&
        operationID == requirement.operationID &&
        entityID == requirement.entityID &&
        fieldKey == requirement.fieldKey &&
        proposedValueIdentity == requirement.proposedValueIdentity &&
        expectedRevision == requirement.expectedRevision
    }
}

/// UI and direct-command boundaries call this only after an explicit user confirmation.
enum InventoryConfirmationAuthority {
    static func issue(
        for requirement: InventoryConfirmationRequirement,
        receiptID: UUID = UUID()
    ) -> TrustedInventoryConfirmation {
        TrustedInventoryConfirmation(receiptID: receiptID, requirement: requirement)
    }
}

struct InventoryPolicyViolation: Sendable {
    let operationID: UUID?
    let message: String
}

enum InventoryPolicyDecision: Sendable {
    case execute
    case requiresClarification(fields: [UnresolvedInventoryField])
    case requiresConfirmation(requirements: [InventoryConfirmationRequirement])
    case reject(violations: [InventoryPolicyViolation])
}

/// Validates AI-produced plans before a future repository is allowed to execute them.
/// This milestone deliberately does not connect policy decisions to persistence.
enum InventoryPolicy {
    static func evaluate(_ plan: InventoryOperationPlan) -> InventoryPolicyDecision {
        evaluate(plan, trustedConfirmations: [])
    }

    static func evaluate(
        _ plan: InventoryOperationPlan,
        trustedConfirmations: [TrustedInventoryConfirmation]
    ) -> InventoryPolicyDecision {
        var violations: [InventoryPolicyViolation] = []
        var requirements: [InventoryConfirmationRequirement] = []

        guard plan.schemaVersion == InventoryOperationPlan.currentSchemaVersion else {
            return .reject(violations: [
                InventoryPolicyViolation(
                    operationID: nil,
                    message: "Unsupported operation plan schema version: \(plan.schemaVersion)"
                )
            ])
        }

        let operationIDs = plan.operations.map(\.operationID)
        if Set(operationIDs).count != operationIDs.count {
            violations.append(InventoryPolicyViolation(operationID: nil, message: "Operation IDs must be unique"))
        }
        for unresolvedField in plan.unresolvedFields where !operationIDs.contains(unresolvedField.operationID) {
            violations.append(.init(
                operationID: unresolvedField.operationID,
                message: "Unresolved field must reference an operation in the plan"
            ))
        }

        for plannedOperation in plan.operations {
            validate(
                plannedOperation,
                planID: plan.planID,
                violations: &violations,
                requirements: &requirements
            )
        }

        if !violations.isEmpty {
            return .reject(violations: violations)
        }

        let requiredClarifications = plan.unresolvedFields.filter(\.isRequired)
        if !requiredClarifications.isEmpty {
            return .requiresClarification(fields: requiredClarifications)
        }

        let unconfirmedRequirements = requirements.filter { requirement in
            !trustedConfirmations.contains { $0.matches(requirement) }
        }
        if !unconfirmedRequirements.isEmpty {
            return .requiresConfirmation(requirements: unconfirmedRequirements)
        }

        return .execute
    }

    private static func validate(
        _ plannedOperation: PlannedInventoryOperation,
        planID: UUID,
        violations: inout [InventoryPolicyViolation],
        requirements: inout [InventoryConfirmationRequirement]
    ) {
        let evidence: [ProposedFieldEvidence]

        switch plannedOperation.operation {
        case .createProduct(let operation):
            evidence = operation.evidence
            if operation.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                violations.append(.init(operationID: plannedOperation.operationID, message: "Product name cannot be empty"))
            }
            requireEvidence(.canonicalName, in: evidence, operationID: plannedOperation.operationID, violations: &violations)
            if operation.brand != nil {
                requireEvidence(.brand, in: evidence, operationID: plannedOperation.operationID, violations: &violations)
            }
            if operation.categoryRawValue != nil {
                requireEvidence(.category, in: evidence, operationID: plannedOperation.operationID, violations: &violations)
            }
            if operation.defaultUnit != nil {
                requireEvidence(.unit, in: evidence, operationID: plannedOperation.operationID, violations: &violations)
            }

        case .addLot(let operation):
            evidence = operation.evidence
            if operation.quantity <= 0 {
                violations.append(.init(operationID: plannedOperation.operationID, message: "New lot quantity must be positive"))
            }
            if operation.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                violations.append(.init(operationID: plannedOperation.operationID, message: "Lot unit cannot be empty"))
            }
            requireEvidence(.quantity, in: evidence, operationID: plannedOperation.operationID, violations: &violations)
            requireEvidence(.unit, in: evidence, operationID: plannedOperation.operationID, violations: &violations)
            if operation.purchasedAt != nil {
                requireEvidence(.purchasedAt, in: evidence, operationID: plannedOperation.operationID, violations: &violations)
            }
            if operation.storageLocation != nil {
                requireEvidence(.storageLocation, in: evidence, operationID: plannedOperation.operationID, violations: &violations)
            }
            validateDateEvidence(
                operation.packageExpiryDate,
                fieldKey: .packageExpiryDate,
                evidence: evidence,
                operationID: plannedOperation.operationID,
                violations: &violations
            )
            validateDateEvidence(
                operation.estimatedExpiryDate,
                fieldKey: .estimatedExpiryDate,
                evidence: evidence,
                operationID: plannedOperation.operationID,
                violations: &violations
            )
            validateDateEvidence(
                operation.plannedUseByDate,
                fieldKey: .plannedUseByDate,
                evidence: evidence,
                operationID: plannedOperation.operationID,
                violations: &violations
            )
            if let packageExpiryDate = operation.packageExpiryDate {
                requirements.append(.init(
                    planID: planID,
                    operationID: plannedOperation.operationID,
                    entityID: operation.lotID,
                    fieldKey: .packageExpiryDate,
                    reason: .packageExpiryRequiresConfirmation,
                    proposedValueIdentity: dateIdentity(packageExpiryDate),
                    expectedRevision: nil
                ))
            }

        case .adjustQuantity(let operation):
            evidence = operation.evidence
            if operation.delta == 0 {
                violations.append(.init(operationID: plannedOperation.operationID, message: "Quantity adjustment cannot be zero"))
            }
            requireEvidence(.quantity, in: evidence, operationID: plannedOperation.operationID, violations: &violations)
            validateRevision(operation.expectedRevision, operationID: plannedOperation.operationID, violations: &violations)
            requirements.append(.init(
                planID: planID,
                operationID: plannedOperation.operationID,
                entityID: operation.lotID,
                fieldKey: .quantity,
                reason: .existingStateMutationRequiresConfirmation,
                proposedValueIdentity: "delta:\(operation.delta)",
                expectedRevision: operation.expectedRevision
            ))

        case .setLotDate(let operation):
            evidence = operation.evidence
            validateRevision(operation.expectedRevision, operationID: plannedOperation.operationID, violations: &violations)
            requireEvidence(operation.kind.fieldKey, in: evidence, operationID: plannedOperation.operationID, violations: &violations)
            validateDateEvidence(
                operation.date,
                fieldKey: operation.kind.fieldKey,
                evidence: evidence,
                operationID: plannedOperation.operationID,
                violations: &violations
            )
            requirements.append(.init(
                planID: planID,
                operationID: plannedOperation.operationID,
                entityID: operation.lotID,
                fieldKey: operation.kind.fieldKey,
                reason: operation.kind == .packageExpiry
                    ? .packageExpiryRequiresConfirmation
                    : .existingStateMutationRequiresConfirmation,
                proposedValueIdentity: operation.date.map(dateIdentity) ?? "clear",
                expectedRevision: operation.expectedRevision
            ))

        case .moveLot(let operation):
            evidence = operation.evidence
            if operation.storageLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                violations.append(.init(operationID: plannedOperation.operationID, message: "Storage location cannot be empty"))
            }
            requireEvidence(.storageLocation, in: evidence, operationID: plannedOperation.operationID, violations: &violations)
            validateRevision(operation.expectedRevision, operationID: plannedOperation.operationID, violations: &violations)
            requirements.append(.init(
                planID: planID,
                operationID: plannedOperation.operationID,
                entityID: operation.lotID,
                fieldKey: .storageLocation,
                reason: .existingStateMutationRequiresConfirmation,
                proposedValueIdentity: operation.storageLocation,
                expectedRevision: operation.expectedRevision
            ))

        case .closeLot(let operation):
            evidence = operation.evidence
            if operation.state == .active {
                violations.append(.init(operationID: plannedOperation.operationID, message: "Closing a lot requires a closed state"))
            }
            requireEvidence(.state, in: evidence, operationID: plannedOperation.operationID, violations: &violations)
            validateRevision(operation.expectedRevision, operationID: plannedOperation.operationID, violations: &violations)
            requirements.append(.init(
                planID: planID,
                operationID: plannedOperation.operationID,
                entityID: operation.lotID,
                fieldKey: .state,
                reason: .destructiveOperationRequiresConfirmation,
                proposedValueIdentity: operation.state.rawValue,
                expectedRevision: operation.expectedRevision
            ))

        case .undoLot(let operation):
            evidence = operation.evidence
            validateRevision(operation.expectedRevision, operationID: plannedOperation.operationID, violations: &violations)
            for field: InventoryFieldKey in [.state, .quantity] {
                requireEvidence(field, in: evidence, operationID: plannedOperation.operationID, violations: &violations)
                requirements.append(.init(
                    planID: planID, operationID: plannedOperation.operationID,
                    entityID: operation.lotID, fieldKey: field,
                    reason: .existingStateMutationRequiresConfirmation,
                    proposedValueIdentity: "undo:\(operation.originalOperationID.uuidString)",
                    expectedRevision: operation.expectedRevision
                ))
            }

        case .createTemplate(let operation):
            evidence = operation.evidence
            requireEvidence(.templateDefaults, in: evidence, operationID: plannedOperation.operationID, violations: &violations)
            requirements.append(.init(
                planID: planID,
                operationID: plannedOperation.operationID,
                entityID: operation.templateID,
                fieldKey: .templateDefaults,
                reason: .existingStateMutationRequiresConfirmation,
                proposedValueIdentity: valueIdentity(operation),
                expectedRevision: nil
            ))

        case .updateTemplate(let operation):
            evidence = operation.evidence
            requireEvidence(.templateDefaults, in: evidence, operationID: plannedOperation.operationID, violations: &violations)
            validateRevision(operation.expectedRevision, operationID: plannedOperation.operationID, violations: &violations)
            requirements.append(.init(
                planID: planID,
                operationID: plannedOperation.operationID,
                entityID: operation.templateID,
                fieldKey: .templateDefaults,
                reason: .existingStateMutationRequiresConfirmation,
                proposedValueIdentity: valueIdentity(operation),
                expectedRevision: operation.expectedRevision
            ))
        }

        for item in evidence {
            if !item.confidence.isFinite || !(0...1).contains(item.confidence) {
                violations.append(.init(operationID: plannedOperation.operationID, message: "Evidence confidence must be between 0 and 1"))
            }
        }
        let fieldKeys = evidence.map(\.fieldKey)
        if Set(fieldKeys).count != fieldKeys.count {
            violations.append(.init(
                operationID: plannedOperation.operationID,
                message: "An operation can provide only one evidence proposal per field"
            ))
        }
    }

    private static func validateDateEvidence(
        _ date: Date?,
        fieldKey: InventoryFieldKey,
        evidence: [ProposedFieldEvidence],
        operationID: UUID,
        violations: inout [InventoryPolicyViolation]
    ) {
        guard date != nil else { return }
        guard let matchingEvidence = evidence.first(where: { $0.fieldKey == fieldKey }) else {
            violations.append(.init(operationID: operationID, message: "\(fieldKey.rawValue) requires field evidence"))
            return
        }

        if fieldKey == .packageExpiryDate {
            let allowedSources: Set<EvidenceSourceKind> = [
                .userStated, .userEdited, .ocr, .orderImport, .heuristicParser,
            ]
            if !allowedSources.contains(matchingEvidence.source) {
                violations.append(.init(operationID: operationID, message: "Package expiry cannot be inferred or estimated"))
            }
        }
    }

    private static func requireEvidence(
        _ fieldKey: InventoryFieldKey,
        in evidence: [ProposedFieldEvidence],
        operationID: UUID,
        violations: inout [InventoryPolicyViolation]
    ) {
        if !evidence.contains(where: { $0.fieldKey == fieldKey }) {
            violations.append(.init(operationID: operationID, message: "\(fieldKey.rawValue) requires field evidence"))
        }
    }

    private static func dateIdentity(_ date: Date) -> String {
        String(date.timeIntervalSince1970)
    }

    private static func valueIdentity<Value: Encodable>(_ value: Value) -> String {
        guard let data = try? InventoryOperationCoding.makeJSONEncoder().encode(value) else {
            return "unencodable"
        }
        return data.base64EncodedString()
    }

    private static func validateRevision(
        _ revision: Int,
        operationID: UUID,
        violations: inout [InventoryPolicyViolation]
    ) {
        if revision < 0 {
            violations.append(.init(operationID: operationID, message: "Expected revision cannot be negative"))
        }
    }
}
