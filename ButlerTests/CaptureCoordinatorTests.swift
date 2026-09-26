import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor
final class CaptureCoordinatorTests: XCTestCase {
    func testExplicitSecondCandidateThenRenameDoesNotMutateCatalog() async throws {
        let configuration = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ButlerStore.schema, configurations: [configuration])
        let context = ModelContext(container)
        let firstID = UUID(), secondID = UUID()
        context.insert(CatalogProduct(id: firstID, canonicalName: "牛奶"))
        context.insert(CatalogProduct(id: secondID, canonicalName: "牛奶"))
        try context.save()
        let coordinator = InventoryInputCoordinator(provider: LocalInventoryPlanProvider(),
            lookup: CatalogProductLookup(modelContainer: container),
            repository: InventoryRepository(modelContainer: container))
        await coordinator.submit(text: "买了一瓶牛奶")
        XCTAssertEqual(coordinator.state, .clarifying)
        guard case .productChoice(let operationID, _, let candidates)? = coordinator.questions.first else {
            return XCTFail("Expected individual candidate selection")
        }
        XCTAssertEqual(Set(candidates.map(\.id)), [firstID, secondID])
        coordinator.confirmAndExecute()
        XCTAssertTrue(try context.fetch(FetchDescriptor<InventoryLot>()).isEmpty)
        coordinator.chooseProduct(createOperationID: operationID, choice: .existing(productID: UUID()))
        XCTAssertEqual(coordinator.state, .clarifying)
        coordinator.chooseProduct(createOperationID: operationID, choice: .existing(productID: secondID))
        XCTAssertEqual(coordinator.state, .reviewing)
        let plan = try XCTUnwrap(coordinator.reviewPlan)
        let selected = try XCTUnwrap(plan.operations.compactMap { planned -> AddLotOperation? in
            if case .addLot(let lot) = planned.operation { return lot }; return nil
        }.first)
        XCTAssertEqual(selected.productID, secondID)
        var draft = try XCTUnwrap(coordinator.reviewDraft(lotID: selected.lotID))
        draft.name = "燕麦奶"
        draft.quantity = "2"
        draft.packageExpiry = Date(timeIntervalSince1970: 1_900_000_000)
        XCTAssertTrue(coordinator.editReview(lotID: selected.lotID, draft: draft))
        XCTAssertEqual(coordinator.reviewPlan?.planID, plan.planID)
        let oldRequirement = try XCTUnwrap(coordinator.confirmationRequirements.first)
        draft.packageExpiry = draft.packageExpiry?.addingTimeInterval(86400)
        XCTAssertTrue(coordinator.editReview(lotID: selected.lotID, draft: draft))
        XCTAssertNotEqual(coordinator.confirmationRequirements.first?.proposedValueIdentity, oldRequirement.proposedValueIdentity)
        XCTAssertTrue(try context.fetch(FetchDescriptor<InventoryLot>()).isEmpty)
        coordinator.confirmAndExecute()
        XCTAssertEqual(coordinator.state, .completed, coordinator.errorMessage ?? "")
        let verify = ModelContext(container)
        let products = try verify.fetch(FetchDescriptor<CatalogProduct>())
        XCTAssertEqual(products.filter { $0.id == firstID || $0.id == secondID }.map(\.canonicalName), ["牛奶", "牛奶"])
        XCTAssertEqual(products.count, 3)
        let saved = try XCTUnwrap(verify.fetch(FetchDescriptor<InventoryLot>()).first)
        XCTAssertEqual(saved.id, selected.lotID)
        XCTAssertEqual(saved.quantity, 2)
    }
}
