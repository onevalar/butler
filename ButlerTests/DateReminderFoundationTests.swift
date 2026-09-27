import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor
final class DateReminderFoundationTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private func date(_ day: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }

    func testDateKindsNeverTurnPlansOrEstimatesIntoConfirmedExpiry() {
        for kind in [LotDateKind.packageExpiry, .estimatedExpiry, .plannedUseBy] {
            let lot = InventoryLot(productID: UUID(), quantity: 1, unit: "个")
            switch kind {
            case .packageExpiry: lot.packageExpiryDate = date(20)
            case .estimatedExpiry: lot.estimatedExpiryDate = date(20)
            case .plannedUseBy: lot.plannedUseByDate = date(20)
            }
            let facts = LotFacts(lot: lot, product: nil, now: date(21), calendar: calendar)
            XCTAssertEqual(facts.governingDateKind, kind)
            XCTAssertEqual(facts.dateStatusLabel.contains("已过期"), kind == .packageExpiry)
            XCTAssertEqual(facts.timeLeftLabel, facts.dateStatusLabel)
            XCTAssertEqual(facts.dateKindLabel, kind == .packageExpiry ? "包装有效期" : (kind == .estimatedExpiry ? "预计到期" : "计划用完"))
        }
    }

    func testEarlierPlanKeepsItsMeaningEvenWithLaterPackageExpiry() {
        let lot = InventoryLot(productID: UUID(), quantity: 1, unit: "个",
                               packageExpiryDate: date(29), plannedUseByDate: date(20))
        let facts = LotFacts(lot: lot, product: nil, now: date(21), calendar: calendar)
        XCTAssertEqual(facts.dateStatusLabel, "已超过计划日期 1 天")
    }

    func testOCRProductionAmbiguityInvalidDatesAndExpiry() {
        for text in ["生产日期 2026.09.21", "MFG 20260921"] {
            let candidate = DateParser.candidate(in: text)
            XCTAssertEqual(candidate.context, .production)
            XCTAssertNil(candidate.date)
        }
        for text in ["03/04/2026", "26/09/21", "2026.02.30", "2026.13.01",
                     "EXP 2026.09.21 2026.09.22", "MFG / EXP 2026.09.21", "2026.09"] {
            XCTAssertNil(DateParser.parse(text), text)
        }
        let expiry = DateParser.candidate(in: "EXP: 2026.09.21", calendar: calendar)
        XCTAssertEqual(expiry.context, .expiry)
        XCTAssertEqual(expiry.date, calendar.startOfDay(for: date(21)))
        XCTAssertEqual(DateParser.candidate(in: "20260921").context, .unlabeled)
        XCTAssertNotNil(DateParser.parse("2024年2月29日"))
        XCTAssertNil(DateParser.parse("2026年2月29日"))
    }

    func testLeadBoundaryAndCatchupOnce() throws {
        let due = date(23)
        let boundary = date(21)
        func fire(_ now: Date, receipt: Date? = nil) -> Date? {
            LotReminderPolicy.fireDate(date: due, isMedicine: false, leadDays: 2,
                                       now: now, calendar: calendar, recordedFireDate: receipt)
        }
        XCTAssertEqual(fire(boundary.addingTimeInterval(-1)), boundary)
        let catchup = try XCTUnwrap(fire(boundary))
        XCTAssertEqual(catchup, boundary.addingTimeInterval(60))
        XCTAssertEqual(fire(boundary.addingTimeInterval(30), receipt: catchup), catchup)
        XCTAssertNil(fire(catchup, receipt: catchup))
        XCTAssertNil(fire(date(25), receipt: catchup))
        // A regular scheduled reminder must not become a catch-up after delivery either.
        XCTAssertNil(fire(boundary, receipt: boundary))
    }

    func testNewDueTodayAndOverdueLotsGetOneCatchupAndMedicineGetsExtraLead() {
        let now = date(21)
        for due in [date(20), date(21), date(22)] {
            XCTAssertEqual(LotReminderPolicy.fireDate(date: due, isMedicine: false, leadDays: 2,
                                                    now: now, calendar: calendar, recordedFireDate: nil),
                           now.addingTimeInterval(60))
        }
        XCTAssertEqual(LotReminderPolicy.fireDate(date: date(29), isMedicine: true, leadDays: 2,
                                                now: now, calendar: calendar, recordedFireDate: nil), date(23))
    }

    func testReceiptSurvivesNonDateEditsButChangesForNewDateOrKind() {
        let lot = InventoryLot(productID: UUID(), quantity: 1, unit: "个", packageExpiryDate: date(23))
        func key() -> String? {
            LotReminderPolicy.receiptKey(for: LotFacts(lot: lot, product: nil), calendar: calendar)
        }
        let first = key()
        lot.quantity = 3
        lot.revision += 1
        XCTAssertEqual(key(), first)
        lot.packageExpiryDate = date(24)
        XCTAssertNotEqual(key(), first)
        lot.packageExpiryDate = nil
        lot.estimatedExpiryDate = date(23)
        XCTAssertNotEqual(key(), first)
        lot.estimatedExpiryDate = nil
        XCTAssertNil(key())
    }

    func testLeadPreferenceChangesRescheduleOnlyUndeliveredReminder() {
        let oldFire = date(27)
        XCTAssertEqual(LotReminderPolicy.fireDate(date: date(29), isMedicine: false, leadDays: 4,
                                                now: date(21), calendar: calendar, recordedFireDate: oldFire), date(25))
        XCTAssertNil(LotReminderPolicy.fireDate(date: date(29), isMedicine: false, leadDays: 1,
                                              now: date(27), calendar: calendar, recordedFireDate: oldFire))
    }
}

@MainActor
final class NotificationActionTests: XCTestCase {
    func testUsedUpFromANotificationClosesTheLot() throws {
        let container = try ButlerStore.makePreviewContainer()
        let context = ModelContext(container)
        let product = CatalogProduct(canonicalName: "苹果")
        let lot = InventoryLot(productID: product.id, quantity: 5, unit: "个")
        context.insert(product); context.insert(lot); try context.save()

        let manager = NotificationManager.shared
        let previous = manager.container
        manager.container = container
        defer { manager.container = previous }
        manager.markUsedUp(lot.id)
        manager.markUsedUp(lot.id) // a second tap on an old notification changes nothing

        let saved = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).first)
        XCTAssertEqual(saved.state, .depleted)
        let events = try ModelContext(container).fetch(FetchDescriptor<InventoryEvent>())
        XCTAssertEqual(events.filter { $0.subjectID == lot.id }.count, 1)
    }

    func testCategoriesCarryTheButtons() {
        XCTAssertEqual(NotificationManager.lotCategory, "butler.lot")
        XCTAssertEqual(NotificationManager.reminderCategory, "butler.reminder")
    }
}
