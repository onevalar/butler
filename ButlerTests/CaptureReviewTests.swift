import Foundation
import XCTest
@testable import Butler

final class CaptureReviewTests: XCTestCase {
    func testEditPreservesFrozenIDsAndUntouchedEvidence() throws {
        let fixture = Fixture()
        var session = InventoryPlanSession(basePlan: fixture.plan)
        var edit = fixture.draft
        edit.quantity = "3"
        edit.unit = "盒"
        edit.storage = "冷藏"
        XCTAssertTrue(session.edit(lotID: fixture.lotID, currentName: "牛奶", draft: edit))
        let revised = session.materialize().plan
        XCTAssertEqual(revised.planID, fixture.plan.planID)
        XCTAssertEqual(revised.inputID, fixture.plan.inputID)
        XCTAssertEqual(revised.operations.map(\.operationID), fixture.plan.operations.map(\.operationID))
        let lot = try XCTUnwrap(lots(revised).first)
        XCTAssertEqual(lot.lotID, fixture.lotID)
        XCTAssertEqual(lot.productID, fixture.productID)
        XCTAssertEqual(lot.quantity, 3)
        for key in [InventoryFieldKey.quantity, .unit, .storageLocation] {
            XCTAssertEqual(lot.evidence.first { $0.fieldKey == key }?.source, .userEdited)
        }
        XCTAssertEqual(lot.evidence.first { $0.fieldKey == .plannedUseByDate }?.source, .systemEstimate)
        XCTAssertEqual(try encoded(revised), try encoded(session.materialize().plan))
    }

    func testInvalidQuantityOrRequiredTextDoesNotRevisePlan() throws {
        let fixture = Fixture()
        var session = InventoryPlanSession(basePlan: fixture.plan)
        let before = try encoded(session.materialize().plan)
        for quantity in ["", "0", "-1", "1.5", "1e2", " 2", String(repeating: "9", count: 100)] {
            var draft = fixture.draft
            draft.quantity = quantity
            XCTAssertFalse(session.edit(lotID: fixture.lotID, currentName: "牛奶", draft: draft))
        }
        var draft = fixture.draft
        draft.name = " \n"
        XCTAssertFalse(session.edit(lotID: fixture.lotID, currentName: "牛奶", draft: draft))
        draft = fixture.draft
        draft.unit = " "
        XCTAssertFalse(session.edit(lotID: fixture.lotID, currentName: "牛奶", draft: draft))
        XCTAssertEqual(session.localRevision, 0)
        XCTAssertEqual(try encoded(session.materialize().plan), before)
    }

    func testRenameDetachesExistingProductUsingFrozenProposedIdentity() throws {
        let fixture = Fixture()
        let existingID = UUID()
        var session = InventoryPlanSession(basePlan: fixture.plan)
        session.choose(forCreateOperation: fixture.createID, .existing(productID: existingID))
        var draft = fixture.draft
        draft.name = "燕麦奶"
        XCTAssertTrue(session.edit(lotID: fixture.lotID, currentName: "牛奶", draft: draft))
        let revised = session.materialize().plan
        XCTAssertEqual(Set(revised.operations.map(\.operationID)), Set(fixture.plan.operations.map(\.operationID)))
        let lot = try XCTUnwrap(lots(revised).first)
        XCTAssertEqual(lot.productID, fixture.productID)
        XCTAssertNotEqual(lot.productID, existingID)
        let product = try XCTUnwrap(products(revised).first)
        XCTAssertEqual(product.canonicalName, "燕麦奶")
        XCTAssertEqual(product.evidence.first?.source, .userEdited)
        XCTAssertEqual(products(fixture.plan).first?.canonicalName, "牛奶")
        XCTAssertNil(lot.plannedUseByDate, "A renamed product must not inherit the old product's guessed horizon")
    }

    func testSharedProductRenameAffectsOnlyOneLotAndNewIDsRemainStable() throws {
        let fixture = Fixture(shared: true)
        var session = InventoryPlanSession(basePlan: fixture.plan)
        var draft = fixture.draft
        draft.name = "燕麦奶"
        XCTAssertTrue(session.edit(lotID: fixture.lotID, currentName: "牛奶", draft: draft))
        let first = session.materialize().plan
        let firstLot = try XCTUnwrap(lots(first).first { $0.lotID == fixture.lotID })
        XCTAssertNotEqual(firstLot.productID, fixture.productID)
        XCTAssertEqual(lots(first).last?.productID, fixture.productID)
        draft.name = "无糖燕麦奶"
        XCTAssertTrue(session.edit(lotID: fixture.lotID, currentName: "燕麦奶", draft: draft))
        let second = session.materialize().plan
        XCTAssertEqual(first.operations.map(\.operationID), second.operations.map(\.operationID))
        XCTAssertEqual(lots(second).first?.productID, firstLot.productID)
        XCTAssertEqual(products(second).first { $0.productID == fixture.productID }?.canonicalName, "牛奶")
    }

    func testDateEditsInvalidateReceiptsAndDatesCanBeCleared() throws {
        let fixture = Fixture()
        var session = InventoryPlanSession(basePlan: fixture.plan)
        var draft = fixture.draft
        draft.packageExpiry = Date(timeIntervalSince1970: 1_900_000_000)
        XCTAssertTrue(session.edit(lotID: fixture.lotID, currentName: "牛奶", draft: draft))
        guard case .requiresConfirmation(let old) = InventoryPolicy.evaluate(session.materialize().plan) else {
            return XCTFail("Expected package expiry confirmation")
        }
        let receipts = old.map { InventoryConfirmationAuthority.issue(for: $0) }
        draft.packageExpiry = draft.packageExpiry?.addingTimeInterval(86400)
        XCTAssertTrue(session.edit(lotID: fixture.lotID, currentName: "牛奶", draft: draft))
        guard case .requiresConfirmation(let updated) = InventoryPolicy.evaluate(session.materialize().plan,
                                                                                trustedConfirmations: receipts) else {
            return XCTFail("Old receipt must not confirm a changed date")
        }
        XCTAssertNotEqual(old.first?.proposedValueIdentity, updated.first?.proposedValueIdentity)
        draft.packageExpiry = nil
        draft.plannedUseBy = nil
        XCTAssertTrue(session.edit(lotID: fixture.lotID, currentName: "牛奶", draft: draft))
        let plan = session.materialize().plan
        let lot = try XCTUnwrap(lots(plan).first)
        XCTAssertNil(lot.packageExpiryDate)
        XCTAssertNil(lot.plannedUseByDate)
        XCTAssertEqual(lot.evidence.first { $0.fieldKey == .plannedUseByDate }?.source, .userEdited)
        guard case .execute = InventoryPolicy.evaluate(plan) else { return XCTFail("Cleared date requires no receipt") }
    }

    func testKeepSeparateStillWorksAfterQuantityEdit() throws {
        let fixture = Fixture()
        var session = InventoryPlanSession(basePlan: fixture.plan)
        session.choose(forCreateOperation: fixture.createID, .existing(productID: UUID()))
        var draft = fixture.draft
        draft.quantity = "4"
        XCTAssertTrue(session.edit(lotID: fixture.lotID, currentName: "牛奶", draft: draft))
        session.choose(forCreateOperation: fixture.createID, .createSeparate)
        let lot = try XCTUnwrap(lots(session.materialize().plan).first)
        XCTAssertEqual(lot.productID, fixture.productID)
        XCTAssertEqual(lot.quantity, 4)
    }

    private func lots(_ plan: InventoryOperationPlan) -> [AddLotOperation] {
        plan.operations.compactMap { if case .addLot(let lot) = $0.operation { return lot }; return nil }
    }

    private func products(_ plan: InventoryOperationPlan) -> [CreateProductOperation] {
        plan.operations.compactMap { if case .createProduct(let value) = $0.operation { return value }; return nil }
    }

    private func encoded(_ plan: InventoryOperationPlan) throws -> Data {
        try InventoryOperationCoding.makeJSONEncoder().encode(plan)
    }

    private struct Fixture {
        let productID = UUID()
        let lotID = UUID()
        let createID = UUID()
        let plan: InventoryOperationPlan
        let draft: InventoryReviewEdit

        init(shared: Bool = false) {
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            let productID = self.productID
            draft = .init(name: "牛奶", quantity: "1", unit: "瓶", storage: "", purchasedAt: nil,
                          packageExpiry: nil, estimatedExpiry: nil, plannedUseBy: date)
            let product = CreateProductOperation(productID: productID, canonicalName: "牛奶", brand: nil,
                categoryRawValue: nil, defaultUnit: nil,
                evidence: [.init(fieldKey: .canonicalName, source: .userStated, confidence: 1, rawText: "牛奶")])
            func lot(_ id: UUID) -> PlannedInventoryOperation {
                .init(operationID: UUID(), operation: .addLot(.init(lotID: id, productID: productID,
                    quantity: 1, unit: "瓶", purchasedAt: nil, packageExpiryDate: nil, estimatedExpiryDate: nil,
                    plannedUseByDate: date, storageLocation: nil, evidence: [
                        .init(fieldKey: .quantity, source: .userStated, confidence: 1, rawText: "1"),
                        .init(fieldKey: .unit, source: .userStated, confidence: 1, rawText: "瓶"),
                        .init(fieldKey: .plannedUseByDate, source: .systemEstimate, confidence: 0.6, rawText: nil)
                    ])))
            }
            var operations: [PlannedInventoryOperation] = [.init(operationID: createID, operation: .createProduct(product)), lot(lotID)]
            if shared { operations.append(lot(UUID())) }
            plan = .init(schemaVersion: 1, planID: UUID(), inputID: UUID(), operations: operations, unresolvedFields: [])
        }
    }
}
