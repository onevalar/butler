import Foundation
import SwiftData

enum InventoryEventActor: String, Codable, Sendable {
    case user
    case assistant
    case system
    case legacyMigration
}

/// Append-only audit history. Current state remains materialized in Product and Lot.
@Model
final class InventoryEvent {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var operationID: UUID
    var subjectKindRawValue: String
    var subjectID: UUID
    var eventTypeRawValue: String
    var actorRawValue: String
    var occurredAt: Date
    var payloadSchemaVersion: Int
    var payloadJSON: Data
    var createdAt: Date

    init(
        id: UUID = UUID(),
        operationID: UUID,
        subjectKind: EvidenceSubjectKind,
        subjectID: UUID,
        eventTypeRawValue: String,
        actor: InventoryEventActor,
        occurredAt: Date = Date(),
        payloadSchemaVersion: Int = 1,
        payloadJSON: Data,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.operationID = operationID
        self.subjectKindRawValue = subjectKind.rawValue
        self.subjectID = subjectID
        self.eventTypeRawValue = eventTypeRawValue
        self.actorRawValue = actor.rawValue
        self.occurredAt = occurredAt
        self.payloadSchemaVersion = payloadSchemaVersion
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
    }
}

extension InventoryEvent {
    /// A revision check makes undo safe across navigation, relaunch and later edits.
    func undoQuantity(currentQuantity: Int, revision: Int) -> Int? {
        guard payloadSchemaVersion == 1,
              let operation = try? InventoryOperationCoding.makeJSONDecoder().decode(InventoryOperation.self, from: payloadJSON),
              revision > 0 else { return nil }
        switch operation {
        case .closeLot(let close) where close.expectedRevision == revision - 1:
            guard let quantity = close.quantityBeforeClosing, quantity > 0 else { return nil }
            return quantity
        case .adjustQuantity(let adjustment) where adjustment.expectedRevision == revision - 1:
            let previous = currentQuantity.subtractingReportingOverflow(adjustment.delta)
            return !previous.overflow && previous.partialValue > 0 ? previous.partialValue : nil
        default: return nil
        }
    }
}
