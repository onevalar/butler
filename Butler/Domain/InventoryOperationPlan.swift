import Foundation

// Transport values contain no SwiftData objects or shared mutable state. Their
// Codable witnesses must remain usable outside the app's default MainActor.
nonisolated struct InventoryOperationPlan: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let planID: UUID
    let inputID: UUID
    let operations: [PlannedInventoryOperation]
    let unresolvedFields: [UnresolvedInventoryField]
}

nonisolated struct PlannedInventoryOperation: Codable, Sendable {
    let operationID: UUID
    let operation: InventoryOperation
}

nonisolated struct UnresolvedInventoryField: Codable, Hashable, Sendable {
    let operationID: UUID
    let entityID: UUID
    let fieldKey: InventoryFieldKey
    let reason: String
    let isRequired: Bool
}

nonisolated struct ProposedFieldEvidence: Codable, Sendable {
    let fieldKey: InventoryFieldKey
    let source: EvidenceSourceKind
    let confidence: Double
    let rawText: String?
}

nonisolated enum InventoryFieldKey: String, Codable, Hashable, Sendable {
    case canonicalName
    case brand
    case category
    case quantity
    case unit
    case purchasedAt
    case packageExpiryDate
    case estimatedExpiryDate
    case plannedUseByDate
    case storageLocation
    case state
    case templateDefaults
    case itemProfile
}

nonisolated enum LotDateKind: String, Codable, Sendable {
    case packageExpiry = "packageExpiryDate"
    case estimatedExpiry = "estimatedExpiryDate"
    case plannedUseBy = "plannedUseByDate"

    var fieldKey: InventoryFieldKey {
        switch self {
        case .packageExpiry: return .packageExpiryDate
        case .estimatedExpiry: return .estimatedExpiryDate
        case .plannedUseBy: return .plannedUseByDate
        }
    }
}

nonisolated struct CreateProductOperation: Codable, Sendable {
    let productID: UUID
    let canonicalName: String
    let brand: String?
    let categoryRawValue: String?
    let defaultUnit: String?
    let evidence: [ProposedFieldEvidence]
}

nonisolated struct AddLotOperation: Codable, Sendable {
    let lotID: UUID
    let productID: UUID
    let quantity: Int
    let unit: String
    let purchasedAt: Date?
    let packageExpiryDate: Date?
    let estimatedExpiryDate: Date?
    let plannedUseByDate: Date?
    let storageLocation: String?
    let evidence: [ProposedFieldEvidence]
}

nonisolated struct SetItemProfileOperation: Codable, Sendable {
    let lotID: UUID
    let profile: ItemProfile
    let expectedRevision: Int
    let evidence: [ProposedFieldEvidence]
}

nonisolated struct AdjustQuantityOperation: Codable, Sendable {
    let lotID: UUID
    let delta: Int
    let expectedRevision: Int
    let evidence: [ProposedFieldEvidence]
}

nonisolated struct SetLotDateOperation: Codable, Sendable {
    let lotID: UUID
    let kind: LotDateKind
    let date: Date?
    let expectedRevision: Int
    let evidence: [ProposedFieldEvidence]
}

nonisolated struct MoveLotOperation: Codable, Sendable {
    let lotID: UUID
    let storageLocation: String
    let expectedRevision: Int
    let evidence: [ProposedFieldEvidence]
}

nonisolated struct CloseLotOperation: Codable, Sendable {
    let lotID: UUID
    let state: InventoryLotState
    let expectedRevision: Int
    let evidence: [ProposedFieldEvidence]
    var quantityBeforeClosing: Int? = nil
}

/// Undo only a recorded quantity/close operation, never an arbitrary state overwrite.
nonisolated struct UndoLotOperation: Codable, Sendable {
    let lotID: UUID
    let originalOperationID: UUID
    let expectedRevision: Int
    let evidence: [ProposedFieldEvidence]
}

nonisolated struct CreateTemplateOperation: Codable, Sendable {
    let templateID: UUID
    let productID: UUID
    let usualQuantity: Int?
    let defaultUnit: String?
    let defaultStorageLocation: String?
    let usualConsumptionDays: Int?
    let reminderLeadDays: Int?
    let repurchaseThreshold: Int?
    let evidence: [ProposedFieldEvidence]
}

nonisolated struct UpdateTemplateOperation: Codable, Sendable {
    let templateID: UUID
    let productID: UUID
    let usualQuantity: Int?
    let defaultUnit: String?
    let defaultStorageLocation: String?
    let usualConsumptionDays: Int?
    let reminderLeadDays: Int?
    let repurchaseThreshold: Int?
    let expectedRevision: Int
    let evidence: [ProposedFieldEvidence]
}

/// A versioned, allowlisted command union. It intentionally exposes no arbitrary field mutation.
nonisolated enum InventoryOperation: Codable, Sendable {
    case createProduct(CreateProductOperation)
    case addLot(AddLotOperation)
    case adjustQuantity(AdjustQuantityOperation)
    case setLotDate(SetLotDateOperation)
    case moveLot(MoveLotOperation)
    case setItemProfile(SetItemProfileOperation)
    case closeLot(CloseLotOperation)
    case undoLot(UndoLotOperation)
    case createTemplate(CreateTemplateOperation)
    case updateTemplate(UpdateTemplateOperation)

    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    private enum OperationType: String, Codable {
        case createProduct
        case addLot
        case adjustQuantity
        case setLotDate
        case moveLot
        case setItemProfile
        case closeLot
        case undoLot
        case createTemplate
        case updateTemplate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(OperationType.self, forKey: .type) {
        case .createProduct:
            self = .createProduct(try container.decode(CreateProductOperation.self, forKey: .payload))
        case .addLot:
            self = .addLot(try container.decode(AddLotOperation.self, forKey: .payload))
        case .adjustQuantity:
            self = .adjustQuantity(try container.decode(AdjustQuantityOperation.self, forKey: .payload))
        case .setLotDate:
            self = .setLotDate(try container.decode(SetLotDateOperation.self, forKey: .payload))
        case .setItemProfile:
            self = .setItemProfile(try container.decode(SetItemProfileOperation.self, forKey: .payload))
        case .moveLot:
            self = .moveLot(try container.decode(MoveLotOperation.self, forKey: .payload))
        case .closeLot:
            self = .closeLot(try container.decode(CloseLotOperation.self, forKey: .payload))
        case .undoLot:
            self = .undoLot(try container.decode(UndoLotOperation.self, forKey: .payload))
        case .createTemplate:
            self = .createTemplate(try container.decode(CreateTemplateOperation.self, forKey: .payload))
        case .updateTemplate:
            self = .updateTemplate(try container.decode(UpdateTemplateOperation.self, forKey: .payload))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .createProduct(let payload):
            try container.encode(OperationType.createProduct, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .addLot(let payload):
            try container.encode(OperationType.addLot, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .adjustQuantity(let payload):
            try container.encode(OperationType.adjustQuantity, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .setLotDate(let payload):
            try container.encode(OperationType.setLotDate, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .setItemProfile(let payload):
            try container.encode(OperationType.setItemProfile, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .moveLot(let payload):
            try container.encode(OperationType.moveLot, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .closeLot(let payload):
            try container.encode(OperationType.closeLot, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .undoLot(let payload):
            try container.encode(OperationType.undoLot, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .createTemplate(let payload):
            try container.encode(OperationType.createTemplate, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .updateTemplate(let payload):
            try container.encode(OperationType.updateTemplate, forKey: .type)
            try container.encode(payload, forKey: .payload)
        }
    }
}

nonisolated enum InventoryOperationCoding {
    static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
