import Foundation
import XCTest
@testable import Butler

@MainActor
final class BriefReasoningTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "brief-reasoning-\(UUID())"
        let value = UserDefaults(suiteName: name)!
        addTeardownBlock { value.removePersistentDomain(forName: name) }
        return value
    }

    private var now: Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0,
            of: Date(timeIntervalSince1970: 1_790_000_000))!
    }

    private func candidate(name: String = "牛奶", location: String = "冷藏") -> BriefCandidate {
        BriefCandidate(target: .lot(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            kind: .expiringSoon, name: name, detail: "明天到期", quantity: 2, unit: "瓶",
            daysLeft: 1, location: location, isMedicine: false)
    }

    private final class Model: BriefModel {
        var isAvailable = true
        var cacheIdentity = "local"
        var context = BriefContext()
        var requests = 0
        var fail = false
        var readFails = false
        var lastRequest = ""
        var dependencyOutput: String?
        var delay: Duration = .zero
        var reply = #"{"target":null,"text":"明早出差，今晚先把行李准备好。","rationale":"已记录的明早出行；没有替用户新建提醒。","actions":[]}"#
        func snapshot(now: Date) -> BriefContext { context }
        func answer(_ request: String, context: BriefContext) async throws -> String {
            requests += 1
            lastRequest = request
            if delay > .zero { try await Task.sleep(for: delay) }
            if fail { throw URLError(.notConnectedToInternet) }
            return reply
        }
        func generate(_ request: String, context: BriefContext) async throws -> BriefAnswer {
            let text = try await answer(request, context: context)
            let dependencies = dependencyOutput.map {
                [BriefReadDependency(name: "get_calendar_events", arguments: #"{"start":"2026-10-20T00:00:00Z"}"#,
                                     fingerprint: BriefReadDependency.fingerprint($0))]
            } ?? []
            return BriefAnswer(text: text, dependencies: dependencies)
        }
        func validate(_ dependencies: [BriefReadDependency]) async throws -> Bool {
            if readFails { throw BriefReadError.sourceUnavailable }
            return dependencies.allSatisfy { $0.fingerprint == BriefReadDependency.fingerprint(dependencyOutput ?? "") }
        }
    }

    private func update(_ service: BriefService, at date: Date, candidates: [BriefCandidate] = []) {
        service.update(candidates: candidates, lotCount: 0, taskCount: 0, usesCalendar: false, now: date)
    }

    func testAllRecordsAreReachableAndSkippingAMiddlePageCannotCompleteOverview() async throws {
        let context = BriefContext(sections: ["tasks": (0..<67).map { ["id": $0, "text": $0 == 63 ? "明早出差" : "普通任务"] }])
        let reads = BriefReadSession(context: context)
        let overview = try reads.overview()
        let sections = try XCTUnwrap(overview["sections"] as? [String: Any])
        let first = try XCTUnwrap(sections["tasks"] as? [String: Any])
        XCTAssertEqual(first["total"] as? Int, 67)
        XCTAssertEqual(first["next_offset"] as? Int, 30)
        let last = await reads.execute(.init(id: "last", name: "get_brief_page", arguments: #"{"section":"tasks","offset":60}"#)) { _ in
            XCTFail("Snapshot pages must not use a live tool"); return ""
        }
        XCTAssertTrue(last.contains("明早出差"))
        XCTAssertEqual(reads.missingPages, ["tasks": 30])
        XCTAssertNotNil(reads.completionFeedback("一切安排好了"))
        _ = await reads.execute(.init(id: "middle", name: "get_brief_page", arguments: #"{"section":"tasks","offset":30}"#)) { _ in "" }
        XCTAssertTrue(reads.missingPages.isEmpty)
        XCTAssertNil(reads.completionFeedback("完整总览"))
        XCTAssertThrowsError(try context.page("tasks", offset: -1))
        XCTAssertThrowsError(try context.page("tasks", offset: 68))
    }

    func testLongNotesStayWholeAndRemainAccessibleOnFollowingPages() async throws {
        let long = String(repeating: "临时交代", count: 2000)
        let context = BriefContext(sections: ["notes": [["text": long], ["text": "不是周日，是周六回来"]]])
        let page = try context.page("notes", offset: 0)
        XCTAssertEqual((page["records"] as? [[String: String]])?.first?["text"], long)
        XCTAssertEqual(page["next_offset"] as? Int, 1)
        let next = try context.page("notes", offset: 1)
        XCTAssertEqual((next["records"] as? [[String: String]])?.first?["text"], "不是周日，是周六回来")
    }

    func testReadOnlyPolicyRejectsUnadvertisedWritesAndSensitiveReadsBeforeDispatch() async throws {
        let names = ["search_inventory", "read_conversation", "propose_note", "propose_task_action",
                     "get_tasks", "get_health", "get_calendar_events", "propose_calendar_access"]
        let source = String(decoding: try JSONSerialization.data(withJSONObject: names.map { ["name": $0] }), as: UTF8.self)
        let json = try BriefReadSession.toolJSON(from: source)
        let advertised = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(Set(advertised.compactMap { $0["name"] as? String }),
                       ["search_inventory", "read_conversation", "get_calendar_events", "get_brief_page", "get_brief_overview"])
        var executed: [String] = []
        let reads = BriefReadSession(context: BriefContext())
        for name in names {
            let output = await reads.execute(.init(id: name, name: name, arguments: "{}")) { call in
                executed.append(call.name); return "read only"
            }
            if !BriefReadSession.allowed.contains(name) { XCTAssertTrue(output.contains("error")) }
        }
        XCTAssertEqual(executed, ["search_inventory", "read_conversation", "get_calendar_events"])
    }

    func testSignatureChangesForCorrectionsLocationAndUnavailableSources() async throws {
        let first = BriefCandidates.signature([candidate()], now: now)
        XCTAssertNotEqual(first, BriefCandidates.signature([candidate(name: "酸奶")], now: now))
        XCTAssertNotEqual(first, BriefCandidates.signature([candidate(location: "冷冻")], now: now))
        var context = BriefContext(sections: ["notes": [["text": "周日回来"]]])
        let old = context.signature
        context.sections["notes"] = [["text": "周六回来"]]
        XCTAssertNotEqual(old, context.signature)
        XCTAssertNotEqual(BriefContext(sections: ["tasks": []]).signature,
                          BriefContext(metadata: ["unavailable": ["tasks": "读取失败"]]).signature)
    }

    func testNoActionCandidatesStillUsesTheWholeContextAndCarriesExplanation() async throws {
        let model = Model()
        model.context.sections = ["tasks": [["text": "明早出差"]], "notes": [["text": "今晚准备行李"]]]
        let service = BriefService(defaults: defaults())
        service.attach(model: model)
        update(service, at: now)
        await service.settle()
        XCTAssertEqual(model.requests, 1)
        XCTAssertEqual(service.brief.source, .model)
        XCTAssertEqual(service.brief.text, "明早出差，今晚先把行李准备好。")
        XCTAssertEqual(service.brief.rationale, "已记录的明早出行；没有替用户新建提醒。")
        XCTAssertNil(service.brief.target)
        XCTAssertTrue(service.brief.actions.isEmpty)
    }

    func testFailureRetriesAtBoundaryWithoutAnySituationChange() async throws {
        let model = Model(); model.fail = true
        let service = BriefService(defaults: defaults())
        service.attach(model: model)
        update(service, at: now)
        await service.settle()
        model.fail = false
        update(service, at: now.addingTimeInterval(599))
        await service.settle()
        XCTAssertEqual(model.requests, 1)
        update(service, at: now.addingTimeInterval(600))
        await service.settle()
        XCTAssertEqual(model.requests, 2)
        XCTAssertEqual(service.brief.source, .model)
    }

    func testLoginRecoveryDoesNotRestoreTheOldThirtyMinuteExpiry() async throws {
        let model = Model(); model.isAvailable = false
        let service = BriefService(defaults: defaults())
        service.attach(model: model)
        update(service, at: now)
        XCTAssertEqual(model.requests, 0)
        model.isAvailable = true
        update(service, at: now)
        await service.settle()
        update(service, at: now.addingTimeInterval(1799))
        await service.settle()
        XCTAssertEqual(model.requests, 1)
        update(service, at: now.addingTimeInterval(1800))
        await service.settle()
        XCTAssertEqual(model.requests, 1)
    }

    func testConfirmedCorrectionInvalidatesCacheButDoesNotReplaceTouchedCard() async throws {
        let model = Model()
        let service = BriefService(defaults: defaults())
        service.attach(model: model)
        update(service, at: now)
        await service.settle()
        let original = service.brief
        service.beginInteraction()
        model.context.sections["notes"] = [["text": "行程取消了"]]
        model.reply = #"{"text":"行程取消了，今天不用准备行李。","target":null,"actions":[]}"#
        update(service, at: now)
        await service.settle()
        XCTAssertEqual(model.requests, 2)
        XCTAssertEqual(service.brief, original)
        service.endInteraction()
        update(service, at: now)
        XCTAssertEqual(service.brief.text, "行程取消了，今天不用准备行李。")
        XCTAssertEqual(model.requests, 2, "Use the completed background result, not a third request")
    }

    func testTimeoutStopsWaitingAndKeepsLocalCardUsable() async {
        let model = Model(); model.delay = .seconds(60)
        let service = BriefService(defaults: defaults(), timeout: 0.01)
        service.attach(model: model)
        update(service, at: now, candidates: [candidate()])
        await service.settle()
        XCTAssertEqual(model.requests, 1)
        XCTAssertFalse(service.isThinking)
        XCTAssertEqual(service.brief.source, .local)
        XCTAssertFalse(service.brief.actions.isEmpty)
    }

    private final class DeferredModel: BriefModel {
        var isAvailable = true
        var context = BriefContext()
        var waiting: CheckedContinuation<String, Never>?
        var requests = 0
        func snapshot(now: Date) -> BriefContext { context }
        func answer(_ request: String, context: BriefContext) async throws -> String {
            requests += 1
            if requests == 1 { return await withCheckedContinuation { waiting = $0 } }
            return #"{"target":null,"text":"行程取消了，今天不用准备行李。","actions":[]}"#
        }
    }

    func testLateOldResponseCannotReplaceOrCacheOverTheNewSituation() async throws {
        let model = DeferredModel(), store = defaults()
        let service = BriefService(defaults: store)
        service.attach(model: model)
        update(service, at: now, candidates: [candidate()])
        for _ in 0..<1000 where model.waiting == nil { await Task.yield() }
        let old = try XCTUnwrap(model.waiting)
        // Capture the old task before update replaces the service's current task.
        var observingOld = false
        let oldSettled = Task { observingOld = true; await service.settle() }
        while !observingOld { await Task.yield() }
        update(service, at: now, candidates: [candidate(name: "酸奶")])
        await service.settle()
        old.resume(returning: #"{"target":null,"text":"旧行程仍要准备行李。","actions":[]}"#)
        await oldSettled.value
        XCTAssertEqual(service.brief.text, "行程取消了，今天不用准备行李。")
        XCTAssertFalse(service.isThinking)
        let reopened = BriefService(defaults: store)
        update(reopened, at: now, candidates: [candidate(name: "酸奶")])
        XCTAssertEqual(reopened.brief.text, service.brief.text, "The cache must also retain the newer result")
    }

    func testTenColdOpensAndGreetingChangeReuseTheSameSentence() async {
        let storage = defaults(), model = Model()
        let original = BriefService(defaults: storage)
        original.attach(model: model)
        update(original, at: now)
        await original.settle()
        for index in 1...10 {
            let reopened = BriefService(defaults: storage)
            reopened.attach(model: model)
            update(reopened, at: now.addingTimeInterval(Double(index) * 1801))
            XCTAssertEqual(reopened.brief.text, "明早出差，今晚先把行李准备好。")
            XCTAssertFalse(reopened.isThinking)
            await reopened.settle()
        }
        XCTAssertEqual(model.requests, 1)
        update(original, at: now.addingTimeInterval(4 * 3600))
        XCTAssertNotEqual(original.brief.greeting, DailyBrief.greeting(hour: 9))
        XCTAssertEqual(model.requests, 1, "A different greeting is not a different situation")
    }

    func testExplicitReviewBoundaryAndMidnightInvalidateWithoutAnEdit() async {
        let model = Model(), service = BriefService(defaults: defaults())
        let deadline = now.addingTimeInterval(37 * 60)
        model.reply = "{\"text\":\"出发前先把行李准备好。\",\"review_after\":\"\(deadline.ISO8601Format())\"}"
        service.attach(model: model)
        update(service, at: now)
        await service.settle()
        XCTAssertEqual(service.nextCheckAt, deadline)
        update(service, at: deadline.addingTimeInterval(-1))
        await service.settle()
        XCTAssertEqual(model.requests, 1)
        model.reply = #"{"text":"现在可以准备出发了。"}"#
        update(service, at: deadline)
        await service.settle()
        XCTAssertEqual(model.requests, 2)
        XCTAssertEqual(service.brief.text, "现在可以准备出发了。")
        let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(86400)
        update(service, at: midnight)
        await service.settle()
        XCTAssertEqual(model.requests, 3)
    }

    func testLocalBoundaryOnlyChecksUnlessTheSituationChanges() async {
        let model = Model(), service = BriefService(defaults: defaults())
        model.context.boundaries = [now.addingTimeInterval(1200)]
        service.attach(model: model)
        update(service, at: now)
        await service.settle()
        XCTAssertEqual(service.nextCheckAt, now.addingTimeInterval(1200))
        model.context.boundaries = []
        update(service, at: now.addingTimeInterval(1200))
        await service.settle()
        XCTAssertEqual(model.requests, 1)
        model.context.sections["calendar"] = [["id": "trip", "phase": "ongoing"]]
        update(service, at: now.addingTimeInterval(1201))
        await service.settle()
        XCTAssertEqual(model.requests, 2)
    }

    func testEmptyExtraQueryIsPersistedAndNewEventInvalidatesIt() async {
        let storage = defaults(), model = Model()
        model.dependencyOutput = #"{"events":[],"total":0}"#
        let service = BriefService(defaults: storage)
        service.attach(model: model)
        update(service, at: now)
        await service.settle()
        let reopened = BriefService(defaults: storage)
        reopened.attach(model: model)
        update(reopened, at: now.addingTimeInterval(3600))
        XCTAssertFalse(reopened.isThinking, "Revalidating reads is not a model request")
        await reopened.settle()
        XCTAssertEqual(model.requests, 1)
        model.dependencyOutput = #"{"events":[{"id":"new-trip"}],"total":1}"#
        model.reply = #"{"text":"新增了一趟出行，记得提前准备。"}"#
        update(reopened, at: now.addingTimeInterval(3601))
        await reopened.settle()
        XCTAssertEqual(model.requests, 2)
        XCTAssertEqual(reopened.brief.text, "新增了一趟出行，记得提前准备。")
    }

    func testReadSessionTracksEmptyQueriesButNotDeniedTools() async throws {
        let reads = BriefReadSession(context: BriefContext())
        let arguments = #"{"start":"2026-10-20T00:00:00Z","end":"2026-10-21T00:00:00Z"}"#
        _ = await reads.execute(.init(id: "empty", name: "get_calendar_events", arguments: arguments)) { _ in
            #"{"events":[],"total":0}"#
        }
        _ = await reads.execute(.init(id: "forbidden", name: "propose_task", arguments: "{}")) { _ in
            XCTFail("Must not execute a write"); return ""
        }
        XCTAssertEqual(reads.dependencies.count, 1)
        XCTAssertEqual(reads.dependencies.first?.arguments, arguments)
        XCTAssertEqual(BriefReadDependency.fingerprint(#"{"events":[],"total":0}"#),
                       BriefReadDependency.fingerprint(#"{"total":0,"events":[]}"#))
    }

    func testBatchChecksCanInvalidateTouchedCardWithoutStartingGeneration() async {
        let model = Model(), service = BriefService(defaults: defaults())
        service.attach(model: model)
        service.update(candidates: [], lotCount: 0, taskCount: 0, usesCalendar: false, now: now, allowGeneration: false)
        await service.settle()
        XCTAssertEqual(model.requests, 0)
        model.dependencyOutput = #"{"events":[]}"#
        update(service, at: now)
        await service.settle()
        let original = service.brief
        service.beginInteraction()
        model.dependencyOutput = #"{"events":[{"id":"new"}]}"#
        service.update(candidates: [], lotCount: 0, taskCount: 0, usesCalendar: false, now: now, allowGeneration: false)
        await service.settle()
        XCTAssertEqual(model.requests, 1)
        XCTAssertEqual(service.brief, original)
        XCTAssertFalse(service.actionsAreCurrent)
        service.endInteraction()
        update(service, at: now)
        await service.settle()
        XCTAssertEqual(model.requests, 2)
    }

    func testUnreadableExtraQueryBlocksOldActionsAndRecoversWithoutRewriting() async {
        let model = Model(), service = BriefService(defaults: defaults())
        model.dependencyOutput = #"{"events":[]}"#
        service.attach(model: model)
        update(service, at: now)
        await service.settle()
        model.readFails = true
        update(service, at: now.addingTimeInterval(1))
        await service.settle()
        XCTAssertFalse(service.actionsAreCurrent)
        XCTAssertEqual(service.brief.text, "部分资料暂时无法读取，请稍后再看。")
        XCTAssertEqual(service.nextCheckAt, now.addingTimeInterval(61))
        model.readFails = false
        update(service, at: now.addingTimeInterval(61))
        await service.settle()
        XCTAssertEqual(model.requests, 1)
        XCTAssertEqual(service.brief.source, .model)
        XCTAssertTrue(service.actionsAreCurrent)
    }

    func testExtraCalendarQueryChangesAtStartAndEndEvenWithIdenticalStoredFields() {
        let output = #"{"events":[{"fields":{"start":"2026-10-20T09:00:00Z","end":"2026-10-20T10:30:00Z"}}]}"#
        let start = ISO8601DateFormatter().date(from: "2026-10-20T09:00:00Z")!
        let end = start.addingTimeInterval(90 * 60)
        XCTAssertEqual(BriefReadDependency.boundaries(in: output), [start, end])
        let before = BriefReadDependency.fingerprint(output, now: start.addingTimeInterval(-1))
        let ongoing = BriefReadDependency.fingerprint(output, now: start)
        XCTAssertNotEqual(before, ongoing)
        XCTAssertEqual(ongoing, BriefReadDependency.fingerprint(output, now: end.addingTimeInterval(-1)))
        XCTAssertNotEqual(ongoing, BriefReadDependency.fingerprint(output, now: end))
    }

    func testPastReviewIsNotCachedAndDoesNotCauseAnImmediateRetryLoop() async {
        let model = Model(), storage = defaults()
        let past = now.addingTimeInterval(-60)
        model.reply = "{\"text\":\"出发前先把行李准备好。\",\"review_after\":\"\(past.ISO8601Format())\"}"
        let saved = BriefService(defaults: storage)
        saved.attach(model: model)
        update(saved, at: now)
        await saved.settle()
        XCTAssertNil(storage.data(forKey: "briefCache"))
        XCTAssertEqual(saved.nextCheckAt, now.addingTimeInterval(600))
        update(saved, at: now.addingTimeInterval(1))
        await saved.settle()
        XCTAssertEqual(model.requests, 1)
        XCTAssertEqual(saved.brief.source, .local)
    }

    func testChangeDuringRequestIsRejectedEvenWithoutAnotherUpdateCall() async throws {
        let model = DeferredModel(), storage = defaults()
        let service = BriefService(defaults: storage)
        var invalidated = false
        service.onNeedsUpdate = { invalidated = true }
        service.attach(model: model)
        invalidated = false
        update(service, at: now)
        for _ in 0..<1000 where model.waiting == nil { await Task.yield() }
        let waiting = try XCTUnwrap(model.waiting)
        model.context.sections["notes"] = [["text": "行程取消了"]]
        waiting.resume(returning: #"{"text":"明早出差，今晚准备行李。"}"#)
        await service.settle()
        XCTAssertTrue(invalidated)
        XCTAssertEqual(service.brief.source, .local)
        XCTAssertNil(storage.data(forKey: "briefCache"))
    }

    func testUncooperativeRequestTimesOutAndItsLateAnswerIsIgnored() async throws {
        let model = DeferredModel(), storage = defaults()
        let service = BriefService(defaults: storage, timeout: 0.02)
        service.attach(model: model)
        update(service, at: now, candidates: [candidate()])
        await service.settle()
        XCTAssertFalse(service.isThinking)
        XCTAssertEqual(service.brief.source, .local)
        let waiting = try XCTUnwrap(model.waiting)
        waiting.resume(returning: #"{"text":"这是一段已经超时的旧提醒。"}"#)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(storage.data(forKey: "briefCache"))
        XCTAssertEqual(service.brief.source, .local)
    }

    func testFailureBackoffSurvivesReopenButDoesNotBlockNewFacts() async {
        let storage = defaults(), model = Model()
        model.fail = true
        let service = BriefService(defaults: storage)
        service.attach(model: model)
        update(service, at: now)
        await service.settle()
        model.fail = false
        let reopened = BriefService(defaults: storage)
        reopened.attach(model: model)
        update(reopened, at: now.addingTimeInterval(60))
        await reopened.settle()
        XCTAssertEqual(model.requests, 1)
        model.context.sections["tasks"] = [["text": "新增紧急出行"]]
        update(reopened, at: now.addingTimeInterval(61))
        await reopened.settle()
        XCTAssertEqual(model.requests, 2)
    }

    func testUnreadableSourcesNeverBecomeAnEmptyDayAndOldButtonsAreInvalid() async {
        let model = Model(), service = BriefService(defaults: defaults())
        service.attach(model: model)
        update(service, at: now, candidates: [candidate()])
        await service.settle()
        service.beginInteraction()
        model.context.metadata["unavailable"] = ["tasks": "读取失败"]
        update(service, at: now.addingTimeInterval(1))
        XCTAssertFalse(service.actionsAreCurrent)
        service.endInteraction()
        update(service, at: now.addingTimeInterval(2))
        XCTAssertEqual(service.brief.text, "部分资料暂时无法读取，请稍后再看。")
        XCTAssertTrue(service.brief.actions.isEmpty)
        XCTAssertEqual(model.requests, 1)
    }

    func testAccountAndPermissionChangesCannotReuseAnOldAnswer() async {
        let model = Model(), service = BriefService(defaults: defaults())
        model.context.metadata["calendar_allowed"] = true
        service.attach(model: model)
        update(service, at: now)
        await service.settle()
        model.context.sections["notes"] = [["text": "新增交代"]]
        update(service, at: now.addingTimeInterval(0.5))
        await service.settle()
        XCTAssertTrue(model.lastRequest.contains("previous_text"))
        model.cacheIdentity = "another-account"
        update(service, at: now.addingTimeInterval(1))
        await service.settle()
        XCTAssertEqual(model.requests, 3)
        XCTAssertFalse(model.lastRequest.contains("previous_text"), "Do not send a previous account's reminder")
        model.context.metadata["calendar_allowed"] = false
        model.context.metadata["unavailable"] = ["calendar": "未授权"]
        update(service, at: now.addingTimeInterval(2))
        await service.settle()
        XCTAssertEqual(model.requests, 4, "Denied access is different from a failed authorized read")
        XCTAssertFalse(model.lastRequest.contains("previous_text"), "Do not resubmit calendar content after permission is revoked")
    }

    private func weather(at date: Date, rain: Double = 0.2, hours: [WeatherSnapshot.Hour]? = nil) -> WeatherSnapshot {
        let url = URL(string: "https://example.com/weather")!
        return WeatherSnapshot(place: WeatherPlace(name: "上海", latitude: 31, longitude: 121, timeZoneIdentifier: "Asia/Shanghai"), selection: WeatherLocation(),
            fetchedAt: date, observedAt: date, temperature: 22, feelsLike: 23, condition: "晴", symbol: "sun.max",
            windKPH: 8, uvIndex: 3,
            days: [.init(date: Calendar.current.startOfDay(for: now), symbol: "sun.max", condition: "晴", low: 18, high: 25, rainChance: rain)],
            alerts: [], legalURL: url, lightMark: url, darkMark: url, hours: hours)
    }

    func testWeatherSummaryParsingAndDirectActionsOnly() throws {
        for summary in ["下午可能有雨", String(repeating: "雨", count: 14)] {
            let reply = "{\"text\":\"今天下午要出门，记得带伞。\",\"weather_summary\":\"\(summary)\"}"
            XCTAssertEqual(BriefModelReply.parse(reply, candidates: [])?.weatherSummary, summary)
        }
        for summary in ["", String(repeating: "雨", count: 15), "下午\\n有雨"] {
            let parsed = try XCTUnwrap(BriefModelReply.parse("{\"text\":\"今天有安排。\",\"weather_summary\":\"\(summary)\"}", candidates: []))
            XCTAssertNil(parsed.weatherSummary, "Bad weather copy must not discard an otherwise useful brief")
        }
        let complete = BriefAction(label: "我已完成", effect: .completeTask)
        let later = BriefAction(label: "稍后提醒", effect: .remindLater(minutes: 30))
        var brief = ButlerBrief(greeting: "", text: "该取快递了。", basis: "", target: .task(UUID()),
            actions: [complete, .init(label: "查看详情", effect: .openDetail), later, .init(label: "其他安排", effect: .snooze(days: 1))], source: .model)
        XCTAssertEqual(brief.quickActions, [complete, later])
        brief.target = nil
        brief.hasSubject = true
        XCTAssertTrue(brief.quickActions.isEmpty, "An overview must not sprout buttons even with legacy actions")
    }

    func testHourlyForecastCarriesTimeZoneAndNeverInventsTimesFromDailyData() throws {
        let hours: [WeatherSnapshot.Hour] = [
            .init(date: now.addingTimeInterval(-3600), condition: "雨", temperature: 18, rainChance: 0.9),
            .init(date: now, condition: "晴", temperature: 22, rainChance: 0.1),
            .init(date: now.addingTimeInterval(5 * 3600), condition: "雨", temperature: 20, rainChance: 0.8)
        ]
        let facts = try XCTUnwrap(BriefModelReply.weatherContext(weather(at: now, hours: hours), now: now))
        let supplied = try XCTUnwrap(facts["hours"] as? [[String: Any]])
        XCTAssertEqual(supplied.count, 2, "Already-ended rain must not look like upcoming rain")
        XCTAssertEqual(supplied.last?["date"] as? String, now.addingTimeInterval(5 * 3600).ISO8601Format())
        XCTAssertEqual(supplied.last?["rain_chance"] as? Double, 0.8)
        XCTAssertEqual(facts["time_zone"] as? String, "Asia/Shanghai")
        XCTAssertNil(facts["latitude"])
        let dailyOnly = try XCTUnwrap(BriefModelReply.weatherContext(weather(at: now), now: now))
        XCTAssertEqual((dailyOnly["hours"] as? [[String: Any]])?.count, 0)
        let snapshot = weather(at: now.addingTimeInterval(-60), hours: hours)
        let before = BriefModelReply.weatherSignature(snapshot, now: now.addingTimeInterval(-1))
        XCTAssertNotEqual(before, BriefModelReply.weatherSignature(snapshot, now: now), "An hour ending must invalidate its forecast even when both reads are fresh")
        let encoded = try JSONEncoder().encode(weather(at: now))
        XCTAssertNil(try JSONDecoder().decode(WeatherSnapshot.self, from: encoded).hours, "Legacy snapshots remain usable")
    }

    func testWeatherSummaryIsBoundToFreshFactsAndReviewDeadline() async throws {
        let model = Model(), service = BriefService(defaults: defaults())
        model.reply = "{\"text\":\"今天下午出门，记得带伞。\",\"weather_summary\":\"下午可能有雨\",\"review_after\":\"\(now.addingTimeInterval(600).ISO8601Format())\"}"
        service.attach(model: model)
        let snapshot = weather(at: now)
        service.update(candidates: [], lotCount: 0, taskCount: 0, usesCalendar: false, now: now, weather: snapshot)
        await service.settle()
        let brief = service.brief
        XCTAssertEqual(brief.weatherLabel(for: snapshot, at: now.addingTimeInterval(599)), "下午可能有雨")
        XCTAssertNil(brief.weatherLabel(for: snapshot, at: now.addingTimeInterval(600)))
        XCTAssertNil(brief.weatherLabel(for: weather(at: now, rain: 0.9), at: now))
        XCTAssertNil(brief.weatherLabel(for: nil, at: now))
        XCTAssertNil(brief.weatherLabel(for: snapshot, at: now.addingTimeInterval(1800)))
        XCTAssertEqual(try JSONDecoder().decode(ButlerBrief.self, from: JSONEncoder().encode(brief)), brief)
        var longLived = brief
        longLived.weatherValidUntil = now.addingTimeInterval(7200)
        XCTAssertEqual(longLived.weatherLabel(for: snapshot, at: now.addingTimeInterval(1799)), "下午可能有雨")
        XCTAssertNil(longLived.weatherLabel(for: snapshot, at: now.addingTimeInterval(1800)), "Freshness must expire even before the model's review time")

        let noWeather = BriefService(defaults: defaults())
        noWeather.attach(model: model)
        update(noWeather, at: now)
        await noWeather.settle()
        XCTAssertNil(noWeather.brief.weatherSummary, "Unsolicited model weather must not appear without a source")
    }

    func testHourlyBoundaryRechecksBeforeWeatherCacheExpires() async {
        let model = Model(), service = BriefService(defaults: defaults())
        service.attach(model: model)
        let snapshot = weather(at: now, hours: [
            .init(date: now.addingTimeInterval(-3300), condition: "晴", temperature: 22, rainChance: 0.1),
            .init(date: now.addingTimeInterval(300), condition: "雨", temperature: 20, rainChance: 0.8)
        ])
        service.update(candidates: [], lotCount: 0, taskCount: 0, usesCalendar: false, now: now, weather: snapshot)
        await service.settle()
        XCTAssertEqual(service.nextCheckAt, now.addingTimeInterval(300))
        service.update(candidates: [], lotCount: 0, taskCount: 0, usesCalendar: false, now: now.addingTimeInterval(300), weather: snapshot)
        await service.settle()
        XCTAssertEqual(model.requests, 2, "A just-ended hour cannot keep a future-tense summary alive")
    }

    func testDestinationWeatherIsReadOnlyAndExpiresAtItsOwnDeadline() async throws {
        let reads = BriefReadSession(context: BriefContext())
        let expiry = Date.now.addingTimeInterval(1800)
        let output = "{\"available\":true,\"place\":\"杭州\",\"valid_until\":\"\(expiry.ISO8601Format())\",\"hours\":[]}"
        var dispatched: [String] = []
        let value = await reads.execute(.init(id: "weather", name: "get_destination_weather", arguments: #"{"query":"浙江杭州"}"#)) {
            dispatched.append($0.name); return output
        }
        XCTAssertEqual(value, output)
        XCTAssertEqual(reads.dependencies.count, 1)
        XCTAssertEqual(reads.dependencies.first?.boundaries, [ISO8601DateFormatter().date(from: expiry.ISO8601Format())!])
        _ = await reads.execute(.init(id: "write", name: "propose_weather_location", arguments: "{}")) {
            dispatched.append($0.name); return "{}"
        }
        XCTAssertEqual(dispatched, ["get_destination_weather"])
        XCTAssertNotEqual(BriefReadDependency.fingerprint(output, now: expiry.addingTimeInterval(-2)),
                          BriefReadDependency.fingerprint(output, now: expiry.addingTimeInterval(2)))
    }

    func testWeatherFetchTimeDoesNotRewriteButForecastAndFreshnessDo() async {
        let model = Model(), service = BriefService(defaults: defaults())
        service.attach(model: model)
        func refresh(_ date: Date, _ weather: WeatherSnapshot) {
            service.update(candidates: [], lotCount: 0, taskCount: 0, usesCalendar: false, now: date, weather: weather)
        }
        refresh(now, weather(at: now))
        await service.settle()
        let later = now.addingTimeInterval(1900)
        refresh(later, weather(at: later))
        await service.settle()
        XCTAssertEqual(model.requests, 1, "Same weather fetched again after 30 minutes must still reuse")
        refresh(later.addingTimeInterval(1), weather(at: later, rain: 0.9))
        await service.settle()
        XCTAssertEqual(model.requests, 2)
        refresh(later.addingTimeInterval(1800), weather(at: later, rain: 0.9))
        await service.settle()
        XCTAssertEqual(model.requests, 3, "Stale observations cannot remain current indefinitely")
    }

    private final class PagingModel: LocalAgentModel {
        var calls = 0
        func reply(to messages: [LocalAgentMessage]) async throws -> LocalModelReply {
            calls += 1
            if calls == 1 { return LocalModelReply(text: "过早给出的总览", calls: []) }
            if calls == 2 {
                return LocalModelReply(text: "", calls: [.init(id: "page", name: "get_brief_page",
                    arguments: #"{"section":"tasks","offset":30}"#)])
            }
            return LocalModelReply(text: "已读完整概况", calls: [])
        }
    }

    func testToolLoopContinuesWhenModelSkipsUnreadPages() async throws {
        let reads = BriefReadSession(context: BriefContext(sections: ["tasks": (0..<31).map { ["id": $0] }]))
        let data = try JSONSerialization.data(withJSONObject: reads.overview())
        let model = PagingModel()
        var messages: [LocalAgentMessage] = [.user(String(decoding: data, as: UTF8.self))]
        let answer = try await ToolConversationLoop.run(model: model, messages: &messages, execute: { call in
            await reads.execute(call) { _ in XCTFail("No live reads"); return "" }
        }, completionFeedback: reads.completionFeedback, log: { _ in })
        XCTAssertEqual(model.calls, 3)
        XCTAssertEqual(answer, "已读完整概况")
        XCTAssertTrue(reads.missingPages.isEmpty)
    }
}
