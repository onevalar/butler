import Foundation
import XCTest
@testable import Butler

@MainActor final class TaskDisplayStoreTests: XCTestCase {
    private final class Device: TaskDisplayDevice {
        var enabled = true
        var activities: [SystemTaskDisplay] = []
        var starts = 0
        var ends = 0
        var failAfterStart = false
        var ignoreEnd = false
        var beforeStart: ((TaskDisplayRecord) throws -> Void)?
        func read() -> [SystemTaskDisplay] { activities }
        func start(_ record: TaskDisplayRecord) throws -> String {
            try beforeStart?(record)
            starts += 1
            let id = UUID().uuidString
            activities.append(.init(id: id, sessionID: record.id, taskID: record.taskID, active: true))
            if failAfterStart { throw TaskDisplayStore.Failure("lost receipt") }
            return id
        }
        func end(_ id: String) async {
            ends += 1
            await Task.yield()
            if !ignoreEnd { activities.removeAll { $0.id == id } }
        }
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("journal.json")
    }
    private func change(_ task: TaskDisplayTask, seconds: Double = 1700) -> TaskDisplayChange {
        .init(action: .start, taskID: task.id, expectedRevision: task.revision,
              deadline: now.addingTimeInterval(seconds), sessionID: nil)
    }

    func testJournalPrecedesRequestAndConfirmationCannotRepeat() async throws {
        let path = file(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let device = Device(), task = TaskDisplayTask(id: UUID(), revision: 3, active: true)
        let store = TaskDisplayStore(file: path, device: device), operation = UUID()
        device.beforeStart = { record in
            let journal = try JSONDecoder().decode([TaskDisplayRecord].self, from: Data(contentsOf: path))
            XCTAssertEqual(journal.first?.state, .requesting)
            XCTAssertEqual(journal.first?.id, record.id)
        }
        _ = try await store.apply(change(task), operationID: operation, tasks: { [task] }, now: now)
        _ = try await store.apply(change(task), operationID: operation, tasks: { [] }, now: now)
        do {
            _ = try await store.apply(change(task), operationID: UUID(), tasks: { [task] }, now: now)
            XCTFail("duplicate task")
        } catch {}
        XCTAssertEqual(device.starts, 1)
        XCTAssertEqual(try store.read().first?.state, .active)
    }

    func testTimeAndRevisionBoundariesAndDeniedDevice() async throws {
        let path = file(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let device = Device(), task = TaskDisplayTask(id: UUID(), revision: 3, active: true)
        let store = TaskDisplayStore(file: path, device: device)
        XCTAssertNoThrow(try store.validate(change(task, seconds: 28800), tasks: [task], now: now))
        for seconds in [0.0, -1, 28801] {
            XCTAssertThrowsError(try store.validate(change(task, seconds: seconds), tasks: [task], now: now))
        }
        XCTAssertThrowsError(try store.validate(change(task), tasks: [.init(id: task.id, revision: 4, active: true)], now: now))
        XCTAssertThrowsError(try store.validate(change(task), tasks: [.init(id: task.id, revision: 3, active: false)], now: now))
        let bounded = TaskDisplayTask(id: task.id, revision: 3, active: true, automaticEnd: now.addingTimeInterval(1699))
        XCTAssertThrowsError(try store.validate(change(task), tasks: [bounded], now: now))
        XCTAssertNoThrow(try store.validate(change(task, seconds: 1699), tasks: [bounded], now: now))
        device.enabled = false
        do {
            _ = try await store.apply(change(task), operationID: UUID(), tasks: { [task] }, now: now)
            XCTFail("denied")
        } catch {}
        XCTAssertEqual(device.starts, 0)
        XCTAssertTrue(try store.read().isEmpty)
    }

    func testLostReceiptRecoversAndDismissalNeverRestarts() async throws {
        let path = file(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let device = Device(), task = TaskDisplayTask(id: UUID(), revision: 3, active: true)
        let store = TaskDisplayStore(file: path, device: device)
        device.failAfterStart = true
        do {
            _ = try await store.apply(change(task), operationID: UUID(), tasks: { [task] }, now: now)
            XCTFail("lost receipt")
        } catch {}
        XCTAssertEqual(try store.read().first?.state, .requesting)
        let recovered = TaskDisplayStore(file: path, device: device)
        try await recovered.reconcile(tasks: [task], now: now)
        XCTAssertEqual(try recovered.read().first?.state, .active)
        let delayed = device.activities
        device.activities = []
        try await recovered.reconcile(tasks: [task], now: now)
        XCTAssertEqual(try recovered.read().first?.state, .ended)
        device.activities = delayed // A delayed system appearance must also be closed.
        try await recovered.reconcile(tasks: [task], now: now)
        XCTAssertTrue(device.activities.isEmpty)
        XCTAssertEqual(device.starts, 1)
    }

    func testRevisionChangeAndExpiryEndRatherThanRestart() async throws {
        for revised in [false, true] {
            let path = file(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
            let device = Device(), task = TaskDisplayTask(id: UUID(), revision: 3, active: true)
            let store = TaskDisplayStore(file: path, device: device)
            _ = try await store.apply(change(task), operationID: UUID(), tasks: { [task] }, now: now)
            let current = TaskDisplayTask(id: task.id, revision: revised ? 5 : 3, active: true)
            try await store.reconcile(tasks: [current], now: revised ? now : now.addingTimeInterval(1700))
            try await store.reconcile(tasks: [current], now: now)
            XCTAssertTrue(device.activities.isEmpty)
            XCTAssertEqual(device.starts, 1)
            XCTAssertEqual(device.ends, 1)
        }
    }

    func testEndSurvivesFailureAndDoesNotNeedReadableTask() async throws {
        let path = file(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let device = Device(), task = TaskDisplayTask(id: UUID(), revision: 3, active: true)
        let store = TaskDisplayStore(file: path, device: device), operation = UUID()
        _ = try await store.apply(change(task), operationID: operation, tasks: { [task] }, now: now)
        device.ignoreEnd = true
        do {
            _ = try await store.apply(.init(action: .end, taskID: task.id, expectedRevision: nil, deadline: nil, sessionID: operation),
                operationID: UUID(), tasks: { XCTFail("end must not read tasks"); return [] }, now: now)
            XCTFail("end not accepted")
        } catch {}
        XCTAssertEqual(try store.read().first?.state, .ending)
        device.ignoreEnd = false
        let recovered = TaskDisplayStore(file: path, device: device)
        try await recovered.reconcile(tasks: [task], now: now)
        XCTAssertEqual(try recovered.read().first?.state, .ended)
        XCTAssertTrue(device.activities.isEmpty)
        XCTAssertEqual(device.starts, 1)
    }

    func testCorruptAndUnwritableJournalsCannotStart() async throws {
        let path = file(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("broken journal".utf8)
        try original.write(to: path)
        let device = Device(), task = TaskDisplayTask(id: UUID(), revision: 3, active: true)
        for url in [path, path.appendingPathComponent("not-a-directory.json")] {
            let store = TaskDisplayStore(file: url, device: device)
            do {
                _ = try await store.apply(change(task), operationID: UUID(), tasks: { [task] }, now: now)
                XCTFail("bad storage")
            } catch {}
        }
        XCTAssertEqual(device.starts, 0)
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testConcurrentRecoveryCannotDoubleEnd() async throws {
        let path = file(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let device = Device(), task = TaskDisplayTask(id: UUID(), revision: 3, active: true)
        let store = TaskDisplayStore(file: path, device: device)
        _ = try await store.apply(change(task), operationID: UUID(), tasks: { [task] }, now: now)
        async let first: Void = store.reconcile(tasks: [], now: now)
        async let second: Void = store.reconcile(tasks: [], now: now)
        _ = try? await first
        _ = try? await second
        XCTAssertEqual(device.ends, 1)
        XCTAssertTrue(device.activities.isEmpty)
    }
}
