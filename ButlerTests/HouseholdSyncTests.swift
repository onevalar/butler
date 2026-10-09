import Foundation
import SwiftData
import XCTest
@testable import Butler

/// Two phones in one household, over a fake CloudKit zone.
@MainActor final class HouseholdSyncTests: XCTestCase {
    final class Said { var lines: [String] = [] }

    struct Phone {
        let base: ButlerSyncData
        let household: HouseholdStore
        let sync: SyncStore
        let said: Said
        var container: ModelContainer { base.container }
        var tasks: ReminderStore { base.tasks }
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
        HouseholdService.wire(base, household)
        let said = Said()
        let local = HouseholdSyncData(base: base, store: household)
        local.announce = { title, body, _ in said.lines.append("\(title)：\(body)") }
        let sync = SyncStore(file: dir.appendingPathComponent("household.json"),
                             local: local, transport: cloud, kinds: HouseholdService.kinds)
        return Phone(base: base, household: household, sync: sync, said: said)
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

    // MARK: Tasks

    private func pair() async throws -> (FakeSyncCloud, Phone, Phone) {
        let cloud = FakeSyncCloud()
        let mine = try phone(cloud, me: owner, role: .owner, name: "老公")
        let theirs = try phone(cloud, me: member, role: .member, name: "老婆")
        try await mine.sync.setEnabled(true); try await mine.sync.synchronize()
        try await theirs.sync.setEnabled(true); try await theirs.sync.synchronize(); try await mine.sync.synchronize()
        return (cloud, mine, theirs)
    }

    private func roundTrip(_ from: Phone, _ to: Phone) async throws {
        try await from.sync.synchronize(); try await to.sync.synchronize()
    }

    private func task(_ text: String, _ sharing: TaskSharing?) -> TimedReminder {
        var value = TimedReminder(text: text, fireDate: .now.addingTimeInterval(3600 * 5))
        value.sharing = sharing
        return value
    }

    func testAnAssignedTaskReachesThatPersonAndOnlyTheirPhoneReminds() async throws {
        let (_, mine, theirs) = try await pair()
        let bills = task("交水费", TaskSharing(scope: .household, createdBy: owner, assignee: member))
        try mine.tasks.add(bills)
        try mine.tasks.add(task("体检", TaskSharing(scope: .personal, createdBy: owner)))
        try await roundTrip(mine, theirs)

        XCTAssertEqual(theirs.tasks.reminders.map(\.text), ["交水费"], "the private check-up stays on the owner's phone")
        let received = try XCTUnwrap(theirs.tasks.reminder(id: bills.id))
        XCTAssertTrue(theirs.tasks.remindsHere(received), "the person responsible is reminded")
        XCTAssertFalse(mine.tasks.remindsHere(try XCTUnwrap(mine.tasks.reminder(id: bills.id))), "the one who gave it is not")
        XCTAssertEqual(theirs.said.lines, ["老公交给你一件事：交水费 · \(received.whenLabel)"])
        XCTAssertEqual(theirs.household.names.rowLabel(received.sharing), "老公交给你")
        XCTAssertEqual(mine.household.names.rowLabel(bills.sharing), "交给老婆")
    }

    func testFinishingIsRecordedWithWhoAndTheCreatorIsTold() async throws {
        let (_, mine, theirs) = try await pair()
        let bills = task("交水费", TaskSharing(scope: .household, createdBy: owner, assignee: member))
        try mine.tasks.add(bills)
        try await roundTrip(mine, theirs)
        try theirs.tasks.complete(bills.id)
        try await roundTrip(theirs, mine)

        let done = try XCTUnwrap(mine.tasks.reminder(id: bills.id))
        XCTAssertEqual(done.status, .completed, "it is not removed, it is finished")
        XCTAssertEqual(mine.household.names.completedBy(done), "老婆完成")
        XCTAssertEqual(mine.said.lines, ["老婆完成了：交水费"])
        XCTAssertNil(theirs.household.names.completedBy(try XCTUnwrap(theirs.tasks.reminder(id: bills.id))), "not said about oneself")

        // Anyone who can see it can reopen it, and that is recorded too.
        try mine.tasks.reopen(bills.id)
        try await roundTrip(mine, theirs)
        let reopened = try XCTUnwrap(theirs.tasks.reminder(id: bills.id))
        XCTAssertEqual(reopened.status, .active)
        XCTAssertEqual(reopened.activity.last?.by, owner)
    }

    func testATaskHiddenFromSomeoneNeverReachesTheirListsAndComesBackWhenShown() async throws {
        let (_, mine, theirs) = try await pair()
        let surprise = task("订生日蛋糕", TaskSharing(scope: .household, hiddenFrom: [member], createdBy: owner))
        try mine.tasks.add(surprise)
        try await roundTrip(mine, theirs)
        XCTAssertNil(theirs.tasks.reminder(id: surprise.id))
        XCTAssertNotNil(theirs.household.hiddenTasks[surprise.id], "kept aside so syncing does not delete it")
        try await theirs.sync.synchronize(); try await mine.sync.synchronize()
        XCTAssertNotNil(mine.tasks.reminder(id: surprise.id), "the other phone's sync did not remove it")

        try mine.tasks.setSharing(surprise.id, TaskSharing(scope: .household, createdBy: owner), detail: "改为全家可见")
        try await roundTrip(mine, theirs)
        XCTAssertNotNil(theirs.tasks.reminder(id: surprise.id))
        XCTAssertNil(theirs.household.hiddenTasks[surprise.id])
    }

    func testMakingATaskPersonalTakesItOffTheOtherPhoneAndIntoTheOwnSync() async throws {
        let (_, mine, theirs) = try await pair()
        let shopping = task("周六买菜", TaskSharing(scope: .household, createdBy: owner))
        try mine.tasks.add(shopping)
        XCTAssertNil(try mine.base.snapshot()[.init(kind: .task, id: shopping.id)], "own sync leaves shared tasks to the household")
        try await roundTrip(mine, theirs)
        XCTAssertNotNil(theirs.tasks.reminder(id: shopping.id))

        try mine.tasks.setSharing(shopping.id, TaskSharing(scope: .personal, createdBy: owner), detail: "改为只有老公")
        try await roundTrip(mine, theirs)
        XCTAssertNil(theirs.tasks.reminder(id: shopping.id))
        XCTAssertNotNil(try mine.base.snapshot()[.init(kind: .task, id: shopping.id)])
    }

    func testWhoIsResponsibleAndRemindedCannotBeLeftOutOfWhoCanSee() {
        let given = TaskSharing(scope: .personal, createdBy: owner, assignee: member).normalized()
        XCTAssertEqual(given.scope, .people)
        XCTAssertTrue(given.canSee(member))
        XCTAssertEqual(given.reminded, [member])
        let hidden = TaskSharing(scope: .household, hiddenFrom: [member], createdBy: owner, notify: [member]).normalized()
        XCTAssertTrue(hidden.hiddenFrom.isEmpty, "someone reminded can see it")
        XCTAssertEqual(TaskSharing(scope: .household, createdBy: owner).reminded, [owner], "nobody responsible: the one who wrote it down")
    }

    func testTheCardLineSaysTheDecisionInOneLine() {
        let names = HouseholdNames(me: owner, names: [owner: "老公", member: "老婆"])
        XCTAssertEqual(names.summary(TaskSharing(scope: .household, createdBy: owner, assignee: member)), "全家可见 · 交给老婆")
        XCTAssertEqual(names.summary(TaskSharing(scope: .personal, createdBy: owner)), "只有你")
        XCTAssertEqual(names.summary(TaskSharing(scope: .household, hiddenFrom: [member], createdBy: owner)), "全家可见，不给老婆看")
        XCTAssertEqual(names.summary(TaskSharing(scope: .household, createdBy: owner, notify: [owner, member])), "全家可见 · 提醒你、老婆")
        XCTAssertEqual(names.thirdPerson.summary(TaskSharing(scope: .people, people: [member], createdBy: owner, assignee: member)),
                       "老公、老婆可见 · 交给老婆", "records read the same on every phone")
    }

    func testTheDiaryTellsWhatTheFamilyDid() {
        let names = HouseholdNames(me: owner, names: [owner: "老公", member: "老婆"])
        var bills = task("交水费", TaskSharing(scope: .household, createdBy: owner, assignee: member))
        bills.activity = [ReminderActivity(kind: "created", detail: "创建", by: owner),
                          ReminderActivity(kind: "completed", detail: "完成", by: member)]
        let diary = DiaryDay.build(from: [], tasks: [bills], household: names)
        XCTAssertEqual(diary.first?.family, ["老婆完成了 交水费"])
        XCTAssertEqual(diary.first?.headline, "家里：家人完成了 1 件事")
    }
}
