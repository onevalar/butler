import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor
final class LotPresentationTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 9))!

    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: now)! }

    func testGlyphPrefersSpecificWordsThenMedicineThenFirstCharacter() {
        XCTAssertEqual(LotGlyph.glyph(for: "简爱原味酸奶", isMedicine: false), "酸")
        XCTAssertEqual(LotGlyph.glyph(for: "光明鲜牛奶", isMedicine: false), "奶")
        XCTAssertEqual(LotGlyph.glyph(for: "哈根达斯冰激凌", isMedicine: false), "冰")
        XCTAssertTrue(LotGlyph.isMedicine(name: "布洛芬缓释胶囊", category: nil))
        XCTAssertEqual(LotGlyph.glyph(for: "布洛芬缓释胶囊", isMedicine: true), "药")
        XCTAssertFalse(LotGlyph.isMedicine(name: "薯片", category: nil))
        XCTAssertEqual(LotGlyph.glyph(for: "薯片", isMedicine: false), "薯")
    }

    func testGoverningDateIsEarliestOfThreeDatesAndDrivesTier() {
        let product = CatalogProduct(canonicalName: "鲜牛奶")
        let lot = InventoryLot(productID: product.id, quantity: 1, unit: "瓶",
                               packageExpiryDate: day(6), plannedUseByDate: day(2))
        let facts = LotFacts(lot: lot, product: product, now: now, calendar: calendar)
        XCTAssertEqual(facts.governingDateKind, .plannedUseBy)
        XCTAssertEqual(facts.daysLeft, 2)
        XCTAssertEqual(facts.tier, .soon)
        XCTAssertFalse(facts.needsDate)
    }

    func testTierBoundaries() {
        XCTAssertEqual(UrgencyTier(daysLeft: -1), .overdue)
        XCTAssertEqual(UrgencyTier(daysLeft: 0), .today)
        XCTAssertEqual(UrgencyTier(daysLeft: 3), .soon)
        XCTAssertEqual(UrgencyTier(daysLeft: 4), .week)
        XCTAssertEqual(UrgencyTier(daysLeft: 8), .calm)
        XCTAssertEqual(UrgencyTier(daysLeft: nil), .undated)
    }

    func testUndatedLotAsksForDateAndAmbiguousFridgeAsksForCompartment() {
        let product = CatalogProduct(canonicalName: "冰激凌")
        let lot = InventoryLot(productID: product.id, quantity: 1, unit: "个", storageLocation: StorageLocation.ambiguousFridge)
        let facts = LotFacts(lot: lot, product: product, now: now, calendar: calendar)
        XCTAssertTrue(facts.needsDate)
        XCTAssertTrue(facts.needsCompartment)
        XCTAssertEqual(facts.timeLeftLabel, "待补日期")
    }

    func testPostponedStorageKeepsStatedFridgeAndClearsQuestion() async throws {
        let container = try ButlerStore.makePreviewContainer()
        let coordinator = InventoryInputCoordinator(
            provider: LocalInventoryPlanProvider(),
            lookup: CatalogProductLookup(modelContainer: container),
            repository: InventoryRepository(modelContainer: container)
        )
        await coordinator.submit(text: "买了一个冰激凌。冰激凌先放冰箱了", referenceDate: now, timeZone: calendar.timeZone)
        XCTAssertEqual(coordinator.state, .clarifying)
        guard case .field(let field)? = coordinator.questions.first else { return XCTFail("expected storage question") }

        coordinator.postponeStorage(field)
        XCTAssertEqual(coordinator.state, .reviewing)
        coordinator.confirmAndExecute()
        XCTAssertEqual(coordinator.state, .completed)

        let lots = try ModelContext(container).fetch(FetchDescriptor<InventoryLot>())
        XCTAssertEqual(lots.map(\.storageLocation), [StorageLocation.ambiguousFridge])
    }

    func testChoosingFreezerRecordsPlanEstimateButNeverAPackageDate() async throws {
        let container = try ButlerStore.makePreviewContainer()
        let coordinator = InventoryInputCoordinator(
            provider: LocalInventoryPlanProvider(),
            lookup: CatalogProductLookup(modelContainer: container),
            repository: InventoryRepository(modelContainer: container)
        )
        await coordinator.submit(text: "买了一个冰激凌。冰激凌先放冰箱了", referenceDate: now, timeZone: calendar.timeZone)
        guard case .field(let field)? = coordinator.questions.first else { return XCTFail("expected storage question") }
        coordinator.answerStorage(field, choice: .frozen)
        coordinator.confirmAndExecute()

        let lot = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).first)
        XCTAssertEqual(lot.storageLocation, "冷冻")
        XCTAssertNil(lot.packageExpiryDate)
        let planned = try XCTUnwrap(lot.plannedUseByDate)
        XCTAssertEqual(LotFacts.days(from: now, to: planned, calendar: calendar), 60)
        let evidence = try ModelContext(container).fetch(FetchDescriptor<FieldEvidence>())
            .first { $0.fieldKey == InventoryFieldKey.plannedUseByDate.rawValue }
        XCTAssertEqual(evidence?.sourceKindRawValue, EvidenceSourceKind.systemEstimate.rawValue)
    }

    func testButtonActionsWriteThroughPolicyWithUserConfirmation() throws {
        let container = try ButlerStore.makePreviewContainer()
        let context = ModelContext(container)
        let product = CatalogProduct(canonicalName: "牛奶")
        let lot = InventoryLot(productID: product.id, quantity: 1, unit: "瓶")
        context.insert(product)
        context.insert(lot)
        try context.save()
        let actions = InventoryActions(modelContainer: container)

        var facts = LotFacts(lot: lot, product: product, now: now, calendar: calendar)
        try actions.setPackageExpiry(day(5), for: facts, source: .ocr, rawText: "2026.09.26")
        let fresh = ModelContext(container)
        let dated = try XCTUnwrap(fresh.fetch(FetchDescriptor<InventoryLot>()).first)
        XCTAssertEqual(dated.packageExpiryDate, day(5))
        let evidence = try fresh.fetch(FetchDescriptor<FieldEvidence>())
        XCTAssertEqual(evidence.first?.sourceKindRawValue, EvidenceSourceKind.ocr.rawValue)
        XCTAssertEqual(evidence.first?.verificationStateRawValue, EvidenceVerificationState.userConfirmed.rawValue)

        facts = LotFacts(lot: dated, product: product, now: now, calendar: calendar)
        try actions.close(facts, as: .depleted)
        let closed = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).first)
        XCTAssertEqual(closed.state, .depleted)

        // A stale revision (the pre-close snapshot) must not be able to act again.
        XCTAssertThrowsError(try actions.close(facts, as: .discarded))
    }
}
