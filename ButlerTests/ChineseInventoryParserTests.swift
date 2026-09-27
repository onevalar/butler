import Foundation
import XCTest
@testable import Butler

/// Real sentences people say, and what Butler must hear. Each line is a product promise.
final class ChineseInventoryParserTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!
    private lazy var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }()
    /// Monday 2026-09-21, 09:00.
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 9))!

    private struct Heard {
        let name: String
        let quantity: Int
        let unit: String
        let quantityGuessed: Bool
        let storage: String?
        let storageGuessed: Bool
        let asksCompartment: Bool
        let packageInDays: Int?
        let estimatedInDays: Int?
        let plannedInDays: Int?
        let plannedGuessed: Bool
        let category: String?
    }

    private func hear(_ text: String) throws -> [Heard] {
        let input = InventoryPlanningInput(text: text, locale: Locale(identifier: "zh_CN"), referenceDate: now,
                                           timeZone: timeZone, inputID: UUID(), planID: UUID())
        let plan = try LocalInventoryPlanProvider().makePlan(for: input)
        XCTAssertEqual(InventoryPolicy.evaluate(plan).isReject, false, "plan must pass policy: \(text)")

        var products: [UUID: CreateProductOperation] = [:]
        for planned in plan.operations {
            if case .createProduct(let product) = planned.operation { products[product.productID] = product }
        }
        return plan.operations.compactMap { planned in
            guard case .addLot(let lot) = planned.operation else { return nil }
            let source = { (key: InventoryFieldKey) in lot.evidence.first { $0.fieldKey == key }?.source }
            let days = { (date: Date?) in date.map { LotFacts.days(from: self.now, to: $0, calendar: self.calendar) } }
            return Heard(
                name: products[lot.productID]?.canonicalName ?? "?",
                quantity: lot.quantity, unit: lot.unit,
                quantityGuessed: source(.quantity) == .systemEstimate,
                storage: lot.storageLocation,
                storageGuessed: source(.storageLocation) == .systemEstimate,
                asksCompartment: plan.unresolvedFields.contains { $0.entityID == lot.lotID },
                packageInDays: days(lot.packageExpiryDate),
                estimatedInDays: days(lot.estimatedExpiryDate),
                plannedInDays: days(lot.plannedUseByDate),
                plannedGuessed: source(.plannedUseByDate) == .systemEstimate,
                category: products[lot.productID]?.categoryRawValue
            )
        }
    }

    // MARK: - The spec's acceptance sentence

    func testSpecSentenceStillBehavesExactlyAsSpecified() throws {
        let items = try hear("我今天买了一瓶牛奶、三包方便面和一个冰激凌。冰激凌先放冰箱了还没吃")
        XCTAssertEqual(items.map(\.name), ["牛奶", "方便面", "冰激凌"])
        XCTAssertEqual(items.map(\.quantity), [1, 3, 1])
        XCTAssertEqual(items.map(\.unit), ["瓶", "包", "个"])
        XCTAssertEqual(items.map(\.asksCompartment), [false, false, true], "only ice cream is asked")
        XCTAssertNil(items[1].packageInDays, "a plan date must never become a package date")
        let noodles = try XCTUnwrap(items[1].plannedInDays)
        XCTAssertEqual(noodles, LotFacts.days(from: now, to: calendar.date(byAdding: .month, value: 3, to: now)!, calendar: calendar))
        XCTAssertTrue(items[1].plannedGuessed)
    }

    // MARK: - Amounts

    func testNoQuantityMeansOneAndIsMarkedAsAGuess() throws {
        let items = try hear("买了牛奶和鸡蛋")
        XCTAssertEqual(items.map(\.name), ["牛奶", "鸡蛋"])
        XCTAssertEqual(items.map(\.quantity), [1, 1])
        XCTAssertEqual(items.map(\.unit), ["瓶", "个"])
        XCTAssertEqual(items.map(\.quantityGuessed), [true, true])
    }

    func testVagueAmountAndFillerWords() throws {
        let items = try hear("今天去超市囤了点酸奶")
        XCTAssertEqual(items.map(\.name), ["酸奶"])
        XCTAssertEqual(items.first?.unit, "杯")
        XCTAssertEqual(items.first?.quantityGuessed, true)
    }

    func testAmountAfterTheName() throws {
        let items = try hear("牛奶两瓶，鸡蛋一打")
        XCTAssertEqual(items.map(\.name), ["牛奶", "鸡蛋"])
        XCTAssertEqual(items.map(\.quantity), [2, 12])
    }

    func testDozenAndBigChineseNumbers() throws {
        XCTAssertEqual(try hear("一打鸡蛋").first?.quantity, 12)
        XCTAssertEqual(try hear("十二瓶矿泉水").first?.quantity, 12)
        XCTAssertEqual(try hear("二十包纸巾").first?.quantity, 20)
        XCTAssertEqual(ChineseInventoryParser.chineseInteger("一百零五"), 105)
    }

    func testWeightsBecomeOnePortionWithANote() throws {
        let items = try hear("五百克牛肉")
        XCTAssertEqual(items.map(\.name), ["牛肉"])
        XCTAssertEqual(items.first?.quantity, 1)
        XCTAssertEqual(items.first?.quantityGuessed, true)
    }

    // MARK: - Splitting speech without punctuation

    func testSpeechWithoutPunctuationStillSplitsItems() throws {
        let items = try hear("买了一瓶牛奶三包方便面")
        XCTAssertEqual(items.map(\.name), ["牛奶", "方便面"])
        XCTAssertEqual(items.map(\.quantity), [1, 3])
    }

    func testSpacesSeparateItems() throws {
        XCTAssertEqual(try hear("牛奶 鸡蛋 面包").map(\.name), ["牛奶", "鸡蛋", "面包"])
    }

    func testBrandNamesContainingHeAreNotSplit() throws {
        let items = try hear("和路雪冰淇淋一盒")
        XCTAssertEqual(items.map(\.name), ["和路雪冰淇淋"])
        XCTAssertEqual(items.first?.unit, "盒")
    }

    func testRunTogetherProductNamesAreSeparatedButFlavoursAreNot() throws {
        XCTAssertEqual(try hear("今天买了酸奶鸡蛋和面包").map(\.name), ["酸奶", "鸡蛋", "面包"])
        XCTAssertEqual(try hear("买了草莓酸奶").map(\.name), ["草莓酸奶"])
    }

    func testNamesFirstThenAmountsWithoutPauses() throws {
        let items = try hear("牛奶一瓶鸡蛋十个面包两袋")
        XCTAssertEqual(items.map(\.name), ["牛奶", "鸡蛋", "面包"])
        XCTAssertEqual(items.map(\.quantity), [1, 10, 2])
    }

    func testAmountSaidAfterTheVerb() throws {
        let item = try XCTUnwrap(try hear("感冒药买了两盒放药箱了").first)
        XCTAssertEqual(item.quantity, 2)
        XCTAssertEqual(item.storage, "药箱")
    }

    func testRestockAfterFinishingSomething() throws {
        let items = try hear("牛奶喝完了又买了两瓶")
        XCTAssertEqual(items.map(\.name), ["牛奶"])
        XCTAssertEqual(items.first?.quantity, 2)
    }

    func testWhoItIsForAndHesitationsAreNotItems() throws {
        XCTAssertEqual(try hear("给宝宝买了一罐奶粉").map(\.name), ["奶粉"])
        XCTAssertEqual(try hear("嗯那个我买了牛奶").map(\.name), ["牛奶"])
        XCTAssertEqual(try hear("刚从盒马回来，买了一盒草莓").map(\.name), ["草莓"])
    }

    // MARK: - Where it is

    func testFridgeMeansChilledForFreshFoodButIsAskedForFreezables() throws {
        let items = try hear("买了两盒草莓和一袋饺子，都放冰箱了")
        XCTAssertEqual(items.map(\.name), ["草莓", "饺子"])
        XCTAssertEqual(items[0].storage, "冷藏")
        XCTAssertTrue(items[0].storageGuessed)
        XCTAssertNil(items[1].storage)
        XCTAssertTrue(items[1].asksCompartment)
    }

    func testExplicitCompartmentIsNeverAsked() throws {
        let items = try hear("饺子放冷冻了")
        XCTAssertEqual(items.first?.storage, "冷冻")
        XCTAssertEqual(items.first?.storageGuessed, false)
        XCTAssertEqual(items.first?.asksCompartment, false)
    }

    func testStorageSaidBeforeTheItem() throws {
        let items = try hear("冰箱里放了两盒牛奶")
        XCTAssertEqual(items.map(\.name), ["牛奶"])
        XCTAssertEqual(items.first?.quantity, 2)
        XCTAssertEqual(items.first?.storage, "冷藏")
    }

    func testFollowUpClauseAttachesToThePreviousItems() throws {
        let items = try hear("买了两盒草莓，放冰箱了")
        XCTAssertEqual(items.first?.storage, "冷藏")
    }

    // MARK: - Dates

    func testSpokenExpiryIsAPackageDate() throws {
        XCTAssertEqual(try hear("一瓶牛奶明天过期").first?.packageInDays, 1)
        XCTAssertEqual(try hear("酸奶还有三天过期").first?.packageInDays, 3)
        XCTAssertEqual(try hear("牛奶10月5号过期").first?.packageInDays, 14)
    }

    func testShelfLifeIsAnEstimateNotAPackageDate() throws {
        let item = try XCTUnwrap(try hear("买了面包保质期七天").first)
        XCTAssertEqual(item.name, "面包")
        XCTAssertEqual(item.estimatedInDays, 7)
        XCTAssertNil(item.packageInDays)
    }

    func testSpokenPlans() throws {
        let withinDays = try XCTUnwrap(try hear("酸奶三天内喝掉").first)
        XCTAssertEqual(withinDays.plannedInDays, 3)
        XCTAssertFalse(withinDays.plannedGuessed, "the user said it")

        XCTAssertEqual(try hear("一瓶牛奶一个月内喝掉").first?.name, "牛奶")

        let soon = try XCTUnwrap(try hear("买了点草莓要尽快吃").first)
        XCTAssertEqual(soon.plannedInDays, 2)
        XCTAssertTrue(soon.plannedGuessed, "尽快 is vague, the day is Butler's pick")
    }

    // MARK: - Kinds

    func testMedicineIsStrictAndNeverGetsGuessedDates() throws {
        let item = try XCTUnwrap(try hear("买了一盒布洛芬").first)
        XCTAssertEqual(item.category, "medicine")
        XCTAssertNil(item.plannedInDays)
        XCTAssertNil(item.packageInDays)
    }

    func testHouseholdGoodsOnlyCountQuantityAndGetNoInventedDate() throws {
        for text in ["三包纸巾", "买了一箱矿泉水"] {
            let item = try XCTUnwrap(try hear(text).first)
            XCTAssertEqual(item.category, "household", text)
            XCTAssertNil(item.plannedInDays, text)
        }
        let product = CatalogProduct(canonicalName: "纸巾", categoryRawValue: "household")
        let lot = InventoryLot(productID: product.id, quantity: 1, unit: "包")
        lot.plannedUseByDate = .now
        let facts = LotFacts(lot: lot, product: product)
        XCTAssertFalse(facts.needsDate)
        XCTAssertNil(facts.governingDate, "quantity-only items never drive date reminders")
        XCTAssertTrue(facts.isRunningLow)
        XCTAssertEqual(facts.dateStatusLabel, "只剩 1 包")
    }

    func testPackagedFreshFoodIsNeverGivenAGuessedDate() throws {
        let milk = try XCTUnwrap(try hear("买了一瓶牛奶").first)
        XCTAssertNil(milk.plannedInDays)
        XCTAssertNil(milk.packageInDays)
    }

    func testLooseProduceGetsAPlanSuggestionInsteadOfAPhotoRequest() throws {
        let strawberries = try XCTUnwrap(try hear("买了两盒草莓").first)
        XCTAssertEqual(strawberries.plannedInDays, 3)
        XCTAssertTrue(strawberries.plannedGuessed)
        XCTAssertNil(strawberries.packageInDays, "a suggestion is never a package date")
    }

    // MARK: - Things it must not record

    func testUsingUpIsExplainedInsteadOfMisrecorded() {
        do {
            _ = try hear("牛奶喝完了")
            XCTFail("must not record anything")
        } catch InventoryPlanningError.usingUpNotSupported {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testNothingConcreteIsNotInvented() {
        do {
            _ = try hear("买了一些东西")
            XCTFail("must not invent an item")
        } catch InventoryPlanningError.noInventoryItems {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

private extension InventoryPolicyDecision {
    var isReject: Bool { if case .reject = self { return true } else { return false } }
}
