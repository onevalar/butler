import Foundation
import XCTest
@testable import Butler

@MainActor final class FakeHealthDevice: HealthDevice {
    var available = true
    var writable: Set<HealthMetric> = Set(HealthMetric.allCases.filter(\.writable))
    var grants: [(Set<HealthMetric>, Set<HealthMetric>)] = []
    var reads = 0
    var writes = 0
    var live: [HealthWriteToken] = []
    var prepared: [HealthWriteToken] = []
    var throwAfterCommit = false
    var verifyError = false
    var beforeCommit: (() throws -> Void)?
    var suspendAuthorization: CheckedContinuation<Void, Never>?
    var pauseAuthorization = false
    let secretResult = "PRIVATE-HEALTH-729.25"
    func authorize(read: Set<HealthMetric>, write: Set<HealthMetric>) async throws {
        grants.append((read, write))
        if pauseAuthorization { await withCheckedContinuation { suspendAuthorization = $0 } }
    }
    func canWrite(_ metric: HealthMetric) -> Bool { writable.contains(metric) }
    func summary(_ metrics: [HealthMetric], range: HealthRange) async throws -> String { reads += 1; return secretResult }
    func ownRecords(_ metric: HealthMetric, range: HealthRange) async throws -> String { reads += 1; return secretResult }
    func prepare(_ change: HealthChange, operationID: UUID) async throws -> HealthWriteToken {
        let token: HealthWriteToken
        switch change {
        case .create: token = .init(action: .save, sampleID: UUID(), syncID: operationID, version: 1)
        case .correct(let id, _):
            guard let old = live.first(where: { $0.sampleID == id }) else { throw HealthFailure("旧编号不存在") }
            token = .init(action: .save, sampleID: UUID(), syncID: old.syncID, version: old.version + 1)
        case .delete(let id, _):
            guard let old = live.first(where: { $0.sampleID == id }) else { throw HealthFailure("不属于本应用") }
            token = .init(action: .delete, sampleID: old.sampleID, syncID: old.syncID, version: old.version)
        default: throw HealthFailure("invalid")
        }
        prepared.append(token)
        return token
    }
    func commit(_ token: HealthWriteToken) async throws {
        try beforeCommit?()
        writes += 1
        live.removeAll { $0.syncID == token.syncID }
        if token.action == .save { live.append(token) }
        if throwAfterCommit { throw HealthFailure(secretResult) }
    }
    func discard(_ token: HealthWriteToken) { prepared.removeAll { $0 == token } }
    func verify(_ token: HealthWriteToken) async throws -> Bool {
        reads += 1
        if verifyError { throw NSError(domain: secretResult, code: 1) }
        return live.contains(token)
    }
}

@MainActor final class HealthStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var entry: HealthEntry { .init(metric: .water, value: 729.25, date: now.addingTimeInterval(-73)) }
    private func setup() throws -> (HealthStore, FakeHealthDevice, URL) {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("health.json"), device = FakeHealthDevice()
        return (HealthStore(file: file, device: device), device, file)
    }
    func testUnitConversionsAndInvalidDimensions() throws {
        XCTAssertEqual(try HealthMetric.water.canonical(0.375, unit: "L"), 375, accuracy: 0.00001)
        XCTAssertEqual(try HealthMetric.dietaryEnergy.canonical(836.8, unit: "kJ"), 200, accuracy: 0.00001)
        XCTAssertEqual(try HealthMetric.protein.canonical(1730, unit: "mg"), 1.73, accuracy: 0.00001)
        XCTAssertEqual(try HealthMetric.fat.canonical(17.3, unit: "g"), 17.3)
        for unit in ["g", "杯", "kcal", "ml"] { XCTAssertThrowsError(try HealthMetric.water.canonical(10, unit: unit)) }
        for value in [0.0, -1, .infinity, .nan] { XCTAssertThrowsError(try HealthMetric.water.canonical(value, unit: "mL")) }
        XCTAssertThrowsError(try HealthEntry(metric: .steps, value: 10, date: now).validate(now: now))
        XCTAssertThrowsError(try HealthEntry(metric: .water, value: 10, date: now.addingTimeInterval(1)).validate(now: now))
    }
    func testRangeBoundariesAndNoPermissionBeforeConfirmation() throws {
        let (store, device, _) = try setup()
        XCTAssertTrue(store.available)
        XCTAssertTrue(try store.receipts().isEmpty)
        XCTAssertTrue(device.grants.isEmpty)
        let range = HealthRange(start: now.addingTimeInterval(-31 * 86400), end: now)
        XCTAssertNoThrow(try HealthChange.summary([.steps], range).validate(now: now))
        XCTAssertThrowsError(try HealthChange.summary([.steps, .steps], range).validate(now: now))
        XCTAssertThrowsError(try HealthRange(start: now.addingTimeInterval(-31 * 86400 - 1), end: now).validate(now: now))
        XCTAssertThrowsError(try HealthRange(start: now, end: now).validate(now: now))
        XCTAssertThrowsError(try HealthRange(start: now.addingTimeInterval(-1), end: now.addingTimeInterval(1)).validate(now: now))
    }
    func testReadIsOneShotAndResultNeverEntersReceiptOrDisk() async throws {
        let (store, device, file) = try setup(), id = UUID()
        let change = HealthChange.summary([.steps, .activeEnergy], .init(start: now.addingTimeInterval(-1700), end: now))
        let result = try await store.apply(change, operationID: id, now: now)
        XCTAssertEqual(result.localText, device.secretResult)
        XCTAssertFalse(result.receipt.contains(device.secretResult))
        let second = try await store.apply(change, operationID: id, now: now)
        XCTAssertNil(second.localText)
        XCTAssertEqual(device.reads, 1)
        XCTAssertEqual(device.grants.first?.0, [.steps, .activeEnergy])
        XCTAssertEqual(device.grants.first?.1, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testDeniedWritesHaveNoEffectsAndJournalPrecedesWrite() async throws {
        let (store, device, file) = try setup()
        device.writable = []
        do { _ = try await store.apply(.create(entry), operationID: UUID(), now: now); XCTFail("denied") } catch {}
        XCTAssertEqual(device.writes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        device.writable = [.water]
        device.beforeCommit = {
            let data = try Data(contentsOf: file)
            let rows = try JSONDecoder().decode([HealthStore.Operation].self, from: data)
            XCTAssertEqual(rows.last?.state, .pending)
            let json = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(json.contains("729.25"))
            XCTAssertFalse(json.contains("water"))
            XCTAssertFalse(json.contains("date"))
        }
        let id = UUID()
        _ = try await store.apply(.create(entry), operationID: id, now: now)
        _ = try await store.apply(.create(entry), operationID: id, now: now)
        XCTAssertEqual(device.writes, 1)
        XCTAssertEqual(device.grants.last?.0, []) // Saving doesn't silently request permission to read.
        XCTAssertEqual(device.grants.last?.1, [.water])
        XCTAssertTrue(device.prepared.isEmpty)
    }
    func testInterruptedWriteBlocksDuplicatesAndRecoversWithoutRewriting() async throws {
        let (store, device, file) = try setup(), id = UUID()
        device.throwAfterCommit = true
        do { _ = try await store.apply(.create(entry), operationID: id, now: now); XCTFail("lost callback") }
        catch { XCTAssertFalse(error.localizedDescription.contains(device.secretResult)) }
        let recovered = HealthStore(file: file, device: device)
        do { _ = try await recovered.apply(.create(entry), operationID: UUID(), now: now); XCTFail("duplicate") } catch {}
        XCTAssertEqual(device.writes, 1)
        device.verifyError = true
        do { _ = try await recovered.apply(.verify(id), operationID: UUID(), now: now); XCTFail("query failure") }
        catch { XCTAssertFalse(error.localizedDescription.contains(device.secretResult)) }
        device.verifyError = false
        _ = try await recovered.apply(.verify(id), operationID: UUID(), now: now)
        XCTAssertEqual(try recovered.receipts().first?.state, .succeeded)
        XCTAssertEqual(device.writes, 1)
    }
    func testCorrectionUsesNewVersionAndStaleOrForeignIDsFail() async throws {
        let (store, device, _) = try setup()
        _ = try await store.apply(.create(entry), operationID: UUID(), now: now)
        let original = try XCTUnwrap(device.live.first)
        _ = try await store.apply(.correct(original.sampleID, .init(metric: .water, value: 321, date: now)), operationID: UUID(), now: now)
        XCTAssertEqual(device.live.first?.syncID, original.syncID)
        XCTAssertEqual(device.live.first?.version, 2)
        XCTAssertNotEqual(device.live.first?.sampleID, original.sampleID)
        for id in [original.sampleID, UUID()] {
            do { _ = try await store.apply(.delete(id, .water), operationID: UUID(), now: now); XCTFail("stale or foreign") } catch {}
        }
        XCTAssertEqual(device.writes, 2)
        _ = try await store.apply(.delete(try XCTUnwrap(device.live.first).sampleID, .water), operationID: UUID(), now: now)
        XCTAssertTrue(device.live.isEmpty)
    }
    func testUnknownDeleteCannotBeVerifiedFromAbsence() async throws {
        let (store, device, _) = try setup()
        _ = try await store.apply(.create(entry), operationID: UUID(), now: now)
        let id = UUID(), sample = try XCTUnwrap(device.live.first).sampleID
        device.throwAfterCommit = true
        do { _ = try await store.apply(.delete(sample, .water), operationID: id, now: now); XCTFail("lost receipt") } catch {}
        XCTAssertTrue(device.live.isEmpty)
        do { _ = try await store.apply(.verify(id), operationID: UUID(), now: now); XCTFail("absence isn't proof") } catch {}
        XCTAssertEqual(try store.receipts().last?.state, .pending)
        _ = try await store.apply(.closeVerification(id), operationID: UUID(), now: now)
        XCTAssertEqual(try store.receipts().last?.state, .closedUnverified)
        XCTAssertEqual(device.writes, 2) // Closing verification must never retry or reverse the deletion.
        device.throwAfterCommit = false
        _ = try await store.apply(.create(entry), operationID: UUID(), now: now)
        XCTAssertEqual(device.writes, 3)
    }
    func testCorruptAndUnwritableStorageCannotWrite() async throws {
        let (_, device, file) = try setup()
        let original = Data("broken".utf8); try original.write(to: file)
        for target in [file, file.appendingPathComponent("child")] {
            let store = HealthStore(file: target, device: device)
            do { _ = try await store.apply(.create(entry), operationID: UUID(), now: now); XCTFail("bad disk") } catch {}
        }
        XCTAssertEqual(device.writes, 0)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testDiskFailsAfterLoadingButBeforeNativeWrite() async throws {
        let (store, device, file) = try setup()
        let parent = file.deletingLastPathComponent()
        try FileManager.default.removeItem(at: parent)
        try Data("not a directory".utf8).write(to: parent)
        do { _ = try await store.apply(.create(entry), operationID: UUID(), now: now); XCTFail("write without journal") } catch {}
        XCTAssertEqual(device.writes, 0)
        XCTAssertTrue(device.prepared.isEmpty)
        XCTAssertTrue(try store.receipts().isEmpty)
    }
    func testConcurrentConfirmationAndCancellationDuringPermission() async throws {
        let (store, device, _) = try setup()
        device.pauseAuthorization = true
        let change = HealthChange.create(entry), time = now
        let first = Task { try await store.apply(change, operationID: UUID(), now: time) }
        while device.suspendAuthorization == nil { await Task.yield() }
        do { _ = try await store.apply(change, operationID: UUID(), now: now); XCTFail("busy") } catch {}
        first.cancel(); device.suspendAuthorization?.resume()
        do { _ = try await first.value; XCTFail("cancelled") } catch {}
        XCTAssertEqual(device.writes, 0)
        XCTAssertTrue(try store.receipts().isEmpty)
    }
}
