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
        var context = BriefContext()
        var requests = 0
        var fail = false
        var delay: Duration = .zero
        var reply = #"{"target":null,"text":"明早出差，今晚先把行李准备好。","rationale":"已记录的明早出行；没有替用户新建提醒。","actions":[]}"#
        func snapshot(now: Date) -> BriefContext { context }
        func answer(_ request: String, context: BriefContext) async throws -> String {
            requests += 1
            if delay > .zero { try await Task.sleep(for: delay) }
            if fail { throw URLError(.notConnectedToInternet) }
            return reply
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

    func testLoginRecoveryAndCacheExpiryDoNotNeedANewCandidate() async throws {
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
        XCTAssertEqual(model.requests, 2)
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
        var waiting: CheckedContinuation<String, Never>?
        var requests = 0
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
