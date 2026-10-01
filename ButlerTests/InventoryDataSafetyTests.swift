import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor
final class InventoryDataSafetyTests: XCTestCase {
    func testCompleteSchemaCanSaveAndReopenAtUniqueTemporaryURL() throws {
        let store = try TemporaryStore()
        defer {
            do {
                try store.remove()
            } catch {
                XCTFail("Failed to remove temporary store: \(error)")
            }
        }
        let productID = UUID()
        let lotID = UUID()

        try saveFixture(to: store, productID: productID, lotID: lotID)
        try verifyFixture(in: store, productID: productID, lotID: lotID)
    }

    func testRepositoryAtomicallyCreatesProductAndLot() throws {
        let fixture = try RepositoryFixture()
        let plan = fixture.creationPlan(quantity: 3)

        let result = try fixture.repository.execute(plan, actor: .user)

        XCTAssertEqual(result.appliedOperationIDs, plan.operations.map(\.operationID))
        XCTAssertEqual(try fixture.fetch(CatalogProduct.self).count, 1)
        XCTAssertEqual(try fixture.fetch(InventoryLot.self).first?.quantity, 3)
        XCTAssertEqual(try fixture.fetch(InventoryEvent.self).count, 2)
    }

    func testNegativeQuantityIsRejectedWithoutWritesAndMidPlanFailureRollsBack() throws {
        let negative = try RepositoryFixture()
        XCTAssertThrowsError(try negative.repository.execute(negative.creationPlan(quantity: -1), actor: .assistant)) {
            guard case InventoryRepositoryError.rejected = $0 else {
                return XCTFail("Expected policy rejection, got \($0)")
            }
        }
        XCTAssertTrue(try negative.fetch(CatalogProduct.self).isEmpty)
        XCTAssertTrue(try negative.fetch(InventoryLot.self).isEmpty)
        XCTAssertTrue(try negative.fetch(FieldEvidence.self).isEmpty)
        XCTAssertTrue(try negative.fetch(InventoryEvent.self).isEmpty)

        let midway = try RepositoryFixture()
        let product = midway.createProductOperation()
        let missingProductLot = midway.addLotOperation(productID: UUID(), quantity: 1)
        let plan = midway.plan([product, missingProductLot])
        XCTAssertThrowsError(try midway.repository.execute(plan, actor: .assistant)) {
            guard case InventoryRepositoryError.entityNotFound = $0 else {
                return XCTFail("Expected missing product, got \($0)")
            }
        }
        XCTAssertTrue(try midway.fetch(CatalogProduct.self).isEmpty)
        XCTAssertTrue(try midway.fetch(InventoryLot.self).isEmpty)
        XCTAssertTrue(try midway.fetch(FieldEvidence.self).isEmpty)
        XCTAssertTrue(try midway.fetch(InventoryEvent.self).isEmpty)
    }

    func testExactOperationReplayDoesNotDuplicateAndChangedPayloadConflicts() throws {
        let fixture = try RepositoryFixture()
        let operation = fixture.createProductOperation()
        let original = fixture.plan([operation])
        _ = try fixture.repository.execute(original, actor: .user)

        let replay = try fixture.repository.execute(original, actor: .user)
        XCTAssertEqual(replay.replayedOperationIDs, [operation.operationID])
        XCTAssertTrue(replay.appliedOperationIDs.isEmpty)
        XCTAssertEqual(try fixture.fetch(CatalogProduct.self).count, 1)
        XCTAssertEqual(try fixture.fetch(FieldEvidence.self).count, 2)
        XCTAssertEqual(try fixture.fetch(InventoryEvent.self).count, 1)

        let changed = PlannedInventoryOperation(
            operationID: operation.operationID,
            operation: .createProduct(.init(
                productID: fixture.productID,
                canonicalName: "Changed payload",
                brand: nil,
                categoryRawValue: nil,
                defaultUnit: nil,
                evidence: [.init(fieldKey: .canonicalName, source: .userStated, confidence: 1, rawText: nil)]
            ))
        )
        XCTAssertThrowsError(try fixture.repository.execute(fixture.plan([changed]), actor: .user)) {
            guard case InventoryRepositoryError.operationIDConflict(let conflictingID) = $0,
                  conflictingID == operation.operationID else {
                return XCTFail("Expected operation ID conflict, got \($0)")
            }
        }
        XCTAssertEqual(try fixture.fetch(CatalogProduct.self).count, 1)
        XCTAssertEqual(try fixture.fetch(FieldEvidence.self).count, 2)
        XCTAssertEqual(try fixture.fetch(InventoryEvent.self).count, 1)
    }

    func testQuantityReachingZeroDepletesLotAndStaleRevisionIsRejected() throws {
        let fixture = try RepositoryFixture()
        _ = try fixture.repository.execute(fixture.creationPlan(quantity: 2), actor: .user)
        let adjustment = fixture.adjustmentPlan(delta: -2, expectedRevision: 0)
        _ = try fixture.repository.execute(
            adjustment,
            trustedConfirmations: fixture.confirmations(for: adjustment),
            actor: .user
        )

        var lot = try XCTUnwrap(try fixture.fetch(InventoryLot.self).first)
        XCTAssertEqual(lot.quantity, 0)
        XCTAssertEqual(lot.state, .depleted)
        XCTAssertEqual(lot.revision, 1)

        let stale = fixture.adjustmentPlan(delta: 1, expectedRevision: 0)
        XCTAssertThrowsError(try fixture.repository.execute(
            stale,
            trustedConfirmations: fixture.confirmations(for: stale),
            actor: .user
        )) {
            guard case InventoryRepositoryError.staleRevision(_, let id, let expected, let actual) = $0,
                  id == fixture.lotID, expected == 0, actual == 1 else {
                return XCTFail("Expected stale revision, got \($0)")
            }
        }
        lot = try XCTUnwrap(try fixture.fetch(InventoryLot.self).first)
        XCTAssertEqual(lot.quantity, 0)
        XCTAssertEqual(lot.revision, 1)
    }

    func testLegacyMigrationIsIdempotentKeepsSameNamesSeparateAndDatesUnverified() throws {
        let container = try TestContainers.inMemory()
        let context = ModelContext(container)
        let oldDate = Date(timeIntervalSince1970: 1_577_836_800)
        context.insert(Item(name: "Milk", quantity: 1, type: .fresh, expiryDate: oldDate, isEstimated: false))
        context.insert(Item(name: "Milk", quantity: 2, type: .fresh, expiryDate: oldDate, isEstimated: true))
        try context.save()
        let migrator = LegacyItemMigrator(modelContainer: container)

        let first = try migrator.migrateAll()
        let countsAfterFirst = try MigrationCounts(container: container)
        let second = try migrator.migrateAll()
        let countsAfterSecond = try MigrationCounts(container: container)

        XCTAssertEqual(first.migratedCount, 2)
        XCTAssertEqual(first.alreadyMigratedCount, 0)
        XCTAssertEqual(second.migratedCount, 0)
        XCTAssertEqual(second.alreadyMigratedCount, 2)
        XCTAssertEqual(countsAfterSecond.products, countsAfterFirst.products)
        XCTAssertEqual(countsAfterSecond.lots, countsAfterFirst.lots)
        XCTAssertEqual(countsAfterSecond.links, countsAfterFirst.links)
        XCTAssertEqual(countsAfterSecond.evidence, countsAfterFirst.evidence)
        XCTAssertEqual(countsAfterSecond.events, countsAfterFirst.events)
        let verificationContext = ModelContext(container)
        let products = try verificationContext.fetch(FetchDescriptor<CatalogProduct>())
        let lots = try verificationContext.fetch(FetchDescriptor<InventoryLot>())
        let links = try verificationContext.fetch(FetchDescriptor<LegacyItemLink>())
        XCTAssertEqual(products.count, 2, "Same-name legacy rows must not merge")
        XCTAssertEqual(Set(products.map(\.id)).count, 2)
        XCTAssertEqual(lots.count, 2)
        XCTAssertEqual(links.count, 2)
        XCTAssertTrue(lots.allSatisfy { $0.estimatedExpiryDate == oldDate && $0.packageExpiryDate == nil })
        let dateEvidence = try verificationContext.fetch(FetchDescriptor<FieldEvidence>()).filter {
            $0.fieldKey == InventoryFieldKey.estimatedExpiryDate.rawValue
        }
        XCTAssertEqual(dateEvidence.count, 2)
        XCTAssertTrue(dateEvidence.allSatisfy {
            $0.sourceKindRawValue == EvidenceSourceKind.legacyUnknown.rawValue &&
            $0.verificationStateRawValue == EvidenceVerificationState.unverified.rawValue &&
            $0.confidence == 0
        })
    }

    func testPendingLegacyItemOnlyStoreInPlaceSchemaUpgrade() throws {
        throw XCTSkip("Pending: validate SwiftData's Item-only on-disk schema creation and in-place full-schema upgrade with Xcode/macOS APIs; do not guess this API from Linux.")
    }

    private func saveFixture(to store: TemporaryStore, productID: UUID, lotID: UUID) throws {
        let container = try store.makeContainer()
        let context = ModelContext(container)
        context.insert(CatalogProduct(id: productID, canonicalName: "Oats"))
        context.insert(InventoryLot(id: lotID, productID: productID, quantity: 2, unit: "bag"))
        try context.save()
    }

    private func verifyFixture(in store: TemporaryStore, productID: UUID, lotID: UUID) throws {
        let container = try store.makeContainer()
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CatalogProduct>()).map(\.id), [productID])
        XCTAssertEqual(try context.fetch(FetchDescriptor<InventoryLot>()).map(\.id), [lotID])
        XCTAssertTrue(try context.fetch(FetchDescriptor<Item>()).isEmpty)
    }
}

@MainActor
private struct RepositoryFixture {
    let container: ModelContainer
    let repository: InventoryRepository
    let productID = UUID()
    let lotID = UUID()

    init() throws {
        let container = try TestContainers.inMemory()
        self.container = container
        repository = InventoryRepository(modelContainer: container)
    }

    func plan(_ operations: [PlannedInventoryOperation]) -> InventoryOperationPlan {
        .init(schemaVersion: InventoryOperationPlan.currentSchemaVersion, planID: UUID(), inputID: UUID(), operations: operations, unresolvedFields: [])
    }

    func createProductOperation() -> PlannedInventoryOperation {
        .init(operationID: UUID(), operation: .createProduct(.init(
            productID: productID,
            canonicalName: "Rice",
            brand: nil,
            categoryRawValue: nil,
            defaultUnit: "bag",
            evidence: [
                .init(fieldKey: .canonicalName, source: .userStated, confidence: 1, rawText: "Rice"),
                .init(fieldKey: .unit, source: .userStated, confidence: 1, rawText: "bag"),
            ]
        )))
    }

    func addLotOperation(productID: UUID? = nil, quantity: Int) -> PlannedInventoryOperation {
        .init(operationID: UUID(), operation: .addLot(.init(
            lotID: lotID,
            productID: productID ?? self.productID,
            quantity: quantity,
            unit: "bag",
            purchasedAt: nil,
            packageExpiryDate: nil,
            estimatedExpiryDate: nil,
            plannedUseByDate: nil,
            storageLocation: nil,
            evidence: [
                .init(fieldKey: .quantity, source: .userStated, confidence: 1, rawText: "\(quantity)"),
                .init(fieldKey: .unit, source: .userStated, confidence: 1, rawText: "bag"),
            ]
        )))
    }

    func creationPlan(quantity: Int) -> InventoryOperationPlan {
        plan([createProductOperation(), addLotOperation(quantity: quantity)])
    }

    func adjustmentPlan(delta: Int, expectedRevision: Int) -> InventoryOperationPlan {
        plan([.init(operationID: UUID(), operation: .adjustQuantity(.init(
            lotID: lotID,
            delta: delta,
            expectedRevision: expectedRevision,
            evidence: [.init(fieldKey: .quantity, source: .userEdited, confidence: 1, rawText: "\(delta)")]
        )))])
    }

    func confirmations(for plan: InventoryOperationPlan) -> [TrustedInventoryConfirmation] {
        guard case .requiresConfirmation(let requirements) = InventoryPolicy.evaluate(plan) else { return [] }
        return requirements.map { InventoryConfirmationAuthority.issue(for: $0) }
    }

    func fetch<Model: PersistentModel>(_ type: Model.Type) throws -> [Model] {
        try ModelContext(container).fetch(FetchDescriptor<Model>())
    }
}

private enum TestContainers {
    static func inMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: ButlerStore.schema, configurations: [configuration])
    }
}

@MainActor
private struct MigrationCounts {
    let products: Int
    let lots: Int
    let links: Int
    let evidence: Int
    let events: Int

    init(container: ModelContainer) throws {
        let context = ModelContext(container)
        products = try context.fetchCount(FetchDescriptor<CatalogProduct>())
        lots = try context.fetchCount(FetchDescriptor<InventoryLot>())
        links = try context.fetchCount(FetchDescriptor<LegacyItemLink>())
        evidence = try context.fetchCount(FetchDescriptor<FieldEvidence>())
        events = try context.fetchCount(FetchDescriptor<InventoryEvent>())
    }
}

private struct TemporaryStore {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ButlerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        self.directoryURL = directoryURL
        databaseURL = directoryURL.appendingPathComponent("Butler.sqlite")
    }

    func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: ButlerStore.schema, url: databaseURL, cloudKitDatabase: .none)
        return try ModelContainer(for: ButlerStore.schema, configurations: [configuration])
    }

    func remove() throws {
        try FileManager.default.removeItem(at: directoryURL)
    }
}
