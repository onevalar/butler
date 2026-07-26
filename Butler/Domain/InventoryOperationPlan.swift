import Foundation

struct InventoryOperationPlan: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let planID: UUID
    let inputID: UUID
    let operations: [PlannedInventoryOperation]
    let unresolvedFields: [UnresolvedInventoryField]
}

struct PlannedInventoryOperation: Codable, Sendable {
    let operationID: UUID
    let operation: InventoryOperation
}

struct UnresolvedInventoryField: Codable, Hashable, Sendable {
    let operationID: UUID
    let entityID: UUID
    let fieldKey: InventoryFieldKey
    let reason: String
    let isRequired: Bool
}

struct ProposedFieldEvidence: Codable, Sendable {
    let fieldKey: InventoryFieldKey
    let source: EvidenceSourceKind
    let confidence: Double
    let rawText: String?
}

enum InventoryFieldKey: String, Codable, Hashable, Sendable {
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
}

enum LotDateKind: String, Codable, Sendable {
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

struct CreateProductOperation: Codable, Sendable {
    let productID: UUID
    let canonicalName: String
    let brand: String?
    let categoryRawValue: String?
    let defaultUnit: String?
    let evidence: [ProposedFieldEvidence]
}

struct AddLotOperation: Codable, Sendable {
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

struct AdjustQuantityOperation: Codable, Sendable {
    let lotID: UUID
    let delta: Int
    let expectedRevision: Int
    let evidence: [ProposedFieldEvidence]
}

struct SetLotDateOperation: Codable, Sendable {
    let lotID: UUID
    let kind: LotDateKind
    let date: Date
    let expectedRevision: Int
    let evidence: [ProposedFieldEvidence]
}

struct MoveLotOperation: Codable, Sendable {
    let lotID: UUID
    let storageLocation: String
    let expectedRevision: Int
    let evidence: [ProposedFieldEvidence]
}

struct CloseLotOperation: Codable, Sendable {
    let lotID: UUID
    let state: InventoryLotState
    let expectedRevision: Int
    let evidence: [ProposedFieldEvidence]
}

struct CreateTemplateOperation: Codable, Sendable {
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

struct UpdateTemplateOperation: Codable, Sendable {
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
enum InventoryOperation: Codable, Sendable {
    case createProduct(CreateProductOperation)
    case addLot(AddLotOperation)
    case adjustQuantity(AdjustQuantityOperation)
    case setLotDate(SetLotDateOperation)
    case moveLot(MoveLotOperation)
    case closeLot(CloseLotOperation)
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
        case closeLot
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
        case .moveLot:
            self = .moveLot(try container.decode(MoveLotOperation.self, forKey: .payload))
        case .closeLot:
            self = .closeLot(try container.decode(CloseLotOperation.self, forKey: .payload))
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
        case .moveLot(let payload):
            try container.encode(OperationType.moveLot, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .closeLot(let payload):
            try container.encode(OperationType.closeLot, forKey: .type)
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

enum InventoryOperationCoding {
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
