import Foundation
import XCTest
@testable import Butler

@MainActor
final class ToolConversationLoopTests: XCTestCase {
    private func call(_ id: String, _ name: String, _ arguments: String = "{}") -> LocalToolCall {
        LocalToolCall(id: id, name: name, arguments: arguments)
    }

    private func policy(_ epoch: ToolReadCacheEpoch? = nil) -> ToolReadExecutionPolicy {
        .butlerReadOnly(epoch: epoch ?? ToolReadCacheEpoch(center: NotificationCenter()))
    }

    private func receipts(_ messages: [LocalAgentMessage]) -> [(String, String)] {
        messages.compactMap { if case .tool(let id, let output) = $0 { (id, output) } else { nil } }
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date.now.addingTimeInterval(2)
        while !condition(), Date.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "The controlled operation did not start", file: file, line: line)
    }

    func testParallelReadsOverlapWhileWritesWaitAndReceiptsKeepModelOrder() async throws {
        let calls = [call("inventory", "search_inventory", #"{"query":"牛奶","include_finished":false}"#),
                     call("weather", "get_destination_weather", #"{"query":"杭州"}"#),
                     call("notes", "search_notes", #"{"query":"早餐"}"#),
                     call("proposal", "propose_set_quantity"), call("after", "search_notes", #"{"query":"早餐"}"#)]
        let model = LoopScript([calls])
        let gate = LoopReadGate()
        var metrics = ToolLoopMetrics()
        let optimized = policy()
        let work = Task { @MainActor in
            var history: [LocalAgentMessage] = [.user("合成多工具请求")]
            _ = try await ToolConversationLoop.run(model: model, messages: &history, readPolicy: optimized,
                execute: { try await gate.execute($0) }, log: { _ in }, onMetrics: { metrics = $0 })
            return history
        }
        await waitUntil { gate.started.count == 3 }
        XCTAssertEqual(Set(gate.started), Set(["inventory", "weather", "notes"]))
        XCTAssertEqual(gate.peak, 3, "All reads must enter before any is released; this proves overlap without a timing threshold")
        gate.release("notes"); gate.release("weather")
        await waitUntil { gate.finished.count == 2 }
        XCTAssertFalse(gate.started.contains("proposal"))
        gate.release("inventory")
        await waitUntil { gate.started.contains("proposal") }
        XCTAssertFalse(gate.started.contains("after"))
        gate.release("proposal")
        await waitUntil { gate.started.contains("after") }
        gate.release("after")
        let history = try await work.value
        XCTAssertEqual(receipts(history).map(\.0), calls.map(\.id))
        XCTAssertEqual(metrics.parallelGroups, 1)
        XCTAssertEqual(metrics.maximumParallel, 3)
        XCTAssertEqual(metrics.executedTools, 5)
        XCTAssertEqual(metrics.modelRounds, 2)
    }

    func testOnlyOneInventoryJudgeRunsAtOnceAndParallelismIsBounded() async throws {
        let calls = [call("i1", "search_inventory", #"{"query":"牛奶"}"#),
                     call("weather", "get_destination_weather", #"{"query":"北京"}"#),
                     call("i2", "search_inventory", #"{"query":"鸡蛋"}"#),
                     call("notes", "search_notes"), call("settings", "get_settings"), call("guide", "get_product_guide")]
        let gate = LoopReadGate()
        let model = LoopScript([calls])
        let optimized = policy()
        let work = Task { @MainActor in
            var history: [LocalAgentMessage] = []
            _ = try await ToolConversationLoop.run(model: model, messages: &history, readPolicy: optimized,
                execute: { try await gate.execute($0) }, log: { _ in })
        }
        await waitUntil { gate.started.count == 2 }
        XCTAssertFalse(gate.started.contains("i2"))
        gate.release("i1"); gate.release("weather")
        await waitUntil { gate.started.count == 5 }
        XCTAssertFalse(gate.started.contains("guide"), "The concurrency cap is three reads")
        for id in ["i2", "notes", "settings"] { gate.release(id) }
        await waitUntil { gate.started.contains("guide") }
        gate.release("guide")
        try await work.value
        XCTAssertEqual(gate.peak, 3)
    }

    func testDefaultIsSerialAndUnknownPermissionAndRefreshToolsAreBarriers() async throws {
        for optimized in [false, true] {
            let names = optimized ? ["get_current_context", "get_fake_read", "propose_travel_access", "get_weather", "get_tasks", "search_notes"]
                                  : ["search_notes", "get_destination_weather", "get_current_context"]
            let calls = names.enumerated().map { call("\($0.offset)", $0.element, $0.element == "get_weather" ? #"{"refresh":true}"# : "{}") }
            let gate = LoopReadGate()
            let model = LoopScript([calls])
            let selected: ToolReadExecutionPolicy = optimized ? policy() : .serial
            let work = Task { @MainActor in
                var history: [LocalAgentMessage] = []
                _ = try await ToolConversationLoop.run(model: model, messages: &history, readPolicy: selected,
                    execute: { try await gate.execute($0) }, log: { _ in })
            }
            for index in calls.indices {
                await waitUntil { gate.started.count == index + 1 }
                XCTAssertEqual(gate.active, 1)
                gate.release("\(index)")
            }
            try await work.value
            XCTAssertEqual(gate.peak, 1)
        }
    }

    func testCanonicalDuplicateReadsReuseWithinTurnButNotAcrossTurns() async throws {
        let model = LoopScript([[call("a", "search_notes", #"{"query":"早餐","other":null}"#),
                                 call("b", "search_notes", #"{ "other":null, "query":"早餐" }"#)],
                                [call("c", "search_notes", #"{"query":"早餐","other":null}"#)]])
        var executions = 0
        var firstMetrics = ToolLoopMetrics()
        let selected = policy()
        var history: [LocalAgentMessage] = []
        _ = try await ToolConversationLoop.run(model: model, messages: &history, readPolicy: selected,
            execute: { _ in executions += 1; return "[]" }, log: { _ in }, onMetrics: { firstMetrics = $0 })
        XCTAssertEqual(executions, 1)
        XCTAssertEqual(firstMetrics.cacheHits, 2)
        XCTAssertEqual(receipts(history).map(\.0), ["a", "b", "c"])
        let nextTurn = LoopScript([[call("d", "search_notes", #"{"query":"早餐","other":null}"#)]])
        _ = try await ToolConversationLoop.run(model: nextTurn, messages: &history, readPolicy: selected,
            execute: { _ in executions += 1; return "[]" }, log: { _ in })
        XCTAssertEqual(executions, 2, "A new user run cannot inherit prior cached reads")
    }

    func testWritesAndUnknownToolsInvalidateReadsAndAreNeverReusedByArguments() async throws {
        for mutation in ["propose_set_quantity", "revise_pending_change", "discard_pending_changes", "propose_travel_access", "unknown_tool"] {
            let model = LoopScript([[call("r1", "search_notes"), call("w1", mutation),
                                     call("r2", "search_notes"), call("w2", mutation), call("r3", "search_notes")]])
            var executions: [String] = []
            var history: [LocalAgentMessage] = []
            _ = try await ToolConversationLoop.run(model: model, messages: &history, readPolicy: policy(),
                execute: { executions.append($0.id); return $0.name == "search_notes" ? "[]" : "{}" }, log: { _ in })
            XCTAssertEqual(executions, ["r1", "w1", "r2", "w2", "r3"])
        }
    }

    func testCompletePrefetchIsReusedButPartialFailedOrChangedPrefetchIsNot() async throws {
        let variants: [(String, Bool, Int)] = [
            (#"{"complete":true,"truncated":false,"items":[]}"#, false, 0),
            (#"{"complete":false,"truncated":true,"items":[]}"#, false, 1),
            (#"{"error":"暂不可用","complete":true,"items":[]}"#, false, 1),
            (#"{"complete":true,"items":[]}"#, true, 1)
        ]
        for (output, changeAfterPreparation, expectedCalls) in variants {
            let epoch = ToolReadCacheEpoch(center: NotificationCenter())
            let selected = policy(epoch)
            let original = call("prefetch", "search_inventory", #"{"query":"","include_finished":false}"#)
            if changeAfterPreparation { epoch.invalidate() }
            let model = LoopScript([[call("asked", "search_inventory", original.arguments)]])
            var history: [LocalAgentMessage] = []
            var executed = 0
            var metrics = ToolLoopMetrics()
            _ = try await ToolConversationLoop.run(model: model, messages: &history,
                prefetched: [PrefetchedToolResult(call: original, output: output)], readPolicy: selected,
                execute: { _ in executed += 1; return #"{"complete":true,"items":[]}"# }, log: { _ in }, onMetrics: { metrics = $0 })
            XCTAssertEqual(executed, expectedCalls)
            XCTAssertEqual(metrics.prefetchedHits, expectedCalls == 0 ? 1 : 0)
            XCTAssertEqual(receipts(history).map(\.0), ["prefetch", "asked"])
        }
    }

    func testPrefetchedNotesRetainOriginalProvenanceButReuseNormalSearchShape() async throws {
        let original = call("prefetch", "search_notes", #"{"query":""}"#)
        let output = #"{"source":"local_notes","complete":true,"truncated":false,"notes":[{"id":"synthetic","title":"早餐","text":"喜欢牛奶","revision":1}]}"#
        let model = LoopScript([[call("query", "search_notes", original.arguments)]])
        var history: [LocalAgentMessage] = []
        _ = try await ToolConversationLoop.run(model: model, messages: &history,
            prefetched: [PrefetchedToolResult(call: original, output: output)], readPolicy: policy(),
            execute: { _ in XCTFail("Complete prefetch should satisfy the exact read"); return "[]" }, log: { _ in })
        let values = receipts(history)
        XCTAssertEqual(values.first?.1, output)
        let reused = try XCTUnwrap(values.last?.1)
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(reused.utf8)) as? [[String: String]])
        XCTAssertEqual(rows, [["id": "synthetic", "title": "早餐", "text": "喜欢牛奶"]])
    }

    func testFailurePartialWeatherAndContextReadsRemainRetryable() async throws {
        let cases: [(String, String, String)] = [
            ("search_notes", "{}", #"{"error":"temporary"}"#),
            ("search_inventory", "{}", #"{"complete":false,"items":[]}"#),
            ("get_weather", #"{"refresh":false}"#, #"{"fresh":false}"#),
            ("get_destination_weather", "{}", #"{"available":false}"#),
            ("get_current_context", "{}", "{}")
        ]
        for (name, arguments, output) in cases {
            let model = LoopScript([[call("one", name, arguments), call("two", name, arguments)]])
            var executions = 0
            var history: [LocalAgentMessage] = []
            _ = try await ToolConversationLoop.run(model: model, messages: &history, readPolicy: policy(),
                execute: { _ in executions += 1; return output }, log: { _ in })
            XCTAssertEqual(executions, 2, name)
        }
    }

    func testEpochChangesBetweenRoundsAndDuringReadsInvalidateCache() async throws {
        for duringRead in [false, true] {
            let center = NotificationCenter()
            let epoch = ToolReadCacheEpoch(center: center)
            let model = LoopScript([[call("one", "search_notes")], [call("two", "search_notes")]])
            if !duringRead { model.onReply = { if $0 == 1 { center.post(name: .init("butlerBriefSourcesChanged"), object: nil) } } }
            var executions = 0
            var history: [LocalAgentMessage] = []
            _ = try await ToolConversationLoop.run(model: model, messages: &history, readPolicy: policy(epoch),
                execute: { _ in
                    executions += 1
                    if duringRead, executions == 1 { center.post(name: UserDefaults.didChangeNotification, object: nil) }
                    return "[]"
                }, log: { _ in })
            XCTAssertEqual(executions, 2)
        }
    }

    func testHouseholdChangesWithoutNotificationsAndJudgeToggleInvalidateEpoch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loop-family-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let household = HouseholdStore(directory: directory)
        let judge = LoopJudge()
        let epoch = ToolReadCacheEpoch(household: household, judge: judge, center: NotificationCenter())
        var previous = epoch.version
        let me = HouseholdMember(id: UUID(), name: "测试用户", isOwner: true, joinedAt: .now)
        household.begin(HouseholdState(id: UUID(), name: "合成家庭", role: .owner, zoneName: "fictional",
                                      zoneOwner: "fictional", me: me.id, joinedAt: .now), me: me)
        XCTAssertNotEqual(epoch.version, previous)
        previous = epoch.version
        try household.renameMe("合成名字")
        XCTAssertNotEqual(epoch.version, previous)
        previous = epoch.version
        household.setSharing(ItemSharing(scope: .personal, recordedBy: me.id), for: UUID())
        XCTAssertNotEqual(epoch.version, previous)
        previous = epoch.version
        judge.isEnabled = false
        XCTAssertNotEqual(epoch.version, previous)
        previous = epoch.version
        judge.reuseToken = UUID()
        XCTAssertNotEqual(epoch.version, previous)
        previous = epoch.version
        household.end()
        XCTAssertNotEqual(epoch.version, previous)
    }

    func testCacheHitBesideNewReadDoesNotExtendOriginalExpiry() async throws {
        let clock = LoopClock()
        let epoch = ToolReadCacheEpoch(center: NotificationCenter())
        let selected = ToolReadExecutionPolicy.butlerReadOnly(epoch: epoch, now: { clock.date })
        let model = LoopScript([[call("first", "search_notes", #"{"query":"A"}"#)],
                                [call("new", "get_product_guide"), call("cached", "search_notes", #"{"query":"A"}"#)],
                                [call("expired", "search_notes", #"{"query":"A"}"#)]])
        model.onReply = { round in clock.date = clock.start.addingTimeInterval(round == 1 ? 20 : round >= 2 ? 31 : 0) }
        var executed: [String] = []
        var history: [LocalAgentMessage] = []
        _ = try await ToolConversationLoop.run(model: model, messages: &history, readPolicy: selected,
            execute: { executed.append($0.id); return $0.name == "search_notes" ? "[]" : "{}" }, log: { _ in })
        XCTAssertEqual(executed, ["first", "new", "expired"])
    }

    func testSilentNotesAndReminderReloadsInvalidateValueSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loop-reload-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let noteFile = directory.appendingPathComponent("notes.json")
        let reminderFile = directory.appendingPathComponent("reminders.json")
        let notes = try LocalMemoryStore(file: noteFile)
        let reminders = ReminderStore(file: reminderFile, schedules: false, publishesChanges: false)
        // Private notification center proves invalidation is from the reloaded value,
        // independent of incidental notifications from a different store instance.
        let epoch = ToolReadCacheEpoch(notes: notes, reminders: reminders, center: NotificationCenter())
        let original = epoch.version
        let writer = try LocalMemoryStore(file: noteFile)
        try writer.upsert(LocalMemory(id: UUID(), title: "合成偏好", text: "早餐喝牛奶", revision: 1))
        XCTAssertEqual(epoch.version, original, "The reader has not reloaded the changed file yet")
        let model = LoopScript([[call("before", "search_notes")], [call("after", "search_notes")]])
        model.onReply = { if $0 == 1 { try? notes.reload() } }
        var reads = 0
        var history: [LocalAgentMessage] = []
        _ = try await ToolConversationLoop.run(model: model, messages: &history, readPolicy: policy(epoch),
            execute: { _ in reads += 1; return "[]" }, log: { _ in })
        XCTAssertEqual(reads, 2)
        XCTAssertNotEqual(epoch.version, original)
        let beforeReminderReload = epoch.version
        let task = TimedReminder(text: "合成安排", fireDate: .now.addingTimeInterval(86_400))
        try JSONEncoder().encode([task]).write(to: reminderFile, options: .atomic)
        XCTAssertEqual(epoch.version, beforeReminderReload)
        reminders.reload()
        XCTAssertNotEqual(epoch.version, beforeReminderReload)
        XCTAssertEqual(epoch.version.reminders?.first?.text, "合成安排")
    }

    func testTaskReadsRespectUpcomingTimeBoundaryAndActAsBarrierWhenFresh() async throws {
        let clock = LoopClock()
        let selected = ToolReadExecutionPolicy.butlerReadOnly(epoch: ToolReadCacheEpoch(center: NotificationCenter()), now: { clock.date })
        let expires = clock.start.addingTimeInterval(2).ISO8601Format()
        let output = #"{"tasks":[{"next_notifications":["\#(expires)"]}],"truncated":false}"#
        let model = LoopScript([[call("first", "get_tasks")], [call("repeat", "get_tasks")], [call("boundary", "get_tasks")]])
        model.onReply = { if $0 >= 2 { clock.date = clock.start.addingTimeInterval(3) } }
        var executed: [String] = []
        var history: [LocalAgentMessage] = []
        _ = try await ToolConversationLoop.run(model: model, messages: &history, readPolicy: selected,
            execute: { executed.append($0.id); return output }, log: { _ in })
        XCTAssertEqual(executed, ["first", "boundary"])
    }

    func testCancellationCancelsAllChildrenBeforeAnyProposalOrNextModelRound() async throws {
        let gate = LoopReadGate()
        let model = LoopScript([[call("a", "search_notes"), call("b", "get_destination_weather"), call("write", "propose_reminder")]])
        var logs: [String] = []
        var finalMetrics: ToolLoopMetrics?
        let selected = policy()
        let work = Task { @MainActor in
            var history: [LocalAgentMessage] = []
            _ = try await ToolConversationLoop.run(model: model, messages: &history, readPolicy: selected,
                execute: { try await gate.execute($0) }, log: { logs.append($0) }, onMetrics: { finalMetrics = $0 })
        }
        await waitUntil { gate.started.count == 2 }
        work.cancel()
        do { try await work.value; XCTFail("Cancellation should propagate") } catch is CancellationError {}
        XCTAssertEqual(gate.active, 0)
        XCTAssertEqual(Set(gate.finished), Set(["a", "b"]))
        XCTAssertFalse(gate.started.contains("write"))
        XCTAssertEqual(model.rounds, 1)
        XCTAssertEqual(finalMetrics?.executedTools, 2)
        XCTAssertTrue(logs.last?.contains("model_rounds=1 executed_tools=2") == true)
    }

    func testThrownReadCancelsSiblingsAndStillLogsMetrics() async throws {
        let gate = LoopReadGate()
        gate.failure = "b"
        let model = LoopScript([[call("a", "search_notes"), call("b", "get_destination_weather"), call("write", "propose_reminder")]])
        let selected = policy()
        var metrics: ToolLoopMetrics?
        let work = Task { @MainActor in
            var history: [LocalAgentMessage] = []
            _ = try await ToolConversationLoop.run(model: model, messages: &history, readPolicy: selected,
                execute: { try await gate.execute($0) }, log: { _ in }, onMetrics: { metrics = $0 })
        }
        await waitUntil { gate.started.count == 2 }
        gate.release("b")
        do { try await work.value; XCTFail("Expected the synthetic error") } catch LoopTestFailure.failedRead {}
        XCTAssertEqual(gate.active, 0)
        XCTAssertFalse(gate.started.contains("write"))
        XCTAssertEqual(metrics?.parallelGroups, 1)
    }

    func testSameSyntheticLatencyWorkloadReportsSerialAndOptimizedCost() async throws {
        // A controlled local stand-in for I/O. The gate tests above prove causality; this
        // comparison reports elapsed time and avoided calls, not real model performance.
        var reports: [(String, Double, ToolLoopMetrics)] = []
        for optimized in [false, true] {
            let model = LoopScript([[call("notes", "search_notes"), call("weather", "get_destination_weather"), call("guide", "get_product_guide")],
                                    [call("notes-again", "search_notes"), call("weather-again", "get_destination_weather")]])
            var history: [LocalAgentMessage] = []
            var metrics = ToolLoopMetrics()
            let began = Date.now
            _ = try await ToolConversationLoop.run(model: model, messages: &history, readPolicy: optimized ? policy() : .serial,
                execute: { call in
                    try await Task.sleep(for: .milliseconds(40))
                    return call.name == "search_notes" ? "[]" : #"{"available":true}"#
                }, log: { _ in }, onMetrics: { metrics = $0 })
            reports.append((optimized ? "optimized" : "serial", Date.now.timeIntervalSince(began), metrics))
        }
        XCTAssertEqual(reports[0].2.executedTools, 5)
        XCTAssertEqual(reports[1].2.executedTools, 3)
        XCTAssertEqual(reports[1].2.cacheHits, 2)
        XCTAssertEqual(reports[1].2.maximumParallel, 3)
        for (name, elapsed, metrics) in reports {
            print("SYNTHETIC_TOOL_LOOP \(name) elapsed_ms=\(Int(elapsed * 1000)) executed=\(metrics.executedTools) hits=\(metrics.cacheHits) max_parallel=\(metrics.maximumParallel)")
        }
    }
}

@MainActor
private final class LoopScript: LocalAgentModel {
    let batches: [[LocalToolCall]]
    var rounds = 0
    var onReply: ((Int) -> Void)?
    init(_ batches: [[LocalToolCall]]) { self.batches = batches }
    nonisolated deinit {}
    func reply(to messages: [LocalAgentMessage]) async throws -> LocalModelReply {
        onReply?(rounds)
        let calls = rounds < batches.count ? batches[rounds] : []
        rounds += 1
        return LocalModelReply(text: calls.isEmpty ? "完成" : "", calls: calls)
    }
}

@MainActor
private final class LoopReadGate {
    var started: [String] = []
    var finished: [String] = []
    var active = 0
    var peak = 0
    var failure: String?
    private var gates: [String: AsyncStream<Void>.Continuation] = [:]
    nonisolated deinit {}
    func execute(_ call: LocalToolCall) async throws -> String {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        gates[call.id] = continuation
        started.append(call.id); active += 1; peak = max(peak, active)
        defer { active -= 1; finished.append(call.id); gates[call.id] = nil }
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        try Task.checkCancellation()
        if failure == call.id { throw LoopTestFailure.failedRead }
        return #"{"id":"\#(call.id)","complete":true,"available":true}"#
    }
    func release(_ id: String) { gates[id]?.yield(()); gates[id]?.finish() }
}

@MainActor
private final class LoopClock {
    let start = Date(timeIntervalSince1970: 4_075_380_000)
    var date: Date
    init() { date = start }
    nonisolated deinit {}
}

private enum LoopTestFailure: Error { case failedRead }

@MainActor
private final class LoopJudge: ConditionJudge {
    var isEnabled = true
    var isConfigured = true
    var reuseToken: UUID? = UUID()
    nonisolated deinit {}
    func judge(request: String, questions: [JevClient.Question]) async throws -> [String: Double] { throw LoopTestFailure.failedRead }
}
