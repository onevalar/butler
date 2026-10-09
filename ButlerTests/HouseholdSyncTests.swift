import Foundation
import SwiftData
import XCTest
@testable import Butler

/// Two phones in one household, over a fake CloudKit zone.
@MainActor final class HouseholdSyncTests: XCTestCase {
    struct Phone {
        let base: ButlerSyncData
        let household: HouseholdStore
        let sync: SyncStore
        var container: ModelContainer { base.container }
    }

    private let owner = UUID(), member = UUID()

    private func phone(_ cloud: FakeSyncCloud, me: UUID, role: HouseholdState.Role, name: String) throws -> Phone {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let config = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let base = ButlerSyncData(container: try ModelContainer(for: ButlerStore.schema, configurations: [config]),
            notes: try LocalMemoryStore(file: dir.appendingPathComponent("notes.json")),
            tasks: ReminderStore(file: dir.appendingPathComponent("tasks.json"), schedules: false),
            revisionFile: dir.appendingPathComponent("revision.json"))
        let household = HouseholdStore(directory: dir.appendingPathComponent("household"))
        let state = HouseholdState(id: UUID(), name: "我们家", role: role, zoneName: "z", zoneOwner: "o", me: me, joinedAt: .now)
        household.begin(state, me: HouseholdMember(id: me, name: name, isOwner: role == .owner, joinedAt: .now))
        base.householdProducts = { household.householdProducts(container: base.container) }
        let sync = SyncStore(file: dir.appendingPathComponent("household.json"),
                             local: HouseholdSyncData(base: base, store: household), transport: cloud, kinds: [.inventory, .member])
        return Phone(base: base, household: household, sync: sync)
    }

    @discardableResult
    private func add(_ name: String, quantity: Int = 2, to phone: Phone) throws -> (product: UUID, lot: UUID) {
        let context = ModelContext(phone.container)
        let product = CatalogProduct(canonicalName: name)
        let lot = InventoryLot(productID: product.id, quantity: quantity, unit: "个")
        context.insert(product); context.insert(lot)
        try context.save()
        return (product.id, lot.id)
    }

    private func names(_ phone: Phone) throws -> Set<String> {
        Set(try ModelContext(phone.container).fetch(FetchDescriptor<CatalogProduct>()).map(\.canonicalName))
    }

    private func quantity(_ lot: UUID, _ phone: Phone) throws -> Int? {
        try ModelContext(phone.container).fetch(FetchDescriptor<InventoryLot>()).first { $0.id == lot }?.quantity
    }

    func testTheButlerSortsWhatIsFamilyAndWhatIsPersonal() {
        XCTAssertEqual(HouseholdClassifier.scope(name: "降压药", category: .medicine, isMedicine: true), .personal)
        XCTAssertEqual(HouseholdClassifier.scope(name: "给老婆的生日礼物", category: .other, isMedicine: false), .personal)
        XCTAssertEqual(HouseholdClassifier.scope(name: "雅诗兰黛面霜", category: .household, isMedicine: false), .personal)
        XCTAssertEqual(HouseholdClassifier.scope(name: "感冒灵", category: .medicine, isMedicine: true), .household, "the family's cold medicine is shared")
        XCTAssertEqual(HouseholdClassifier.scope(name: "牛奶", category: .food, isMedicine: false), .household)
    }

    func testSharedThingsReachTheFamilyWithWhoRecordedThemAndPersonalOnesStay() async throws {
        let cloud = FakeSyncCloud()
        let mine = try phone(cloud, me: owner, role: .owner, name: "老公")
        let theirs = try phone(cloud, me: member, role: .member, name: "老婆")
        let milk = try add("牛奶", to: mine)
        try add("降压药", to: mine)
        try await mine.sync.setEnabled(true); try await mine.sync.synchronize()
        try await theirs.sync.setEnabled(true); try await theirs.sync.synchronize(); try await mine.sync.synchronize()

        XCTAssertEqual(try names(theirs), ["牛奶"], "the personal medicine never leaves the owner's phone")
        XCTAssertEqual(theirs.household.sharing[milk.product]?.recordedBy, owner)
        XCTAssertEqual(Set(theirs.household.members.map(\.name)), ["老公", "老婆"])
        XCTAssertEqual(Set(mine.household.members.map(\.name)), ["老公", "老婆"])
    }

    func testEitherPersonCanChangeAThingAndTheOtherSeesIt() async throws {
        let cloud = FakeSyncCloud()
        let mine = try phone(cloud, me: owner, role: .owner, name: "老公")
        let theirs = try phone(cloud, me: member, role: .member, name: "老婆")
        let milk = try add("牛奶", quantity: 3, to: mine)
        try await mine.sync.setEnabled(true); try await mine.sync.synchronize()
        try await theirs.sync.setEnabled(true); try await theirs.sync.synchronize()

        let context = ModelContext(theirs.container)
        let lot = try XCTUnwrap(context.fetch(FetchDescriptor<InventoryLot>()).first { $0.id == milk.lot })
        lot.quantity = 1
        try context.save()
        try await theirs.sync.synchronize(); try await mine.sync.synchronize()
        XCTAssertEqual(try quantity(milk.lot, mine), 1)
    }

    func testMakingAThingPersonalTakesItOffTheOtherPhonesAndOutOfTheHousehold() async throws {
        let cloud = FakeSyncCloud()
        let mine = try phone(cloud, me: owner, role: .owner, name: "老公")
        let theirs = try phone(cloud, me: member, role: .member, name: "老婆")
        let gift = try add("香槟", to: mine)
        try await mine.sync.setEnabled(true); try await mine.sync.synchronize()
        try await theirs.sync.setEnabled(true); try await theirs.sync.synchronize()
        XCTAssertTrue(try names(theirs).contains("香槟"))

        mine.household.setSharing(ItemSharing(scope: .personal, recordedBy: owner), for: gift.product)
        XCTAssertFalse(mine.base.householdProducts().contains(gift.product))
        XCTAssertNotNil(try mine.base.snapshot()[.init(kind: .inventory, id: gift.product)], "now this person's own sync carries it")
        try await mine.sync.synchronize(); try await theirs.sync.synchronize()
        XCTAssertFalse(try names(theirs).contains("香槟"))
        XCTAssertTrue(try names(mine).contains("香槟"), "the owner keeps it")
    }

    func testAPresentHiddenFromSomeoneIsNotShownToThem() async throws {
        let cloud = FakeSyncCloud()
        let mine = try phone(cloud, me: owner, role: .owner, name: "老公")
        let theirs = try phone(cloud, me: member, role: .member, name: "老婆")
        let flowers = try add("花束", to: mine)
        try await mine.sync.setEnabled(true); try await mine.sync.synchronize()
        try await theirs.sync.setEnabled(true); try await theirs.sync.synchronize()
        mine.household.setSharing(ItemSharing(scope: .household, hiddenFrom: [member], recordedBy: owner), for: flowers.product)
        try await mine.sync.synchronize(); try await theirs.sync.synchronize()

        XCTAssertFalse(theirs.household.isVisible(flowers.product))
        XCTAssertTrue(mine.household.isVisible(flowers.product))
    }

    func testThisDevicesOwnSyncLeavesSharedThingsToTheHousehold() async throws {
        let cloud = FakeSyncCloud()
        let mine = try phone(cloud, me: owner, role: .owner, name: "老公")
        let milk = try add("牛奶", to: mine)
        let pills = try add("降压药", to: mine)
        let own = try mine.base.snapshot()
        XCTAssertNil(own[.init(kind: .inventory, id: milk.product)])
        XCTAssertNotNil(own[.init(kind: .inventory, id: pills.product)])
        // A late copy of a shared thing arriving through the person's own sync does not overwrite it.
        XCTAssertNoThrow(try mine.base.replace(.init(kind: .inventory, id: milk.product), expected: Data("old".utf8), with: nil))
        XCTAssertTrue(try names(mine).contains("牛奶"))
    }

    func testLeavingKeepsEverythingAsTheirOwn() async throws {
        let cloud = FakeSyncCloud()
        let mine = try phone(cloud, me: owner, role: .owner, name: "老公")
        let milk = try add("牛奶", to: mine)
        XCTAssertNil(try mine.base.snapshot()[.init(kind: .inventory, id: milk.product)])
        mine.household.end()
        XCTAssertNotNil(try mine.base.snapshot()[.init(kind: .inventory, id: milk.product)], "back in this person's own sync")
        XCTAssertTrue(try names(mine).contains("牛奶"))
    }

    func testMemberIDIsTheSameOnEveryDeviceOfOnePerson() {
        XCTAssertEqual(HouseholdMember.id(forUser: "_abc"), HouseholdMember.id(forUser: "_abc"))
        XCTAssertNotEqual(HouseholdMember.id(forUser: "_abc"), HouseholdMember.id(forUser: "_abd"))
    }
}
