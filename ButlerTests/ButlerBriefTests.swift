import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor
final class ButlerBriefTests: XCTestCase {
    private let calendar = Calendar.current
    private func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        let base = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date(timeIntervalSince1970: 1_790_000_000))!
        return calendar.date(byAdding: .day, value: dayOffset, to: base)!
    }
    private func day(_ offset: Int, from now: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }
    private func lot(_ name: String, quantity: Int = 2, package: Date? = nil, category: String? = nil, place: String? = nil,
                     now: Date) -> LotFacts {
        let product = CatalogProduct(canonicalName: name, categoryRawValue: category)
        let lot = InventoryLot(productID: product.id, quantity: quantity, unit: "瓶")
        lot.packageExpiryDate = package
        lot.storageLocation = place
        return LotFacts(lot: lot, product: product, now: now, calendar: calendar)
    }
    private func defaults() -> UserDefaults {
        let name = "brief-tests-\(UUID())"
        let store = UserDefaults(suiteName: name)!
        addTeardownBlock { store.removePersistentDomain(forName: name) }
        return store
    }

    // MARK: Candidates

    func testCandidatesAreOrderedByHowPressingTheyAreAndSnoozedOnesLeaveTheSentence() throws {
        let now = at(9)
        let eggs = lot("土鸡蛋", package: day(-4, from: now), place: "冷藏", now: now)
        let yogurt = lot("红枣酸奶", package: day(2, from: now), now: now)
        let water = lot("七鲜饮用纯净水", quantity: 1, category: "household", now: now)
        let due = TimedReminder(text: "热剩饭", fireDate: at(8), createdAt: day(-1, from: now))
        let agenda = HomeAgenda.build(lots: [yogurt, water, eggs], reminders: [due], events: [], now: now)

        let all = BriefCandidates.make(facts: [yogurt, water, eggs], agenda: agenda, now: now)
        XCTAssertEqual(all.map(\.kind), [.expired, .dueTask, .expiringSoon, .lowStock])
        XCTAssertEqual(all.first?.name, "土鸡蛋")
        XCTAssertEqual(all.first?.detail, "已过期 4 天")

        let snoozed = BriefCandidates.make(facts: [yogurt, water, eggs], agenda: agenda, now: now, snoozed: [BriefTarget.lot(eggs.id).key])
        XCTAssertEqual(snoozed.map(\.kind), [.dueTask, .expiringSoon, .lowStock])
    }

    func testQuickActionValidationDoesNotLoseTasksBehindFiveExpiredItems() {
        let now = at(9)
        let food = (0..<8).map { lot("食物\($0)", package: day(-2, from: now), now: now) }
        let trip = TimedReminder(text: "出发去机场", fireDate: at(8))
        let agenda = HomeAgenda.build(lots: food, reminders: [trip], events: [], now: now)
        let candidates = BriefCandidates.make(facts: food, agenda: agenda, now: now)
        XCTAssertEqual(candidates.count, 9)
        XCTAssertTrue(candidates.contains { $0.target == .task(trip.id) })
        let reply = #"{"target":"\#(BriefTarget.task(trip.id).key)","text":"今天要出行，先确认出发安排。","actions":[]}"#
        XCTAssertEqual(BriefModelReply.parse(reply, candidates: candidates)?.target, .task(trip.id))
    }

    func testTheCardSumsUpTodaysTasksWithoutDetailsAndNeverTakesThemOffTheList() throws {
        let now = at(5)
        let yogurt = lot("红枣酸奶", package: day(-3, from: now), now: now)
        let morning = TimedReminder(text: "G2515 北京北 07:09 → 朔州东", fireDate: at(6, 9), createdAt: day(-1, from: now))
        let noon = TimedReminder(text: "D6061 朔州东 → 太原南", fireDate: at(12, 30), createdAt: day(-1, from: now))
        let agenda = HomeAgenda.build(lots: [yogurt], reminders: [morning, noon], events: [], now: now)
        let all = BriefCandidates.make(facts: [yogurt], agenda: agenda, now: now)
        XCTAssertEqual(all.map(\.kind), [.expired, .upcomingTask, .upcomingTask])

        let brief = BriefLocal.compose(candidates: all, lotCount: 3, basis: "", now: now)
        XCTAssertTrue(brief.text.hasPrefix("今天还有 2 件安排，最早在早上 6 点多。"), brief.text)
        XCTAssertFalse(brief.text.contains("G2515"), "details stay in the list")
        XCTAssertEqual(brief.target, .lot(yogurt.id), "buttons are for the thing that needs handling")

        let onlyTasks = BriefCandidates.make(facts: [], agenda: HomeAgenda.build(lots: [], reminders: [morning, noon], events: [], now: now), now: now)
        let overview = BriefLocal.compose(candidates: onlyTasks, lotCount: 3, basis: "", now: now)
        XCTAssertNil(overview.target)
        XCTAssertTrue(overview.actions.isEmpty)
        XCTAssertEqual(overview.hasSubject, true, "not a quiet day: 其他 stays")
        XCTAssertNotEqual(overview.text, "暂时没有新的提醒，其他安排和记录都在下面。")

        // The model may not aim buttons at an upcoming task; it may answer with an overview only.
        let upcomingKey = BriefTarget.task(morning.id).key
        let aimed = BriefModelReply.parse(#"{"target":"\#(upcomingKey)","text":"今天两趟车，一大早就要出门。","actions":[{"label":"做完了","effect":"complete_task","value":null}]}"#, candidates: onlyTasks)
        XCTAssertNil(aimed?.target)
        XCTAssertEqual(aimed?.actions.isEmpty, true)
        XCTAssertNotNil(BriefModelReply.parse(#"{"target":null,"text":"今天两趟车，一大早就要出门。","actions":[]}"#, candidates: onlyTasks))
    }

    func testSignatureChangesWithTheSituationAndThePartOfTheDayButNotWithTheClock() {
        let morning = at(9)
        let egg = BriefCandidate(target: .lot(UUID()), kind: .expired, name: "土鸡蛋", detail: "已过期 4 天", quantity: 6, unit: "枚",
                                 daysLeft: -4, location: nil, isMedicine: false)
        let a = BriefCandidates.signature([egg], now: morning)
        XCTAssertEqual(a, BriefCandidates.signature([egg], now: at(10, 30)))
        XCTAssertNotEqual(a, BriefCandidates.signature([egg], now: at(19)))
        XCTAssertNotEqual(a, BriefCandidates.signature([], now: morning))
        XCTAssertNotEqual(a, BriefCandidates.signature([egg], now: at(9, dayOffset: 1)))
    }

    // MARK: Local sentence

    func testLocalSentenceAndButtonsFollowWhatTheThingIs() {
        let now = at(9)
        let egg = BriefCandidate(target: .lot(UUID()), kind: .expired, name: "土鸡蛋", detail: "已过期 4 天", quantity: 6, unit: "枚",
                                 daysLeft: -4, location: nil, isMedicine: false)
        let expired = BriefLocal.compose(candidates: [egg], lotCount: 3, basis: "依据", now: now)
        XCTAssertEqual(expired.text, "土鸡蛋已过期 4 天，今天处理掉吧。")
        XCTAssertEqual(expired.actions.map(\.label), ["扔掉了", "已吃完", "先放放"])
        XCTAssertEqual(expired.target, egg.target)
        XCTAssertEqual(expired.source, .local)

        let task = BriefCandidate(target: .task(UUID()), kind: .dueTask, name: "热剩饭", detail: "已到时间", quantity: nil, unit: nil,
                                  daysLeft: nil, location: nil, isMedicine: false)
        let due = BriefLocal.compose(candidates: [task], lotCount: 0, basis: "", now: now)
        XCTAssertEqual(due.actions.map(\.effect), [.completeTask, .remindLater(minutes: 10)])

        let medicine = BriefCandidate(target: .lot(UUID()), kind: .expired, name: "布洛芬", detail: "已过期 1 天", quantity: 1, unit: "盒",
                                      daysLeft: -1, location: nil, isMedicine: true)
        XCTAssertFalse(BriefLocal.compose(candidates: [medicine], lotCount: 1, basis: "", now: now).actions.contains { $0.effect == .closeLot(.depleted) })

        XCTAssertEqual(BriefLocal.compose(candidates: [], lotCount: 0, basis: "", now: now).text, "家里还没记东西。买了什么跟我说一句，我来记着到期。")
        XCTAssertEqual(BriefLocal.compose(candidates: [], lotCount: 4, basis: "", now: now).text, "暂时没有新的提醒，其他安排和记录都在下面。")
        XCTAssertEqual(BriefLocal.compose(candidates: [], lotCount: 4, basis: "", now: at(20)).text, "暂时没有新的提醒，其他安排和记录都在下面。")
        XCTAssertTrue(BriefLocal.compose(candidates: [], lotCount: 4, basis: "", now: now).actions.isEmpty)
    }

    // MARK: The model's reply

    private func candidates() -> (lot: BriefCandidate, task: BriefCandidate) {
        (BriefCandidate(target: .lot(UUID()), kind: .expiringSoon, name: "红枣酸奶", detail: "后天到期", quantity: 2, unit: "瓶",
                        daysLeft: 2, location: "冷藏", isMedicine: false),
         BriefCandidate(target: .task(UUID()), kind: .dueTask, name: "热剩饭", detail: "已到时间", quantity: nil, unit: nil,
                        daysLeft: nil, location: nil, isMedicine: false))
    }

    func testAModelReplyIsAcceptedOnlyInsideTheClosedSet() throws {
        let (lot, task) = candidates()
        let reply = """
        ```json
        {"target":"\(lot.target.key)","text":"今晚把红枣酸奶喝了吧，它后天到期。","actions":[
          {"label":"喝完了","effect":"close_depleted","value":null},
          {"label":"喝了一瓶","effect":"adjust_quantity","value":1},
          {"label":"再放两天","effect":"snooze","value":2},
          {"label":"其他","effect":"snooze","value":1}]}
        ```
        """
        let parsed = try XCTUnwrap(BriefModelReply.parse(reply, candidates: [lot, task]))
        XCTAssertEqual(parsed.target, lot.target)
        XCTAssertEqual(parsed.text, "今晚把红枣酸奶喝了吧，它后天到期。")
        XCTAssertEqual(parsed.actions.map(\.label), ["喝完了", "喝了一瓶", "再放两天"], "at most three, never a button called 其他")
        XCTAssertEqual(parsed.actions.map(\.effect), [.closeLot(.depleted), .usedSome(1), .snooze(days: 2)])
    }

    func testBadPartsOfAReplyAreDroppedAndBadWholesAreRefused() throws {
        let (lot, task) = candidates()
        func parse(_ json: String) -> BriefModelReply.Parsed? {
            BriefModelReply.parse(json, candidates: [lot, task])
        }
        // A target that isn't a candidate is refused; no target at all is an overview without buttons.
        XCTAssertNil(parse(#"{"target":"lot:\#(UUID().uuidString)","text":"这是一句话，很正常。","actions":[]}"#))
        let overview = parse(#"{"text":"没有目标的一句话。","actions":[{"label":"做完了","effect":"complete_task","value":null}]}"#)
        XCTAssertNotNil(overview)
        XCTAssertNil(overview?.target)
        XCTAssertEqual(overview?.actions.isEmpty, true)
        XCTAssertNil(parse("完全不是 JSON"))
        // A sentence that is empty or far too long.
        XCTAssertNil(parse(#"{"target":"\#(lot.target.key)","text":"好","actions":[]}"#))
        XCTAssertNil(parse(#"{"target":"\#(lot.target.key)","text":"\#(String(repeating: "很", count: 130))","actions":[]}"#))
        // Effects the thing can't take, values out of range, unknown effects.
        let mixed = try XCTUnwrap(parse("""
        {"target":"\(lot.target.key)","text":"红枣酸奶后天到期，早点喝掉吧。","actions":[
          {"label":"做完了","effect":"complete_task","value":null},
          {"label":"用掉五瓶","effect":"adjust_quantity","value":5},
          {"label":"用掉零瓶","effect":"adjust_quantity","value":0},
          {"label":"放一年","effect":"snooze","value":365},
          {"label":"格式化","effect":"delete_everything","value":null},
          {"label":"看看","effect":"open_detail","value":null}]}
        """))
        XCTAssertEqual(mixed.actions.map(\.effect), [.openDetail])
        // Tasks take task effects only, and minutes are bounded.
        let taskReply = try XCTUnwrap(parse("""
        {"target":"\(task.target.key)","text":"热剩饭到点了，热了吗？","actions":[
          {"label":"扔掉了","effect":"close_discarded","value":null},
          {"label":"热好了","effect":"complete_task","value":null},
          {"label":"马上","effect":"snooze_task","value":1},
          {"label":"半小时后","effect":"snooze_task","value":30}]}
        """))
        XCTAssertEqual(taskReply.actions.map(\.effect), [.completeTask, .remindLater(minutes: 30)])
    }

    func testTheRequestCarriesTheSituationAndTheInstructionsNameTheClosedSet() throws {
        let (lot, _) = candidates()
        let request = BriefModelReply.request(candidates: [lot], greeting: "早上好", now: at(9))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
        XCTAssertEqual(json["greeting"] as? String, "早上好")
        let items = try XCTUnwrap(json["action_targets"] as? [[String: Any]])
        XCTAssertEqual(items.first?["key"] as? String, lot.target.key)
        XCTAssertEqual(items.first?["kind"] as? String, "expiring_soon")
        for effect in ["close_depleted", "close_discarded", "close_gifted", "adjust_quantity", "snooze", "complete_task", "snooze_task", "open_detail"] {
            XCTAssertTrue(BriefModelReply.instructions().contains(effect), effect)
        }
    }

    // MARK: Snoozes

    func testSnoozeKeepsAThingOutOfTheSentenceUntilItsTime() {
        let store = defaults()
        let now = at(9)
        let target = BriefTarget.lot(UUID())
        BriefSnoozes.snooze(target, days: 0, now: now, defaults: store)
        XCTAssertTrue(BriefSnoozes.active(now: now, defaults: store).contains(target.key))
        XCTAssertTrue(BriefSnoozes.active(now: at(23, 30), defaults: store).contains(target.key))
        XCTAssertFalse(BriefSnoozes.active(now: at(7, dayOffset: 1), defaults: store).contains(target.key), "back tomorrow morning")

        let three = BriefTarget.task(UUID())
        BriefSnoozes.snooze(three, days: 3, now: now, defaults: store)
        XCTAssertTrue(BriefSnoozes.active(now: at(9, dayOffset: 2), defaults: store).contains(three.key))
        XCTAssertFalse(BriefSnoozes.active(now: at(1, dayOffset: 3), defaults: store).contains(three.key))

        let later = BriefTarget.task(UUID())
        BriefSnoozes.snooze(later, until: now.addingTimeInterval(600), defaults: store)
        XCTAssertFalse(BriefSnoozes.active(now: now.addingTimeInterval(601), defaults: store).contains(later.key))
    }

    // MARK: Buttons

    func testButtonsChangeTheRealDataAndTheNextThingTakesOver() async throws {
        let container = try ButlerStore.makePreviewContainer()
        let actions = InventoryActions(modelContainer: container)
        try actions.add([.init(name: "土鸡蛋", quantity: 6, unit: "枚", storage: "冷藏", packageExpiry: Date.now.addingTimeInterval(-4 * 86_400), plannedUseBy: nil)],
                        sourceText: "测试")
        try actions.add([.init(name: "红枣酸奶", quantity: 3, unit: "瓶", storage: "冷藏", packageExpiry: Date.now.addingTimeInterval(2 * 86_400), plannedUseBy: nil)],
                        sourceText: "测试")
        func facts() throws -> [LotFacts] {
            let context = ModelContext(container)
            let products = try context.fetch(FetchDescriptor<CatalogProduct>())
            return try context.fetch(FetchDescriptor<InventoryLot>()).filter { $0.state == .active }.map { lot in
                LotFacts(lot: lot, product: products.first { $0.id == lot.productID })
            }
        }
        let store = defaults()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let runner = BriefActionRunner(container: container, reminders: ReminderStore(file: file, schedules: false), defaults: store)

        var current = try facts()
        let egg = try XCTUnwrap(current.first { $0.name == "土鸡蛋" })
        let yogurt = try XCTUnwrap(current.first { $0.name == "红枣酸奶" })

        // Used one of three: two are left, and the count can't be taken to zero this way.
        let outcome = await runner.run(BriefAction(label: "喝了一瓶", effect: .usedSome(1)), target: .lot(yogurt.id), facts: current)
        XCTAssertEqual(outcome, .done)
        current = try facts()
        XCTAssertEqual(current.first { $0.name == "红枣酸奶" }?.quantity, 2)
        let tooMany = await runner.run(BriefAction(label: "全喝了", effect: .usedSome(2)), target: .lot(yogurt.id), facts: current)
        if case .failed = tooMany {} else { XCTFail("using every last one is 已吃完, not a quantity change") }

        // Threw the eggs away: they leave the shelf, so the yogurt is next.
        let thrown = await runner.run(BriefAction(label: "扔掉了", effect: .closeLot(.discarded)), target: .lot(egg.id), facts: current)
        XCTAssertEqual(thrown, .done)
        current = try facts()
        XCTAssertNil(current.first { $0.name == "土鸡蛋" })
        let agenda = HomeAgenda.build(lots: current, reminders: [], events: [], now: .now)
        XCTAssertEqual(BriefCandidates.make(facts: current, agenda: agenda, now: .now).first?.name, "红枣酸奶")

        // 先放放 doesn't touch the item at all.
        let snoozed = await runner.run(BriefAction(label: "先放放", effect: .snooze(days: 0)), target: .lot(yogurt.id), facts: current)
        XCTAssertEqual(snoozed, .done)
        XCTAssertEqual(try facts().count, 1)
        XCTAssertTrue(BriefCandidates.make(facts: current, agenda: agenda, now: .now, snoozed: BriefSnoozes.active(defaults: store)).isEmpty)

        // A task button can't act on an item and the other way round.
        let wrong = await runner.run(BriefAction(label: "做完了", effect: .completeTask), target: .lot(yogurt.id), facts: current)
        if case .failed = wrong {} else { XCTFail("completeTask on a lot must be refused") }
        let opened = await runner.run(BriefAction(label: "看看", effect: .openDetail), target: .lot(yogurt.id), facts: current)
        XCTAssertEqual(opened, .open)
    }

    func testTaskButtonsCompleteAndPostpone() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let reminders = ReminderStore(file: file, schedules: false)
        let task = TimedReminder(text: "取快递", fireDate: Date.now.addingTimeInterval(-600))
        try reminders.add(task)
        let store = defaults()
        let runner = BriefActionRunner(container: try ButlerStore.makePreviewContainer(), reminders: reminders, defaults: store)

        let completed = await runner.run(BriefAction(label: "做完了", effect: .completeTask), target: .task(task.id), facts: [])
        XCTAssertEqual(completed, .done)
        XCTAssertEqual(reminders.reminder(id: task.id)?.status, .completed)
        let gone = await runner.run(BriefAction(label: "做完了", effect: .completeTask), target: .task(UUID()), facts: [])
        if case .failed = gone {} else { XCTFail("an unknown task can't be completed") }
    }

    // MARK: Service

    func testWithoutTheModelTheServiceStillHasAnHonestSentenceAndDoesNotRepeatItself() {
        let store = defaults()
        let service = BriefService(defaults: store)
        let now = at(9)
        let egg = BriefCandidate(target: .lot(UUID()), kind: .expired, name: "土鸡蛋", detail: "已过期 4 天", quantity: 6, unit: "枚",
                                 daysLeft: -4, location: nil, isMedicine: false)
        service.update(candidates: [egg], lotCount: 3, taskCount: 1, usesCalendar: false, now: now)
        XCTAssertEqual(service.brief.text, "土鸡蛋已过期 4 天，今天处理掉吧。")
        XCTAssertEqual(service.brief.basis, "依据：家里的 3 样东西 · 1 条提醒")
        XCTAssertFalse(service.isThinking, "no connection: nothing to wait for")

        service.update(candidates: [egg], lotCount: 4, taskCount: 1, usesCalendar: true, now: now)
        XCTAssertEqual(service.brief.basis, "依据：家里的 4 样东西 · 1 条提醒 · 日历", "same situation: only the basis line follows")
        service.update(candidates: [], lotCount: 4, taskCount: 1, usesCalendar: true, now: now)
        XCTAssertNil(service.brief.target)
        XCTAssertEqual(service.brief.actions, [])
    }

    // MARK: Service with the model

    @MainActor
    private final class FakeModel: BriefModel {
        var isAvailable = true
        var reply: () async throws -> String
        private(set) var requests: [String] = []
        init(_ reply: @escaping () async throws -> String) { self.reply = reply }
        func answer(_ request: String, context: BriefContext) async throws -> String {
            requests.append(request)
            return try await reply()
        }
    }

    private func candidate(_ name: String = "红枣酸奶") -> BriefCandidate {
        BriefCandidate(target: .lot(UUID()), kind: .expiringSoon, name: name, detail: "后天到期", quantity: 3, unit: "瓶",
                       daysLeft: 2, location: "冷藏", isMedicine: false)
    }

    private func reply(for candidate: BriefCandidate, text: String = "今晚把红枣酸奶喝了吧，它后天到期。") -> String {
        """
        {"target":"\(candidate.target.key)","text":"\(text)","actions":[
        {"label":"喝了一瓶","effect":"adjust_quantity","value":1},{"label":"再放两天","effect":"snooze","value":2}]}
        """
    }

    func testAModelThatConnectsAfterTheFirstCardIsStillAsked() async {
        // At launch home builds the card before the conversation services (and the model) exist.
        let item = candidate()
        let service = BriefService(defaults: defaults())
        service.update(candidates: [item], lotCount: 4, taskCount: 0, usesCalendar: false, now: at(19))
        XCTAssertEqual(service.brief.source, .local)
        let model = FakeModel { self.reply(for: item) }
        service.attach(model: model)
        await service.settle()
        XCTAssertEqual(model.requests.count, 1)
        XCTAssertEqual(service.brief.source, .model)
    }

    func testInteractingWithLocalCardKeepsItsActionsWhileBackgroundReplyIsCached() async {
        let storage = defaults()
        let item = candidate()
        let service = BriefService(defaults: storage)
        service.attach(model: FakeModel { self.reply(for: item) })
        let now = at(19)
        service.update(candidates: [item], lotCount: 4, taskCount: 0, usesCalendar: false, now: now)
        let visible = service.brief
        service.beginInteraction()
        await service.settle()
        XCTAssertEqual(service.brief, visible, "background completion must not replace a touched card")
        XCTAssertFalse(service.isThinking)
        let reopened = BriefService(defaults: storage)
        reopened.update(candidates: [item], lotCount: 4, taskCount: 0, usesCalendar: false, now: now)
        XCTAssertEqual(reopened.brief.source, .model, "the background work still completes and can be reused")
    }

    func testNewSituationCanUpdateAfterUserFinishedPreviousAction() async {
        let storage = defaults()
        let first = candidate()
        let second = candidate("鸡蛋")
        let model = FakeModel { self.reply(for: first) }
        let service = BriefService(defaults: storage)
        service.attach(model: model)
        service.update(candidates: [first], lotCount: 2, taskCount: 0, usesCalendar: false, now: at(19))
        service.beginInteraction()
        await service.settle()
        model.reply = { self.reply(for: second, text: "鸡蛋也该处理了。") }
        service.endInteraction()
        service.update(candidates: [second], lotCount: 1, taskCount: 0, usesCalendar: false, now: at(19))
        await service.settle()
        XCTAssertEqual(service.brief.target, second.target)
        XCTAssertEqual(service.brief.source, .model)
    }

    func testTheModelChoosesTheSentenceAndTheButtonsAndItIsAskedOncePerSituation() async throws {
        let store = defaults()
        let item = candidate()
        let model = FakeModel { self.reply(for: item) }
        let service = BriefService(defaults: store)
        service.attach(model: model)
        let now = at(19)

        service.update(candidates: [item], lotCount: 4, taskCount: 0, usesCalendar: false, now: now)
        XCTAssertTrue(service.isThinking)
        XCTAssertEqual(service.brief.source, .local, "an honest local sentence is there while the model thinks")
        await service.settle()
        XCTAssertFalse(service.isThinking)
        XCTAssertEqual(service.brief.source, .model)
        XCTAssertEqual(service.brief.text, "今晚把红枣酸奶喝了吧，它后天到期。")
        XCTAssertEqual(service.brief.actions.map(\.label), ["喝了一瓶", "再放两天"])
        XCTAssertEqual(service.brief.actions.map(\.effect), [.usedSome(1), .snooze(days: 2)])
        XCTAssertEqual(service.brief.target, item.target)
        XCTAssertEqual(model.requests.count, 1)
        XCTAssertTrue(model.requests[0].contains(item.target.key))

        // Same situation again: nothing new is asked.
        service.update(candidates: [item], lotCount: 4, taskCount: 0, usesCalendar: false, now: at(19, 20))
        XCTAssertEqual(model.requests.count, 1)

        // A new service (the app was reopened) in the same situation reuses the answer without asking.
        let reopened = BriefService(defaults: store)
        let other = FakeModel { XCTFail("must not be asked again"); return "" }
        reopened.attach(model: other)
        reopened.update(candidates: [item], lotCount: 4, taskCount: 0, usesCalendar: false, now: at(19, 29))
        XCTAssertEqual(reopened.brief.source, .model)
        XCTAssertEqual(reopened.brief.text, "今晚把红枣酸奶喝了吧，它后天到期。")
        XCTAssertFalse(reopened.isThinking)
        XCTAssertTrue(other.requests.isEmpty)
    }

    func testAnUnusableUnreachableOrSlowModelLeavesTheLocalSentence() async throws {
        let item = candidate()
        let now = at(9)

        let garbage = BriefService(defaults: defaults())
        garbage.attach(model: FakeModel { "抱歉，我没法做到" })
        garbage.update(candidates: [item], lotCount: 1, taskCount: 0, usesCalendar: false, now: now)
        await garbage.settle()
        XCTAssertEqual(garbage.brief.source, .local)
        XCTAssertFalse(garbage.isThinking)
        XCTAssertFalse(garbage.brief.actions.isEmpty, "the local buttons work once the wait is over")

        let failing = BriefService(defaults: defaults())
        failing.attach(model: FakeModel { throw URLError(.notConnectedToInternet) })
        failing.update(candidates: [item], lotCount: 1, taskCount: 0, usesCalendar: false, now: now)
        await failing.settle()
        XCTAssertEqual(failing.brief.source, .local)
        XCTAssertFalse(failing.isThinking)

        let slow = BriefService(defaults: defaults(), timeout: 0.2)
        slow.attach(model: FakeModel { try await Task.sleep(for: .seconds(30)); return "" })
        slow.update(candidates: [item], lotCount: 1, taskCount: 0, usesCalendar: false, now: now)
        await slow.settle()
        XCTAssertEqual(slow.brief.source, .local)
        XCTAssertFalse(slow.isThinking, "a slow network never holds the buttons back for long")

        let signedOut = FakeModel { XCTFail("not signed in"); return "" }
        signedOut.isAvailable = false
        let quiet = BriefService(defaults: defaults())
        quiet.attach(model: signedOut)
        quiet.update(candidates: [item], lotCount: 1, taskCount: 0, usesCalendar: false, now: now)
        XCTAssertFalse(quiet.isThinking)
        XCTAssertTrue(signedOut.requests.isEmpty)
    }

    func testAnAnswerForYesterdaysSituationIsNotShownForTodays() async throws {
        let egg = candidate("土鸡蛋")
        let yogurt = candidate("红枣酸奶")
        let model = FakeModel {
            try await Task.sleep(for: .milliseconds(150))
            return self.reply(for: egg, text: "土鸡蛋放太久了，今天处理掉吧。")
        }
        let service = BriefService(defaults: defaults())
        service.attach(model: model)
        service.update(candidates: [egg], lotCount: 2, taskCount: 0, usesCalendar: false, now: at(9))
        // The eggs are dealt with before the model answers: the yogurt is what matters now.
        service.update(candidates: [yogurt], lotCount: 1, taskCount: 0, usesCalendar: false, now: at(9))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(service.brief.target, yogurt.target)
        XCTAssertNotEqual(service.brief.text, "土鸡蛋放太久了，今天处理掉吧。")
    }

    // MARK: Day list

    private func agenda(_ lots: [LotFacts], reminders: [TimedReminder] = [], now: Date) -> HomeAgenda {
        HomeAgenda.build(lots: lots, reminders: reminders, events: [], now: now)
    }

    func testTodayListPutsWhatNeedsHandlingBeforeTheSchedule() {
        let now = at(10)
        let eggs = lot("土鸡蛋", quantity: 6, package: day(-4, from: now), place: "冷藏", now: now)
        let yogurt = lot("红枣酸奶", package: day(2, from: now), place: "冷藏", now: now)
        let water = lot("七鲜饮用纯净水", quantity: 1, category: "household", place: "卫生间", now: now)
        let pending = TimedReminder(text: "热剩饭", fireDate: at(9), createdAt: day(-1, from: now))
        let noon = TimedReminder(text: "取快递", fireDate: at(15))
        let medicine = TimedReminder(text: "吃药", fireDate: at(21), repeats: .daily, createdAt: day(-3, from: now))
        let a = agenda([eggs, yogurt, water], reminders: [pending, noon, medicine], now: now)

        let list = HomeList.build(day: a.today, agenda: a, facts: [eggs, yogurt, water], now: now)
        XCTAssertEqual(list.rows.map(\.title), ["土鸡蛋", "热剩饭", "红枣酸奶", "七鲜饮用纯净水", "取快递", "吃药"])
        XCTAssertEqual(list.rows.first?.subtitle, "已过期 4 天 · 6 瓶 · 冷藏")
        XCTAssertEqual(list.rows.first?.action, "处理")
        XCTAssertTrue(list.rows.first?.isAlert ?? false)
        XCTAssertEqual(list.rows[1].action, "查看")
        XCTAssertEqual(list.rows[2].subtitle, "后天到期 · 2 瓶 · 冷藏")
        XCTAssertEqual(list.rows[3].subtitle, "只剩 1 瓶 · 卫生间 · 记得买")
        XCTAssertEqual(list.rows[4].lead, "15:00")
        XCTAssertEqual(list.rows[5].lead, "21:00")
    }

    func testTheThingTheButlerSaidIsNotListedAgain() {
        let now = at(10)
        let eggs = lot("土鸡蛋", quantity: 6, package: day(-4, from: now), now: now)
        let noon = TimedReminder(text: "取快递", fireDate: at(15))
        let a = agenda([eggs], reminders: [noon], now: now)
        let list = HomeList.build(day: a.today, agenda: a, facts: [eggs], featured: .lot(eggs.id), now: now)
        XCTAssertEqual(list.rows.map(\.title), ["取快递"])
    }

    func testTimedThingsThatAlreadyHappenedLeaveTheListAndFinishedTasksGatherBelow() throws {
        let now = at(14)
        let morning = TimedReminder(text: "早会提醒", fireDate: at(8), createdAt: day(-1, from: now))
        var done = TimedReminder(text: "寄材料", fireDate: at(12), createdAt: day(-1, from: now))
        done.status = .completed
        done.activity = [ReminderActivity(date: at(12, 30), kind: "completed", detail: "完成")]
        let later = TimedReminder(text: "接孩子", fireDate: at(17))
        let a = agenda([], reminders: [morning, done, later], now: now)
        let list = HomeList.build(day: a.today, agenda: a, facts: [], now: now)
        // The morning one has come due and is unfinished: it stays as a task to look at, not as schedule.
        XCTAssertEqual(list.rows.map(\.title), ["早会提醒", "接孩子"])
        XCTAssertEqual(list.rows.first?.action, "查看")
        XCTAssertEqual(list.completed.map(\.title), ["寄材料"])
        XCTAssertTrue(list.completed.first?.isCompleted ?? false)
    }

    func testEveningLooksAheadToTomorrowMorning() {
        let now = at(20, 30)
        let medicine = TimedReminder(text: "吃药", fireDate: at(21), repeats: .daily, createdAt: day(-3, from: now))
        let umbrella = TimedReminder(text: "带伞", fireDate: at(7, 30, dayOffset: 1))
        let lunch = TimedReminder(text: "订午饭", fireDate: at(11, dayOffset: 1))
        let a = agenda([], reminders: [medicine, umbrella, lunch], now: now)
        let list = HomeList.build(day: a.today, agenda: a, facts: [], now: now)
        XCTAssertEqual(list.rows.map(\.title), ["吃药", "带伞"], "night shows tonight and tomorrow's early start")
        XCTAssertEqual(list.rows.last?.lead, "明早")
        XCTAssertEqual(list.rows.last?.subtitle, "07:30 提醒")
        XCTAssertFalse(list.rows.contains { $0.title == "订午饭" }, "only early things")
    }

    func testAnotherDayListsWholeDayThingsFirstThenByTime() {
        let now = at(10)
        let yogurt = lot("红枣酸奶", package: day(3, from: now), now: now)
        let late = TimedReminder(text: "吃药", fireDate: at(21, dayOffset: 3))
        let early = TimedReminder(text: "带伞", fireDate: at(8, dayOffset: 3))
        let a = agenda([yogurt], reminders: [late, early], now: now)
        let list = HomeList.build(day: day(3, from: now), agenda: a, facts: [yogurt], now: now)
        XCTAssertEqual(list.rows.map(\.title), ["红枣酸奶", "带伞", "吃药"])
        XCTAssertEqual(list.rows.first?.subtitle, "3 天后到期 · 2 瓶")
        XCTAssertTrue(HomeList.build(day: day(5, from: now), agenda: a, facts: [yogurt], now: now).rows.isEmpty)
    }

    func testQuietLines() throws {
        let now = at(10)
        let apples = lot("苹果", quantity: 5, package: day(4, from: now), place: "常温", now: now)
        let milk = lot("牛奶", package: day(30, from: now), place: "冷藏", now: now)
        let ham = lot("火腿", package: day(30, from: now), place: "冷藏", now: now)
        let pickup = TimedReminder(text: "取快递", fireDate: at(15, dayOffset: 2))
        let daily = TimedReminder(text: "吃药", fireDate: at(21), repeats: .daily, createdAt: day(-3, from: now))
        let a = agenda([apples, milk, ham], reminders: [pickup, daily], now: now)
        let week = try XCTUnwrap(HomeList.weekAhead(agenda: a))
        XCTAssertEqual(week.count, 2, "the daily routine isn't counted")
        XCTAssertTrue(week.preview.contains("取快递"))
        XCTAssertNil(HomeList.weekAhead(agenda: agenda([], now: now)))
        XCTAssertEqual(HomeList.places(facts: [apples, milk, ham]), "冷藏 2 · 常温 1")
    }
}

// Home now reads a year of agenda on every refresh; it has to stay quick with a lot of data.
@MainActor
final class HomeAgendaCostTests: XCTestCase {
    func testAYearOfAgendaForABusyHomeIsBuiltQuickly() {
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var lots: [LotFacts] = []
        for index in 0..<200 {
            let product = CatalogProduct(canonicalName: "物品\(index)", categoryRawValue: index % 9 == 0 ? "household" : nil)
            let lot = InventoryLot(productID: product.id, quantity: 1 + index % 4, unit: "个")
            lot.packageExpiryDate = calendar.date(byAdding: .day, value: index * 2 - 20, to: now)
            lot.storageLocation = ["冷藏", "冷冻", "常温", "卫生间"][index % 4]
            lots.append(LotFacts(lot: lot, product: product, now: now, calendar: calendar))
        }
        var reminders: [TimedReminder] = []
        for index in 0..<40 {
            var task = TimedReminder(text: "任务\(index)", fireDate: now.addingTimeInterval(Double(index) * 3600),
                                     repeats: index % 3 == 0 ? .daily : index % 3 == 1 ? .weekly : .none, createdAt: now.addingTimeInterval(-86_400))
            if index % 10 == 0 { task.phases = [ReminderPhase(startDate: now, intervalMinutes: 10, maxOccurrences: 30)] }
            reminders.append(task)
        }
        let started = Date()
        let agenda = HomeAgenda.build(lots: lots, reminders: reminders, events: [], now: now, dayCount: 366)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(agenda.days.count, 366)
        XCTAssertLessThan(elapsed, 3.0, "took \(elapsed)s")
        print("year agenda for 200 items and 40 tasks: \(elapsed)s")
    }
}

/// The confirmation card speaks plainly: when it will remind, and nothing about how the rules are stored.
final class PlainReminderSummaryTests: XCTestCase {
    private var zone: TimeZone { .current }
    private func date(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0, from now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: dayOffset, to: calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start)!)!
    }

    func testASingleReminderIsOneShortLine() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var task = TimedReminder(text: "购买 Claude 订阅", fireDate: date(0, 20, from: now))
        task.timeZoneIdentifier = zone.identifier
        XCTAssertEqual(ReminderSchedule.friendlySummary(task, now: now), "今天 20:00 提醒一次")
        task.fireDate = date(1, 8, 30, from: now)
        XCTAssertEqual(ReminderSchedule.friendlySummary(task, now: now), "明天 08:30 提醒一次")
        task.repeats = .daily
        XCTAssertEqual(ReminderSchedule.friendlySummary(task, now: now), "明天 08:30 起，每天提醒")
    }

    func testNothingInternalLeaksIntoTheCard() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var task = TimedReminder(text: "寄材料", fireDate: date(0, 18, from: now))
        task.timeZoneIdentifier = zone.identifier
        task.phases = [ReminderPhase(startDate: date(0, 18, from: now), intervalMinutes: 10, maxOccurrences: 6),
                       ReminderPhase(startDate: date(2, 20, from: now), repeats: .daily)]
        task.endDate = date(4, 20, from: now)
        let text = ReminderSchedule.friendlySummary(task, now: now)
        XCTAssertTrue(text.contains("第 1 段：今天 18:00 起，每 10 分钟提醒，最多 6 次"), text)
        XCTAssertTrue(text.contains("第 2 段："), text)
        XCTAssertTrue(text.contains("之后不再提醒"), text)
        for internalText in ["时区", "阶段", "预览", "以最先达到的为准", "未设全局停止时间", zone.identifier] {
            XCTAssertFalse(text.contains(internalText), internalText)
        }
        XCTAssertLessThanOrEqual(text.split(separator: "\n").count, 4)
    }

    func testAForeignTimeZoneIsSaidOnceAndOnlyWhenItDiffers() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let other = TimeZone.current.identifier == "Asia/Tokyo" ? "Europe/Paris" : "Asia/Tokyo"
        var task = TimedReminder(text: "会议", fireDate: now.addingTimeInterval(7200))
        task.timeZoneIdentifier = other
        XCTAssertTrue(ReminderSchedule.friendlySummary(task, now: now).contains("按 \(other) 的时间"))
    }
}

extension ButlerBriefTests {
    func testTheLocalCardAlsoMentionsWhatElseNeedsALook() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func item(_ name: String, _ kind: BriefCandidate.Kind) -> BriefCandidate {
            BriefCandidate(target: .lot(UUID()), kind: kind, name: name, detail: "已过期 2 天", quantity: 2, unit: "瓶",
                           daysLeft: -2, location: nil, isMedicine: false)
        }
        let one = BriefLocal.compose(candidates: [item("土鸡蛋", .expired)], lotCount: 3, basis: "", now: now)
        XCTAssertFalse(one.text.contains("另外"))
        let three = BriefLocal.compose(candidates: [item("土鸡蛋", .expired), item("红枣酸奶", .expiringSoon), item("纯净水", .lowStock)],
                                       lotCount: 3, basis: "", now: now)
        XCTAssertTrue(three.text.hasSuffix("另外红枣酸奶、纯净水也要留意。"), three.text)
        XCTAssertEqual(three.target, one.target == nil ? nil : three.target)
        let five = BriefLocal.compose(candidates: (1...5).map { item("物品\($0)", .expiringSoon) }, lotCount: 5, basis: "", now: now)
        XCTAssertTrue(five.text.contains("另外物品2、物品3等 4 样也要留意"), five.text)
    }
}
