import Foundation
import XCTest
@testable import Butler

@MainActor final class FakeHomeDevice: HomeDevice {
    static func control(_ kind: HomeControl.Kind = .power, step: Double? = nil) -> HomeControl {
        .init(id: UUID(), accessoryID: UUID(), room: "客厅", accessory: "灯", service: "服务", kind: kind,
            writable: true, risky: false, reachable: true, value: nil, minimum: nil, maximum: nil, step: step)
    }
    var live = HomeSnapshot(id: UUID(), name: "家", rooms: ["客厅"], controls: [control()], scenes: [])
    var connects = 0, snapshots = 0, reads = 0, writes = 0
    var beforeWrite: (() throws -> Void)?
    var throwAfterWrite = false
    var mismatch = false
    var values: [UUID: Double] = [:]
    var pause = false
    var suspended: CheckedContinuation<Void, Never>?
    func connect() async throws { connects += 1 }
    func disconnect() {}
    func homes() throws -> [(UUID, String)] { [(live.id, live.name)] }
    func snapshot(_ id: UUID) async throws -> HomeSnapshot {
        snapshots += 1
        if pause { await withCheckedContinuation { suspended = $0 } }
        return live
    }
    func write(homeID: UUID, action: HomeAction) async throws {
        try beforeWrite?(); writes += 1; values[action.control.id] = action.target
        if throwAfterWrite { throw HomeFailure("lost reply") }
    }
    func read(homeID: UUID, controlID: UUID) async throws -> Double? {
        reads += 1; return mismatch ? -1 : values[controlID]
    }
}

@MainActor final class HomeStoreTests: XCTestCase {
    private func setup() throws -> (HomeStore, FakeHomeDevice, URL) {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("home.json"), device = FakeHomeDevice()
        return (HomeStore(file: file, device: device), device, file)
    }
    private func allow(_ store: HomeStore) async throws {
        _ = try await store.apply(.access(true), operationID: UUID(), soleConfirmation: true)
    }
    private func plan(_ device: FakeHomeDevice, scene: UUID? = nil) throws -> HomePlan {
        try HomeStore.plan(device.live, controlID: scene == nil ? device.live.controls[0].id : nil,
            target: scene == nil ? 1 : nil, sceneID: scene)
    }
    private func fails(_ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected rejection") } catch {}
    }
    func testConsentBlocksAccessAndReopenRequiresConsent() async throws {
        let (store, device, file) = try setup()
        XCTAssertThrowsError(try store.homes())
        await fails { _ = try await store.snapshot(device.live.id) }
        XCTAssertEqual(device.connects, 0); XCTAssertEqual(device.snapshots, 0)
        try await allow(store)
        XCTAssertEqual(try store.homes().count, 1)
        let reopened = HomeStore(file: file, device: device)
        XCTAssertThrowsError(try reopened.homes())
        _ = try await store.apply(.access(false), operationID: UUID(), soleConfirmation: true)
        await fails { _ = try await store.read(homeID: device.live.id, controlID: device.live.controls[0].id) }
        XCTAssertEqual(device.reads, 0)
    }
    func testRiskDerivedFromKindAndMixedOrUnsupportedScenesReject() async throws {
        let (store, device, _) = try setup(); try await allow(store)
        let lock = FakeHomeDevice.control(.lock), light = device.live.controls[0], sceneID = UUID()
        let mixed = HomeScene(id: sceneID, name: "出门", actions: [.init(control: lock, target: 0), .init(control: light, target: 0)], unsupportedActions: 0)
        device.live = .init(id: device.live.id, name: "家", rooms: [], controls: [lock], scenes: [mixed])
        XCTAssertThrowsError(try plan(device, scene: sceneID))
        let risky = try plan(device)
        XCTAssertTrue(risky.risky) // Even if the adapter mistakenly marks risky=false.
        await fails { _ = try await store.apply(.execute(risky), operationID: UUID(), soleConfirmation: false) }
        XCTAssertEqual(device.writes, 0)
        _ = try await store.apply(.execute(risky), operationID: UUID(), soleConfirmation: true)
        XCTAssertEqual(device.writes, 1)
        let unknown = HomeScene(id: sceneID, name: "未知", actions: [.init(control: light, target: 1)], unsupportedActions: 1)
        device.live = .init(id: device.live.id, name: "家", rooms: [], controls: [light], scenes: [unknown])
        XCTAssertThrowsError(try plan(device, scene: sceneID))
    }
    func testChangedHomeOrSceneStopsBeforeWrite() async throws {
        let (store, device, _) = try setup(); try await allow(store)
        let old = try plan(device), sceneID = UUID(), control = device.live.controls[0]
        device.live = .init(id: device.live.id, name: "新家名", rooms: [], controls: [control], scenes: [])
        await fails { _ = try await store.apply(.execute(old), operationID: UUID(), soleConfirmation: true) }
        device.live = .init(id: device.live.id, name: "家", rooms: [], controls: [control], scenes: [
            .init(id: sceneID, name: "晚上", actions: [.init(control: control, target: 0)], unsupportedActions: 0)])
        let scene = try plan(device, scene: sceneID)
        device.live = .init(id: device.live.id, name: "家", rooms: [], controls: [control], scenes: [
            .init(id: sceneID, name: "晚上", actions: [.init(control: control, target: 1)], unsupportedActions: 0)])
        await fails { _ = try await store.apply(.execute(scene), operationID: UUID(), soleConfirmation: true) }
        XCTAssertEqual(device.writes, 0)
    }
    func testJournalBeforeEffectAndLostReplyNeverRepeatsAfterReopen() async throws {
        let (store, device, file) = try setup(); try await allow(store)
        let proposal = try plan(device), id = UUID()
        device.beforeWrite = {
            let disk = try JSONDecoder().decode([HomeStore.Operation].self, from: Data(contentsOf: file))
            XCTAssertEqual(disk.first?.id, id); XCTAssertEqual(disk.first?.attempted, 1)
            XCTAssertEqual(disk.first?.matched, 0)
        }
        device.throwAfterWrite = true
        await fails { _ = try await store.apply(.execute(proposal), operationID: id, soleConfirmation: true) }
        let reopened = HomeStore(file: file, device: device); try await allow(reopened)
        _ = try await reopened.apply(.execute(proposal), operationID: id, soleConfirmation: true)
        XCTAssertEqual(device.writes, 1)
        XCTAssertEqual(try reopened.operations().first?.finished, false)
    }
    func testReadbackMismatchStopsRemainingSceneActions() async throws {
        let (store, device, _) = try setup(); try await allow(store)
        let a = device.live.controls[0], b = FakeHomeDevice.control(), sceneID = UUID()
        device.live = .init(id: device.live.id, name: "家", rooms: [], controls: [a, b], scenes: [
            .init(id: sceneID, name: "两灯", actions: [.init(control: a, target: 1), .init(control: b, target: 0)], unsupportedActions: 0)])
        device.mismatch = true
        await fails { _ = try await store.apply(.execute(try plan(device, scene: sceneID)), operationID: UUID(), soleConfirmation: true) }
        XCTAssertEqual(device.writes, 1); XCTAssertEqual(device.reads, 1)
        XCTAssertEqual(try store.operations().first?.matched, 0)
    }
    func testSceneChangedAfterFirstWriteStopsAndKeepsPartialReceipt() async throws {
        let (store, device, _) = try setup(); try await allow(store)
        let a = device.live.controls[0], b = FakeHomeDevice.control(), sceneID = UUID()
        device.live = .init(id: device.live.id, name: "家", rooms: [], controls: [a, b], scenes: [
            .init(id: sceneID, name: "两灯", actions: [.init(control: a, target: 1), .init(control: b, target: 0)], unsupportedActions: 0)])
        let original = try plan(device, scene: sceneID)
        device.beforeWrite = {
            device.live = .init(id: device.live.id, name: "家", rooms: [], controls: [a, b], scenes: [
                .init(id: sceneID, name: "两灯", actions: [.init(control: a, target: 1), .init(control: b, target: 1)], unsupportedActions: 0)])
        }
        await fails { _ = try await store.apply(.execute(original), operationID: UUID(), soleConfirmation: true) }
        XCTAssertEqual(device.writes, 1)
        XCTAssertNil(device.values[b.id])
        XCTAssertEqual(try store.operations().first?.matched, 1)
        XCTAssertEqual(try store.operations().first?.finished, false)
        device.beforeWrite = nil
    }
    func testRevokeDuringSnapshotDropsResultAndBlocksWrite() async throws {
        let (store, device, _) = try setup(); try await allow(store)
        let proposal = try plan(device); device.pause = true
        let task = Task { try await store.apply(.execute(proposal), operationID: UUID(), soleConfirmation: true) }
        while device.suspended == nil { await Task.yield() }
        await fails { _ = try await store.apply(.execute(proposal), operationID: UUID(), soleConfirmation: true) }
        _ = try await store.apply(.access(false), operationID: UUID(), soleConfirmation: true)
        device.suspended?.resume(); device.suspended = nil
        await fails { _ = try await task.value }
        XCTAssertEqual(device.writes, 0)
        try await allow(store)
        let query = Task { try await store.snapshot(device.live.id) }
        while device.suspended == nil { await Task.yield() }
        _ = try await store.apply(.access(false), operationID: UUID(), soleConfirmation: true)
        device.suspended?.resume(); device.suspended = nil
        await fails { _ = try await query.value }
    }
    func testCancelledOrCorruptStorageNeverWrites() async throws {
        let (store, device, file) = try setup(); try await allow(store)
        device.pause = true; let proposal = try plan(device)
        let task = Task { try await store.apply(.execute(proposal), operationID: UUID(), soleConfirmation: true) }
        while device.suspended == nil { await Task.yield() }
        task.cancel(); device.suspended?.resume(); device.suspended = nil
        await fails { _ = try await task.value }
        try Data("broken".utf8).write(to: file)
        let broken = HomeStore(file: file, device: device)
        await fails { try await allow(broken) }
        XCTAssertEqual(device.writes, 0)
    }
    func testRangesReadOnlyAndDuplicateActions() throws {
        let brightness = FakeHomeDevice.control(.brightness, step: 5)
        try brightness.validate(35)
        XCTAssertThrowsError(try brightness.validate(37))
        XCTAssertThrowsError(try brightness.validate(105))
        XCTAssertThrowsError(try brightness.validate(.nan))
        XCTAssertThrowsError(try FakeHomeDevice.control(.currentDoor).validate(0))
        XCTAssertThrowsError(try FakeHomeDevice.control(.security).validate(4))
        let duplicate = HomePlan(homeID: UUID(), homeName: "家", sceneID: UUID(), sceneName: "重复",
            actions: [.init(control: brightness, target: 35), .init(control: brightness, target: 50)])
        XCTAssertThrowsError(try duplicate.validate())
    }
}
