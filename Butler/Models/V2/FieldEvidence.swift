import Foundation
import SwiftData

enum EvidenceSubjectKind: String, Codable, Sendable {
    case product
    case lot
    case template
}

enum EvidenceSourceKind: String, Codable, Hashable, Sendable {
    case userStated
    case userEdited
    case ocr
    case orderImport
    case heuristicParser
    case modelInference
    case habitInference
    case systemEstimate
    case legacyUnknown
}

enum EvidenceVerificationState: String, Codable, Sendable {
    case unverified
    case userConfirmed
    case rejected
}

/// Field-level provenance for facts proposed by users, AI, OCR, imports, or rules.
@Model
final class FieldEvidence {
    @Attribute(.unique) var id: UUID
    var subjectKindRawValue: String
    var subjectID: UUID
    var fieldKey: String
    var sourceKindRawValue: String
    var verificationStateRawValue: String
    var confidence: Double
    var capturedAt: Date
    var rawText: String?
    var localArtifactID: String?
    var operationID: UUID?
    var confirmationReceiptID: UUID?
    var valueSchemaVersion: Int
    var valueJSON: Data
    var createdAt: Date

    init(
        id: UUID = UUID(),
        subjectKind: EvidenceSubjectKind,
        subjectID: UUID,
        fieldKey: String,
        sourceKind: EvidenceSourceKind,
        verificationState: EvidenceVerificationState = .unverified,
        confidence: Double,
        capturedAt: Date = Date(),
        rawText: String? = nil,
        localArtifactID: String? = nil,
        operationID: UUID? = nil,
        confirmationReceiptID: UUID? = nil,
        valueSchemaVersion: Int = 1,
        valueJSON: Data,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.subjectKindRawValue = subjectKind.rawValue
        self.subjectID = subjectID
        self.fieldKey = fieldKey
        self.sourceKindRawValue = sourceKind.rawValue
        self.verificationStateRawValue = verificationState.rawValue
        self.confidence = confidence
        self.capturedAt = capturedAt
        self.rawText = rawText
        self.localArtifactID = localArtifactID
        self.operationID = operationID
        self.confirmationReceiptID = confirmationReceiptID
        self.valueSchemaVersion = valueSchemaVersion
        self.valueJSON = valueJSON
        self.createdAt = createdAt
    }
}
