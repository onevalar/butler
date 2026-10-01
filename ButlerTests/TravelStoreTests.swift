import Foundation
import XCTest
@testable import Butler

@MainActor final class FakeTravelDevice: TravelDevice {
    var result = TravelPoint(name: "住宅", address: "测试路73号", latitude: 31.1234567, longitude: 121.7654321, timeZone: "Asia/Shanghai")
    var searches = 0, fixes = 0, grants = 0, schedules = 0, opens = 0, cancels = 0
    var denied = false, loseReply = false, failCancel = false, pause = false
    var suspended: CheckedContinuation<Void, Never>?
    var beforeSchedule: (() throws -> Void)?
    var pending: [UUID: PlaceReminder] = [:]
    var delivered: Set<UUID> = []
    func search(_ query: String, near: TravelPoint?) async throws -> [TravelPoint] {
        searches += 1
        if pause { await withCheckedContinuation { suspended = $0 } }
        return [result]
    }
    func current() async throws -> TravelPoint { fixes += 1; var p = result; p.measuredAt = .now; return p }
    func route(from: TravelPoint, to: TravelPoint, mode: TravelMode, departure: Date) async throws -> TravelRoute {
        .init(origin: from, destination: to, mode: mode, departure: departure, arrival: departure.addingTimeInterval(1337), meters: 4182, seconds: 1337, checkedAt: .now)
    }
    func authorizeReminder() async throws {
        grants += 1
        if pause { await withCheckedContinuation { suspended = $0 } }
        if denied { throw TravelFailure("denied") }
    }
    func schedule(_ reminder: PlaceReminder) async throws {
        try beforeSchedule?(); schedules += 1; pending[reminder.id] = reminder
        if loseReply { throw TravelFailure("lost") }
    }
    func status(_ reminder: PlaceReminder) async throws -> PlaceRequestState {
        if pending[reminder.id] != nil { return .scheduled }
        return delivered.contains(reminder.id) ? .delivered : .missing
    }
    func cancel(_ reminder: PlaceReminder) async throws {
        cancels += 1
        if failCancel { throw TravelFailure("cancel failed") }
        pending.removeValue(forKey: reminder.id); delivered.remove(reminder.id)
    }
    func navigate(_ route: TravelRoute) async throws { opens += 1 }
}

@MainActor final class TravelStoreTests: XCTestCase {
    private func setup() throws -> (TravelStore, FakeTravelDevice, URL) {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let device = FakeTravelDevice(), file = dir.appendingPathComponent("places.json")
        return (TravelStore(file: file, device: device), device, file)
    }
    private func allow(_ store: TravelStore) async throws { _ = try await store.apply(.access(true), operationID: UUID()) }
    private func home(_ store: TravelStore, _ device: FakeTravelDevice) async throws -> SavedPlace {
        try await allow(store)
        let results = try await store.search("测试路73号", near: nil)
        let proposal = try store.saveProposal(alias: "家", candidateID: results[0].id, existingID: nil)
        _ = try await store.apply(proposal, operationID: UUID())
        return try XCTUnwrap(store.places().first)
    }
    private func reminder(_ p: SavedPlace, repeats: Bool = false, text: String = "把肉放进冰箱") -> TravelChange {
        .remind(place: p, text: text, radius: 230, repeats: repeats)
    }
    private func fails(_ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected refusal") } catch {}
    }
    func testConsentAndCurrentLocationNeverImplicitlyMarkHome() async throws {
        let (store, device, _) = try setup()
        await fails { _ = try await store.search("家", near: nil) }
        XCTAssertEqual(device.searches, 0); XCTAssertEqual(device.fixes, 0)
        try await allow(store)
        XCTAssertEqual(device.grants, 0)
        let id = UUID(); _ = try await store.apply(.current, operationID: id)
        _ = try await store.apply(.current, operationID: id)
        XCTAssertEqual(device.fixes, 1); XCTAssertTrue(try store.places().isEmpty)
        XCTAssertEqual(device.schedules, 0)
        XCTAssertThrowsError(try store.place(UUID()))
    }
    func testSavedHomeSurvivesRelaunchWithoutLocationOrNotificationPermission() async throws {
        let (store, device, file) = try setup(); let p = try await home(store, device)
        XCTAssertEqual(device.fixes, 0); XCTAssertEqual(device.grants, 0)
        let reopened = TravelStore(file: file, device: device)
        XCTAssertThrowsError(try reopened.places())
        try await allow(reopened)
        XCTAssertEqual(try reopened.place(p.id), p)
        XCTAssertEqual(device.schedules, 0)
    }
    func testJournalBeforeScheduleAndReopenNeverRearmsLostReply() async throws {
        let (store, device, file) = try setup(); let p = try await home(store, device), id = UUID()
        device.beforeSchedule = {
            let disk = try JSONDecoder().decode(TravelStore.Records.self, from: Data(contentsOf: file))
            XCTAssertEqual(disk.reminders.first?.id, id); XCTAssertEqual(disk.reminders.first?.state, .attempting)
        }
        device.loseReply = true
        await fails { _ = try await store.apply(reminder(p), operationID: id) }
        let reopened = TravelStore(file: file, device: device); try await allow(reopened)
        _ = try await reopened.apply(reminder(p), operationID: id)
        try await reopened.refresh()
        XCTAssertEqual(device.schedules, 1)
        XCTAssertEqual(try reopened.reminders().first?.state, .scheduled)
        device.pending.removeAll(); try await reopened.refresh()
        XCTAssertEqual(try reopened.reminders().first?.state, .unknown)
        XCTAssertEqual(device.schedules, 1)
    }
    func testOnceAndRepeatingHaveDistinctRequestsAndDeliveryDoesNotCompleteTasks() async throws {
        let (store, device, _) = try setup(); let p = try await home(store, device)
        let once = UUID(), repeating = UUID()
        _ = try await store.apply(reminder(p), operationID: once)
        _ = try await store.apply(reminder(p, repeats: true, text: "洗手"), operationID: repeating)
        XCTAssertEqual(device.pending[once]?.repeats, false)
        XCTAssertEqual(device.pending[repeating]?.repeats, true)
        XCTAssertEqual(device.pending[once]?.radius, 230)
        XCTAssertEqual(device.pending[once]?.place.point.longitude, 121.7654321)
        XCTAssertTrue(device.pending[once]!.requestID.hasPrefix("butler.place."))
        device.pending.removeValue(forKey: once); device.delivered = [once, repeating]
        try await store.refresh()
        XCTAssertEqual(try store.reminders().first(where: { $0.id == once })?.state, .delivered)
        XCTAssertEqual(try store.reminders().first(where: { $0.id == repeating })?.state, .scheduled)
        XCTAssertEqual(device.schedules, 2)
    }
    func testMovingHomeIsBlockedUntilOldReminderIsCancelled() async throws {
        let (store, device, _) = try setup(); let p = try await home(store, device), id = UUID()
        _ = try await store.apply(reminder(p), operationID: id)
        let updated = TravelChange.save(alias: "新家", point: device.result, before: p)
        await fails { _ = try await store.apply(updated, operationID: UUID()) }
        await fails { _ = try await store.apply(.remove(p), operationID: UUID()) }
        _ = try await store.apply(.cancel(id), operationID: UUID())
        _ = try await store.apply(updated, operationID: UUID())
        XCTAssertEqual(try store.place(p.id).revision, 2)
        await fails { _ = try await store.apply(reminder(p), operationID: UUID()) }
        XCTAssertTrue(device.pending.isEmpty)
    }
    func testPermissionRefusalAndRevocationWhileAwaitingNeverSchedules() async throws {
        let (store, device, _) = try setup(); let p = try await home(store, device)
        device.denied = true
        await fails { _ = try await store.apply(reminder(p), operationID: UUID()) }
        XCTAssertTrue(try store.reminders().isEmpty)
        device.denied = false; device.pause = true
        let task = Task { try await store.apply(self.reminder(p), operationID: UUID()) }
        while device.suspended == nil { await Task.yield() }
        await fails { _ = try await store.apply(reminder(p), operationID: UUID()) }
        _ = try await store.apply(.access(false), operationID: UUID())
        device.suspended?.resume(); device.suspended = nil
        await fails { _ = try await task.value }
        XCTAssertEqual(device.schedules, 0)
    }
    func testClosingConversationAccessKeepsReminderButRejectsLateSearch() async throws {
        let (store, device, _) = try setup(); let p = try await home(store, device), id = UUID()
        _ = try await store.apply(reminder(p), operationID: id)
        device.pause = true
        let search = Task { try await store.search("药店", near: nil) }
        while device.suspended == nil { await Task.yield() }
        _ = try await store.apply(.access(false), operationID: UUID())
        device.suspended?.resume(); device.suspended = nil
        await fails { _ = try await search.value }
        XCTAssertNotNil(device.pending[id]); XCTAssertEqual(device.cancels, 0)
    }
    func testCancelFailureCanRetryButNeverRecreate() async throws {
        let (store, device, file) = try setup(); let p = try await home(store, device), id = UUID()
        _ = try await store.apply(reminder(p), operationID: id); device.failCancel = true
        await fails { _ = try await store.apply(.cancel(id), operationID: UUID()) }
        let reopened = TravelStore(file: file, device: device); try await allow(reopened); try await reopened.refresh()
        XCTAssertEqual(try reopened.reminders().first?.state, .cancelling)
        device.failCancel = false
        _ = try await reopened.apply(.cancel(id), operationID: UUID())
        XCTAssertTrue(device.pending.isEmpty); XCTAssertEqual(device.schedules, 1)
    }
    func testSequentialSearchesPreserveBothEndpointsAndRouteHasNoSideEffects() async throws {
        let (store, device, _) = try setup(); try await allow(store)
        let first = try await store.search("住宅", near: nil)[0]
        device.result = .init(name: "医院", address: "异地路", latitude: 35, longitude: 139, timeZone: "Asia/Tokyo")
        let second = try await store.search("医院", near: nil)[0], departure = Date.now.addingTimeInterval(100)
        let (id, route) = try await store.route(from: first.id, to: second.id, mode: .walking, departure: departure)
        XCTAssertEqual(route.origin, first); XCTAssertEqual(route.destination, second)
        XCTAssertEqual(route.arrival.timeIntervalSince(departure), 1337)
        XCTAssertEqual(device.opens, 0); XCTAssertEqual(device.schedules, 0)
        let proposal = try store.navigation(id), op = UUID()
        _ = try await store.apply(proposal, operationID: op); _ = try await store.apply(proposal, operationID: op)
        XCTAssertEqual(device.opens, 1)
    }
    func testInvalidRadiusStaleFixDuplicateAliasAndCorruptStoreFailClosed() async throws {
        let (store, device, file) = try setup(); let p = try await home(store, device)
        for radius in [99.0, 2001, .nan] {
            await fails { _ = try await store.apply(.remind(place: p, text: "关灯", radius: radius, repeats: false), operationID: UUID()) }
        }
        await fails { _ = try await store.apply(.save(alias: "家", point: device.result, before: nil), operationID: UUID()) }
        var stale = device.result; stale.measuredAt = .now.addingTimeInterval(-301)
        await fails { _ = try await store.apply(.save(alias: "旧定位", point: stale, before: nil), operationID: UUID()) }
        try Data("broken".utf8).write(to: file)
        let broken = TravelStore(file: file, device: device)
        await fails { try await allow(broken) }
        XCTAssertEqual(device.grants, 0); XCTAssertEqual(device.schedules, 0)
    }
}
