import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor
final class InventoryCorrectionTests: XCTestCase {
    func testDecodedUndoKeepsRevisionSchemaAndOverflowGuards() {
        let payload = Data(#"{"type":"closeLot","payload":{"lotID":"00000000-0000-0000-0000-000000000017","state":"depleted","expectedRevision":3,"quantityBeforeClosing":7,"evidence":[]}}"#.utf8)
        let event = InventoryEvent(operationID: UUID(), subjectKind: .lot, subjectID: UUID(),
                                   eventTypeRawValue: "closeLot", actor: .user, payloadJSON: payload)
        XCTAssertEqual(event.undoQuantity(currentQuantity: 0, revision: 4), 7)
        XCTAssertNil(event.undoQuantity(currentQuantity: 0, revision: 5))
        XCTAssertNil(event.undoQuantity(currentQuantity: 0, revision: 0))
        event.payloadSchemaVersion = 2
        XCTAssertNil(event.undoQuantity(currentQuantity: 0, revision: 4))
        event.payloadSchemaVersion = 1
        event.payloadJSON = Data(#"{"type":"adjustQuantity","payload":{"lotID":"00000000-0000-0000-0000-000000000017","delta":-1,"expectedRevision":3,"evidence":[]}}"#.utf8)
        XCTAssertEqual(event.undoQuantity(currentQuantity: 2, revision: 4), 3)
        XCTAssertNil(event.undoQuantity(currentQuantity: Int.max, revision: 4))
        XCTAssertNil(event.undoQuantity(currentQuantity: 2, revision: 5))
    }

    func testUndoRequiresBoundConfirmationAndRejectsAnotherLotsEvent() throws {
        let container = try ButlerStore.makePreviewContainer()
        let context = ModelContext(container)
        let product = CatalogProduct(canonicalName: "牛奶")
        let first = InventoryLot(productID: product.id, quantity: 3, unit: "瓶")
        let second = InventoryLot(productID: product.id, quantity: 8, unit: "瓶")
        context.insert(product); context.insert(first); context.insert(second); try context.save()
        let actions = InventoryActions(modelContainer: container)
        try actions.close(LotFacts(lot: first, product: product), as: .depleted)
        try actions.close(LotFacts(lot: second, product: product), as: .depleted)
        let event = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryEvent>()).first { $0.subjectID == first.id })
        func plan(for id: UUID) -> InventoryOperationPlan {
            .init(schemaVersion: 1, planID: UUID(), inputID: UUID(), operations: [
                .init(operationID: UUID(), operation: .undoLot(.init(lotID: id,
                    originalOperationID: event.operationID, expectedRevision: 1,
                    evidence: [InventoryFieldKey.state, .quantity].map {
                        .init(fieldKey: $0, source: .userEdited, confidence: 1, rawText: nil)
                    })))
            ], unresolvedFields: [])
        }
        let repository = InventoryRepository(modelContainer: container)
        let valid = plan(for: first.id)
        XCTAssertThrowsError(try repository.execute(valid, actor: .user))
        guard case .requiresConfirmation(let requirements) = InventoryPolicy.evaluate(valid) else {
            return XCTFail("Undo must require explicit confirmation")
        }
        let wrong = plan(for: second.id)
        XCTAssertThrowsError(try repository.execute(wrong,
            trustedConfirmations: requirements.map { InventoryConfirmationAuthority.issue(for: $0) }, actor: .user))
        guard case .requiresConfirmation(let wrongRequirements) = InventoryPolicy.evaluate(wrong) else {
            return XCTFail("Expected confirmation")
        }
        XCTAssertThrowsError(try repository.execute(wrong,
            trustedConfirmations: wrongRequirements.map { InventoryConfirmationAuthority.issue(for: $0) }, actor: .user))
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<InventoryEvent>()), 2)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).allSatisfy { $0.state == .depleted && $0.quantity == 0 })
    }

    func testPartialConsumptionUndoAndStaleUndoCannotOverwriteNewChanges() throws {
        let container = try ButlerStore.makePreviewContainer()
        let context = ModelContext(container)
        let product = CatalogProduct(canonicalName: "牛奶")
        let lot = InventoryLot(productID: product.id, quantity: 5, unit: "瓶")
        context.insert(product); context.insert(lot); try context.save()
        let actions = InventoryActions(modelContainer: container)
        func fresh() throws -> LotFacts {
            LotFacts(lot: try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).first), product: product)
        }
        try actions.adjustQuantity(fresh(), to: 3)
        XCTAssertEqual(try fresh().quantity, 3)
        let event = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryEvent>()).first)
        try actions.undo(event, for: fresh())
        XCTAssertEqual(try fresh().quantity, 5)
        XCTAssertEqual(try fresh().state, .active)
        XCTAssertThrowsError(try actions.undo(event, for: fresh()))
        try actions.adjustQuantity(fresh(), to: 2)
        let latest = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryEvent>()).first {
            $0.undoQuantity(currentQuantity: 2, revision: 3) != nil
        })
        try actions.move(fresh(), to: "冷藏")
        XCTAssertThrowsError(try actions.undo(latest, for: fresh()))
        XCTAssertEqual(try fresh().quantity, 2)
        XCTAssertEqual(try fresh().storageLocation, "冷藏")
    }

    func testCloseAndZeroQuantityCanBeUndoneWithHistoryAndEvidencePreserved() throws {
        for state in [InventoryLotState.depleted, .discarded, .gifted] {
            let container = try ButlerStore.makePreviewContainer()
            let context = ModelContext(container)
            let product = CatalogProduct(canonicalName: "鸡蛋")
            let lot = InventoryLot(productID: product.id, quantity: 7, unit: "个")
            context.insert(product); context.insert(lot); try context.save()
            let actions = InventoryActions(modelContainer: container)
            try actions.close(LotFacts(lot: lot, product: product), as: state)
            let closed = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).first)
            XCTAssertEqual(closed.state, state)
            let event = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryEvent>()).first)
            try actions.undo(event, for: LotFacts(lot: closed, product: product))
            let reopened = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).first)
            XCTAssertEqual(reopened.quantity, 7)
            XCTAssertEqual(reopened.state, .active)
            XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<InventoryEvent>()), 2)
            let evidence = try ModelContext(container).fetch(FetchDescriptor<FieldEvidence>())
            let quantity = try XCTUnwrap(evidence.first { $0.fieldKey == "quantity" })
            XCTAssertEqual(try JSONDecoder().decode(Int.self, from: quantity.valueJSON), 7)
            XCTAssertEqual(quantity.verificationStateRawValue, "userConfirmed")

            try actions.adjustQuantity(LotFacts(lot: reopened, product: product), to: 0)
            let zero = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).first)
            XCTAssertEqual(zero.state, .depleted)
            let consumption = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryEvent>()).first {
                $0.undoQuantity(currentQuantity: 0, revision: zero.revision) == 7
            })
            try actions.undo(consumption, for: LotFacts(lot: zero, product: product))
            XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).first?.quantity, 7)
        }
    }

    func testClearingPackageDateKeepsPlanAndRecordsConfirmedNull() throws {
        let container = try ButlerStore.makePreviewContainer()
        let context = ModelContext(container)
        let product = CatalogProduct(canonicalName: "牛奶")
        let planDate = Date(timeIntervalSince1970: 1_800_000_000)
        let lot = InventoryLot(productID: product.id, quantity: 2, unit: "瓶",
                               packageExpiryDate: planDate.addingTimeInterval(86400), plannedUseByDate: planDate)
        context.insert(product); context.insert(lot); try context.save()
        try InventoryActions(modelContainer: container).setDate(nil, kind: .packageExpiry,
                                                                 for: LotFacts(lot: lot, product: product))
        let saved = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).first)
        XCTAssertNil(saved.packageExpiryDate)
        XCTAssertEqual(saved.plannedUseByDate, planDate)
        let evidence = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<FieldEvidence>()).first)
        XCTAssertEqual(String(data: evidence.valueJSON, encoding: .utf8), "null")
        XCTAssertEqual(evidence.verificationStateRawValue, "userConfirmed")
    }

    func testSearchDoesNotTurnASpecificMedicineIntoAllMedicinesOrUnionFilters() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func facts(_ name: String, days: Int, planned: Bool = false) -> LotFacts {
            let product = CatalogProduct(canonicalName: name)
            let date = Calendar.current.date(byAdding: .day, value: days, to: now)!
            return LotFacts(lot: InventoryLot(productID: product.id, quantity: 1, unit: "盒",
                packageExpiryDate: planned ? nil : date, plannedUseByDate: planned ? date : nil), product: product, now: now)
        }
        XCTAssertTrue(facts("感冒药", days: 3).matchesSearch("感冒药还有吗？"))
        XCTAssertFalse(facts("布洛芬", days: 3).matchesSearch("感冒药还有吗？"))
        XCTAssertTrue(facts("感冒药", days: 7).matchesSearch("快过期的药"))
        XCTAssertFalse(facts("感冒药", days: 8).matchesSearch("快过期的药"))
        XCTAssertFalse(facts("牛奶", days: 2).matchesSearch("快过期的药"))
        XCTAssertFalse(facts("感冒药", days: 2, planned: true).matchesSearch("快过期的药"))
    }
}
