import Foundation
import SwiftData

struct InventoryExecutionResult: Sendable {
    let appliedOperationIDs: [UUID]
    let replayedOperationIDs: [UUID]
}

enum InventoryRepositoryError: Error {
    case requiresClarification([UnresolvedInventoryField])
    case requiresConfirmation([InventoryConfirmationRequirement])
    case rejected([String])
    case entityNotFound(kind: String, id: UUID)
    case entityAlreadyExists(kind: String, id: UUID)
    case staleRevision(kind: String, id: UUID, expected: Int, actual: Int)
    case invalidState(String)
    case missingEvidenceValue(field: InventoryFieldKey)
    case operationIDConflict(UUID)
}

/// Executes already-validated operation plans in one SwiftData save.
/// Use a dedicated ModelContext so rollback cannot discard unrelated UI edits.
@MainActor
final class InventoryRepository {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Nothing to clean up; keep deinit off the MainActor executor to avoid a Swift 6.2 runtime crash
    /// (swift_task_deinitOnExecutor frees an unallocated TaskLocal scope when released on the main thread).
    nonisolated deinit {}

    func execute(
        _ plan: InventoryOperationPlan,
        trustedConfirmations: [TrustedInventoryConfirmation] = [],
        actor: InventoryEventActor
    ) throws -> InventoryExecutionResult {
        let modelContext = ModelContext(modelContainer)
        modelContext.autosaveEnabled = false

        let initialDecision = InventoryPolicy.evaluate(plan)
        let generatedRequirements: [InventoryConfirmationRequirement]
        switch initialDecision {
        case .execute:
            generatedRequirements = []
        case .requiresClarification(let fields):
            throw InventoryRepositoryError.requiresClarification(fields)
        case .requiresConfirmation(let requirements):
            generatedRequirements = requirements
        case .reject(let violations):
            throw InventoryRepositoryError.rejected(violations.map(\.message))
        }

        switch InventoryPolicy.evaluate(plan, trustedConfirmations: trustedConfirmations) {
        case .execute:
            break
        case .requiresClarification(let fields):
            throw InventoryRepositoryError.requiresClarification(fields)
        case .requiresConfirmation(let requirements):
            throw InventoryRepositoryError.requiresConfirmation(requirements)
        case .reject(let violations):
            throw InventoryRepositoryError.rejected(violations.map(\.message))
        }

        var appliedOperationIDs: [UUID] = []
        var replayedOperationIDs: [UUID] = []
        var pendingProducts: [UUID: CatalogProduct] = [:]
        var pendingLots: [UUID: InventoryLot] = [:]
        var pendingTemplates: [UUID: PersonalProductTemplate] = [:]

        do {
            for plannedOperation in plan.operations {
                if let existingEvent = try event(
                    operationID: plannedOperation.operationID,
                    in: modelContext
                ) {
                    try validateReplay(existingEvent, matches: plannedOperation)
                    replayedOperationIDs.append(plannedOperation.operationID)
                    continue
                }

                let subject = try apply(
                    plannedOperation.operation,
                    pendingProducts: &pendingProducts,
                    pendingLots: &pendingLots,
                    pendingTemplates: &pendingTemplates,
                    in: modelContext
                )

                try appendEvidence(
                    for: plannedOperation,
                    planID: plan.planID,
                    subject: subject,
                    generatedRequirements: generatedRequirements,
                    trustedConfirmations: trustedConfirmations,
                    in: modelContext
                )
                try appendEvent(
                    for: plannedOperation,
                    subject: subject,
                    actor: actor,
                    in: modelContext
                )
                appliedOperationIDs.append(plannedOperation.operationID)
            }

            if !appliedOperationIDs.isEmpty {
                try modelContext.save()
                WidgetSnapshotPublisher.shared.refresh()
            }
        } catch {
            modelContext.rollback()
            throw error
        }

        return InventoryExecutionResult(
            appliedOperationIDs: appliedOperationIDs,
            replayedOperationIDs: replayedOperationIDs
        )
    }

    private func apply(
        _ operation: InventoryOperation,
        pendingProducts: inout [UUID: CatalogProduct],
        pendingLots: inout [UUID: InventoryLot],
        pendingTemplates: inout [UUID: PersonalProductTemplate],
        in modelContext: ModelContext
    ) throws -> (kind: EvidenceSubjectKind, id: UUID) {
        switch operation {
        case .createProduct(let payload):
            guard pendingProducts[payload.productID] == nil,
                  try product(id: payload.productID, in: modelContext) == nil else {
                throw InventoryRepositoryError.entityAlreadyExists(kind: "product", id: payload.productID)
            }
            let product = CatalogProduct(
                id: payload.productID,
                canonicalName: payload.canonicalName,
                brand: payload.brand,
                categoryRawValue: payload.categoryRawValue,
                defaultUnit: payload.defaultUnit
            )
            modelContext.insert(product)
            pendingProducts[product.id] = product
            return (.product, product.id)

        case .addLot(let payload):
            let targetProduct: CatalogProduct?
            if let pendingProduct = pendingProducts[payload.productID] {
                targetProduct = pendingProduct
            } else {
                targetProduct = try product(id: payload.productID, in: modelContext)
            }
            guard let targetProduct else {
                throw InventoryRepositoryError.entityNotFound(kind: "product", id: payload.productID)
            }
            guard !targetProduct.isArchived else {
                throw InventoryRepositoryError.invalidState("Archived products cannot receive new lots")
            }
            guard pendingLots[payload.lotID] == nil,
                  try lot(id: payload.lotID, in: modelContext) == nil else {
                throw InventoryRepositoryError.entityAlreadyExists(kind: "lot", id: payload.lotID)
            }
            let lot = InventoryLot(
                id: payload.lotID,
                productID: payload.productID,
                quantity: payload.quantity,
                unit: payload.unit,
                purchasedAt: payload.purchasedAt,
                packageExpiryDate: payload.packageExpiryDate,
                estimatedExpiryDate: payload.estimatedExpiryDate,
                plannedUseByDate: payload.plannedUseByDate,
                storageLocation: payload.storageLocation
            )
            modelContext.insert(lot)
            pendingLots[lot.id] = lot
            return (.lot, lot.id)

        case .adjustQuantity(let payload):
            let lot = try requireLot(id: payload.lotID, pendingLots: pendingLots, in: modelContext)
            try requireRevision(payload.expectedRevision, actual: lot.revision, kind: "lot", id: lot.id)
            guard lot.state == .active else {
                throw InventoryRepositoryError.invalidState("Only active lots can change quantity")
            }
            let addition = lot.quantity.addingReportingOverflow(payload.delta)
            guard !addition.overflow, addition.partialValue >= 0 else {
                throw InventoryRepositoryError.invalidState("Lot quantity cannot be negative")
            }
            let newQuantity = addition.partialValue
            lot.quantity = newQuantity
            if newQuantity == 0 {
                lot.state = .depleted
            }
            try touch(lot)
            return (.lot, lot.id)

        case .setLotDate(let payload):
            let lot = try requireLot(id: payload.lotID, pendingLots: pendingLots, in: modelContext)
            try requireRevision(payload.expectedRevision, actual: lot.revision, kind: "lot", id: lot.id)
            guard lot.state == .active else {
                throw InventoryRepositoryError.invalidState("Only active lots can change dates")
            }
            switch payload.kind {
            case .packageExpiry: lot.packageExpiryDate = payload.date
            case .estimatedExpiry: lot.estimatedExpiryDate = payload.date
            case .plannedUseBy: lot.plannedUseByDate = payload.date
            }
            try touch(lot)
            return (.lot, lot.id)

        case .setItemProfile(let payload):
            let lot = try requireLot(id: payload.lotID, pendingLots: pendingLots, in: modelContext)
            try requireRevision(payload.expectedRevision, actual: lot.revision, kind: "lot", id: lot.id)
            try payload.profile.validate()
            lot.profileData = try JSONEncoder().encode(payload.profile)
            try touch(lot)
            return (.lot, lot.id)

        case .moveLot(let payload):
            let lot = try requireLot(id: payload.lotID, pendingLots: pendingLots, in: modelContext)
            try requireRevision(payload.expectedRevision, actual: lot.revision, kind: "lot", id: lot.id)
            guard lot.state == .active else {
                throw InventoryRepositoryError.invalidState("Only active lots can move")
            }
            lot.storageLocation = payload.storageLocation
            try touch(lot)
            return (.lot, lot.id)

        case .closeLot(let payload):
            let lot = try requireLot(id: payload.lotID, pendingLots: pendingLots, in: modelContext)
            try requireRevision(payload.expectedRevision, actual: lot.revision, kind: "lot", id: lot.id)
            guard lot.state == .active else {
                throw InventoryRepositoryError.invalidState("Lot is already closed")
            }
            if let previous = payload.quantityBeforeClosing, previous != lot.quantity {
                throw InventoryRepositoryError.invalidState("Close snapshot does not match current quantity")
            }
            lot.state = payload.state
            if payload.state == .depleted {
                lot.quantity = 0
            }
            try touch(lot)
            return (.lot, lot.id)

        case .undoLot(let payload):
            let lot = try requireLot(id: payload.lotID, pendingLots: pendingLots, in: modelContext)
            try requireRevision(payload.expectedRevision, actual: lot.revision, kind: "lot", id: lot.id)
            guard let original = try event(operationID: payload.originalOperationID, in: modelContext),
                  original.subjectID == lot.id,
                  let quantity = original.undoQuantity(currentQuantity: lot.quantity, revision: lot.revision) else {
                throw InventoryRepositoryError.invalidState("Only the latest quantity or close operation can be undone")
            }
            lot.quantity = quantity
            lot.state = .active
            try touch(lot)
            return (.lot, lot.id)

        case .createTemplate(let payload):
            let productExists: Bool
            if pendingProducts[payload.productID] != nil {
                productExists = true
            } else {
                productExists = try product(id: payload.productID, in: modelContext) != nil
            }
            guard productExists else {
                throw InventoryRepositoryError.entityNotFound(kind: "product", id: payload.productID)
            }
            guard pendingTemplates[payload.templateID] == nil,
                  !pendingTemplates.values.contains(where: { $0.productID == payload.productID }),
                  try template(id: payload.templateID, in: modelContext) == nil,
                  try template(productID: payload.productID, in: modelContext) == nil else {
                throw InventoryRepositoryError.entityAlreadyExists(kind: "template", id: payload.templateID)
            }
            let template = PersonalProductTemplate(
                id: payload.templateID,
                productID: payload.productID,
                usualQuantity: payload.usualQuantity,
                defaultUnit: payload.defaultUnit,
                defaultStorageLocation: payload.defaultStorageLocation,
                usualConsumptionDays: payload.usualConsumptionDays,
                reminderLeadDays: payload.reminderLeadDays,
                repurchaseThreshold: payload.repurchaseThreshold
            )
            modelContext.insert(template)
            pendingTemplates[template.id] = template
            return (.template, template.id)

        case .updateTemplate(let payload):
            let template = try requireTemplate(
                id: payload.templateID,
                pendingTemplates: pendingTemplates,
                in: modelContext
            )
            try requireRevision(payload.expectedRevision, actual: template.revision, kind: "template", id: template.id)
            guard template.productID == payload.productID else {
                throw InventoryRepositoryError.invalidState("A template cannot change product identity")
            }
            template.usualQuantity = payload.usualQuantity
            template.defaultUnit = payload.defaultUnit
            template.defaultStorageLocation = payload.defaultStorageLocation
            template.usualConsumptionDays = payload.usualConsumptionDays
            template.reminderLeadDays = payload.reminderLeadDays
            template.repurchaseThreshold = payload.repurchaseThreshold
            let revision = template.revision.addingReportingOverflow(1)
            guard !revision.overflow else {
                throw InventoryRepositoryError.invalidState("Template revision overflow")
            }
            template.revision = revision.partialValue
            template.updatedAt = Date()
            return (.template, template.id)
        }
    }

    private func appendEvidence(
        for plannedOperation: PlannedInventoryOperation,
        planID: UUID,
        subject: (kind: EvidenceSubjectKind, id: UUID),
        generatedRequirements: [InventoryConfirmationRequirement],
        trustedConfirmations: [TrustedInventoryConfirmation],
        in modelContext: ModelContext
    ) throws {
        for proposal in plannedOperation.operation.evidence {
            let requirement = generatedRequirements.first {
                $0.planID == planID &&
                $0.operationID == plannedOperation.operationID &&
                $0.entityID == subject.id &&
                $0.fieldKey == proposal.fieldKey
            }
            let confirmation = requirement.flatMap { requirement in
                trustedConfirmations.first { $0.matches(requirement) }
            }
            let value: Data
            if case .undoLot(let undo) = plannedOperation.operation {
                let restored = try requireLot(id: undo.lotID, pendingLots: [:], in: modelContext)
                switch proposal.fieldKey {
                case .quantity: value = try encode(restored.quantity)
                case .state: value = try encode(restored.state.rawValue)
                default: throw InventoryRepositoryError.missingEvidenceValue(field: proposal.fieldKey)
                }
            } else {
                value = try valueJSON(for: proposal.fieldKey, in: plannedOperation.operation)
            }
            let evidence = FieldEvidence(
                subjectKind: subject.kind,
                subjectID: subject.id,
                fieldKey: proposal.fieldKey.rawValue,
                sourceKind: proposal.source,
                verificationState: confirmation == nil ? .unverified : .userConfirmed,
                confidence: proposal.confidence,
                rawText: proposal.rawText,
                operationID: plannedOperation.operationID,
                confirmationReceiptID: confirmation?.receiptID,
                valueJSON: value
            )
            modelContext.insert(evidence)
        }
    }

    private func appendEvent(
        for plannedOperation: PlannedInventoryOperation,
        subject: (kind: EvidenceSubjectKind, id: UUID),
        actor: InventoryEventActor,
        in modelContext: ModelContext
    ) throws {
        let event = InventoryEvent(
            operationID: plannedOperation.operationID,
            subjectKind: subject.kind,
            subjectID: subject.id,
            eventTypeRawValue: eventType(for: plannedOperation.operation),
            actor: actor,
            payloadJSON: try InventoryOperationCoding.makeJSONEncoder().encode(plannedOperation.operation)
        )
        modelContext.insert(event)
    }

    private func validateReplay(
        _ existingEvent: InventoryEvent,
        matches plannedOperation: PlannedInventoryOperation
    ) throws {
        let expectedSubject = subject(for: plannedOperation.operation)
        let expectedPayload = try InventoryOperationCoding.makeJSONEncoder()
            .encode(plannedOperation.operation)
        guard existingEvent.subjectKindRawValue == expectedSubject.kind.rawValue,
              existingEvent.subjectID == expectedSubject.id,
              existingEvent.eventTypeRawValue == eventType(for: plannedOperation.operation),
              existingEvent.payloadJSON == expectedPayload else {
            throw InventoryRepositoryError.operationIDConflict(plannedOperation.operationID)
        }
    }

    private func subject(for operation: InventoryOperation) -> (kind: EvidenceSubjectKind, id: UUID) {
        switch operation {
        case .createProduct(let value): return (.product, value.productID)
        case .addLot(let value): return (.lot, value.lotID)
        case .adjustQuantity(let value): return (.lot, value.lotID)
        case .setLotDate(let value): return (.lot, value.lotID)
        case .setItemProfile(let value): return (.lot, value.lotID)
        case .moveLot(let value): return (.lot, value.lotID)
        case .closeLot(let value): return (.lot, value.lotID)
        case .undoLot(let value): return (.lot, value.lotID)
        case .createTemplate(let value): return (.template, value.templateID)
        case .updateTemplate(let value): return (.template, value.templateID)
        }
    }

    private func eventType(for operation: InventoryOperation) -> String {
        switch operation {
        case .createProduct: return "productCreated"
        case .addLot: return "lotAdded"
        case .adjustQuantity: return "quantityAdjusted"
        case .setLotDate: return "lotDateSet"
        case .setItemProfile: return "itemProfileUpdated"
        case .moveLot: return "lotMoved"
        case .closeLot: return "lotClosed"
        case .undoLot: return "lotActionUndone"
        case .createTemplate: return "templateCreated"
        case .updateTemplate: return "templateUpdated"
        }
    }

    private func valueJSON(for fieldKey: InventoryFieldKey, in operation: InventoryOperation) throws -> Data {
        switch (operation, fieldKey) {
        case (.createProduct(let value), .canonicalName): return try encode(value.canonicalName)
        case (.createProduct(let value), .brand): return try encode(value.brand)
        case (.createProduct(let value), .category): return try encode(value.categoryRawValue)
        case (.createProduct(let value), .unit): return try encode(value.defaultUnit)
        case (.addLot(let value), .quantity): return try encode(value.quantity)
        case (.addLot(let value), .unit): return try encode(value.unit)
        case (.addLot(let value), .purchasedAt): return try encode(value.purchasedAt)
        case (.addLot(let value), .packageExpiryDate): return try encode(value.packageExpiryDate)
        case (.addLot(let value), .estimatedExpiryDate): return try encode(value.estimatedExpiryDate)
        case (.addLot(let value), .plannedUseByDate): return try encode(value.plannedUseByDate)
        case (.addLot(let value), .storageLocation): return try encode(value.storageLocation)
        case (.adjustQuantity(let value), .quantity): return try encode(value.delta)
        case (.setLotDate(let value), let field) where field == value.kind.fieldKey: return try encode(value.date)
        case (.setItemProfile(let value), .itemProfile): return try encode(value.profile)
        case (.moveLot(let value), .storageLocation): return try encode(value.storageLocation)
        case (.closeLot(let value), .state): return try encode(value.state.rawValue)
        case (.createTemplate(let value), .templateDefaults): return try encode(value)
        case (.updateTemplate(let value), .templateDefaults): return try encode(value)
        default: throw InventoryRepositoryError.missingEvidenceValue(field: fieldKey)
        }
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try InventoryOperationCoding.makeJSONEncoder().encode(value)
    }

    private func touch(_ lot: InventoryLot) throws {
        let revision = lot.revision.addingReportingOverflow(1)
        guard !revision.overflow else {
            throw InventoryRepositoryError.invalidState("Lot revision overflow")
        }
        lot.revision = revision.partialValue
        lot.updatedAt = Date()
    }

    private func requireRevision(_ expected: Int, actual: Int, kind: String, id: UUID) throws {
        guard expected == actual else {
            throw InventoryRepositoryError.staleRevision(
                kind: kind,
                id: id,
                expected: expected,
                actual: actual
            )
        }
    }

    private func requireLot(
        id: UUID,
        pendingLots: [UUID: InventoryLot],
        in modelContext: ModelContext
    ) throws -> InventoryLot {
        if let pending = pendingLots[id] { return pending }
        guard let existing = try lot(id: id, in: modelContext) else {
            throw InventoryRepositoryError.entityNotFound(kind: "lot", id: id)
        }
        return existing
    }

    private func requireTemplate(
        id: UUID,
        pendingTemplates: [UUID: PersonalProductTemplate],
        in modelContext: ModelContext
    ) throws -> PersonalProductTemplate {
        if let pending = pendingTemplates[id] { return pending }
        guard let existing = try template(id: id, in: modelContext) else {
            throw InventoryRepositoryError.entityNotFound(kind: "template", id: id)
        }
        return existing
    }

    private func product(id: UUID, in modelContext: ModelContext) throws -> CatalogProduct? {
        let targetID = id
        let descriptor = FetchDescriptor<CatalogProduct>(
            predicate: #Predicate { $0.id == targetID }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func lot(id: UUID, in modelContext: ModelContext) throws -> InventoryLot? {
        let targetID = id
        let descriptor = FetchDescriptor<InventoryLot>(
            predicate: #Predicate { $0.id == targetID }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func template(id: UUID, in modelContext: ModelContext) throws -> PersonalProductTemplate? {
        let targetID = id
        let descriptor = FetchDescriptor<PersonalProductTemplate>(
            predicate: #Predicate { $0.id == targetID }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func template(productID: UUID, in modelContext: ModelContext) throws -> PersonalProductTemplate? {
        let targetID = productID
        let descriptor = FetchDescriptor<PersonalProductTemplate>(
            predicate: #Predicate { $0.productID == targetID }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func event(operationID: UUID, in modelContext: ModelContext) throws -> InventoryEvent? {
        let targetID = operationID
        let descriptor = FetchDescriptor<InventoryEvent>(
            predicate: #Predicate { $0.operationID == targetID }
        )
        return try modelContext.fetch(descriptor).first
    }
}

private extension InventoryOperation {
    var evidence: [ProposedFieldEvidence] {
        switch self {
        case .createProduct(let value): return value.evidence
        case .addLot(let value): return value.evidence
        case .adjustQuantity(let value): return value.evidence
        case .setLotDate(let value): return value.evidence
        case .setItemProfile(let value): return value.evidence
        case .moveLot(let value): return value.evidence
        case .closeLot(let value): return value.evidence
        case .undoLot(let value): return value.evidence
        case .createTemplate(let value): return value.evidence
        case .updateTemplate(let value): return value.evidence
        }
    }
}
