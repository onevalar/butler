import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor
final class ChatSessionsTests: XCTestCase {
    func testHomeAndGeneralCanFindCorrectionsAcrossPagesWithoutReadingDraftsOrExecutingHistory() throws {
        let (_, directory, _, reminders, sessions) = try fixture()
        let old = ChatTurn(question: "这周出差，周日回来", answer: "知道了", date: Date(timeIntervalSince1970: 100))
        let correction = ChatTurn(question: "不是周日，是周六回来", answer: "按周六理解", date: Date(timeIntervalSince1970: 200))
        var unfinished = ChatTurn(question: "尚未完成的请求", answer: "不能使用的片段")
        unfinished.replyState = .answering
        try ChatSessionFiles(scope: .general, root: directory).saveTurns([old])
        try ChatSessionFiles(scope: .settings, root: directory).saveTurns([correction, unfinished])
        let brief = ButlerBrief(greeting: "", text: "明早出差，今晚准备行李。", basis: "", target: nil,
                                actions: [], source: .model, rationale: "已记录的出行安排")
        let home = sessions.chat(for: .brief(BriefConversation(brief: brief, day: "2026-10-03")))
        home.draft = "还未发送的个人安排"
        let tools = try XCTUnwrap(home.tools)
        let history = try XCTUnwrap(tools.conversation?())
        XCTAssertEqual(history.turns.map(\.id), [old.id, correction.id])
        XCTAssertEqual(history.sources[correction.id], .settings)
        XCTAssertEqual(sessions.chat(for: .general).tools?.conversation?().turns.map(\.id), [old.id, correction.id])
        XCTAssertTrue(tools.pending.isEmpty)
        XCTAssertTrue(try reminders.taskSnapshot().isEmpty)
        XCTAssertTrue(home.scopeContext.contains("已记录的出行安排"))
        var sameCard = brief; sameCard.rationale = "另一段解释"
        XCTAssertTrue(home === sessions.chat(for: .brief(BriefConversation(brief: sameCard, day: "2026-10-03"))))
        XCTAssertTrue(sessions.chat(for: .lot(UUID())).tools?.conversation?().turns.isEmpty == true,
                      "Object pages retain their scoped history")
    }

    func testUnreadableSharedHistoryIsNotReportedAsAnEmptyHistory() throws {
        let (_, directory, _, _, sessions) = try fixture()
        let files = ChatSessionFiles(scope: .settings, root: directory)
        try files.prepare()
        try Data("broken".utf8).write(to: files.transcript)
        let archive = sessions.householdArchive()
        XCTAssertNotNil(archive.overview()["error"])
        XCTAssertNotNil(archive.search("出差", from: nil, to: nil, limit: 10)["error"])
        XCTAssertNotNil(archive.read(fromTurn: nil, toTurn: nil, from: nil, to: nil, cursor: nil)["error"])
    }

    func testSyncedHistoryReloadKeepsLocalDraftPhotosAndPendingWithoutExecutingHistory() async throws {
        let (_, directory, _, reminders, sessions) = try fixture()
        let chat = sessions.chat(for: .general), tools = try XCTUnwrap(chat.tools)
        chat.draft = "还没发出的新想法"; chat.photos = [Data([7, 4, 2])]
        tools.add(.note(.init(id: UUID(), title: "待确认", text: "还不能保存", quantity: nil, revision: 1)), title: "本机提案", detail: nil)
        let pending = tools.pending.map(\.id), notes = tools.notes.records, tasks = try reminders.taskSnapshot()
        let remote = ChatTurn(question: "确认全部操作", answer: "历史内容", receipts: ["以前已设置闹钟"])
        let local = ChatSyncData(root: directory, isWorking: { sessions.working }, didImport: { sessions.reloadSyncedHistory($0) })
        try local.replace(.init(kind: .chat, id: remote.id), expected: nil,
            with: SyncRecord.encode(SyncedChatTurn(scope: .general, turn: remote)))
        XCTAssertEqual(chat.turns, [remote]); XCTAssertEqual(chat.draft, "还没发出的新想法")
        XCTAssertEqual(chat.photos, [Data([7, 4, 2])]); XCTAssertEqual(tools.pending.map(\.id), pending)
        XCTAssertEqual(tools.notes.records, notes); XCTAssertEqual(try reminders.taskSnapshot(), tasks)
    }

    func testWholeBriefConversationCarriesAllSubjectsAndNeverBecomesPrimaryLotChat() throws {
        let (_, _, _, _, sessions) = try fixture()
        let id = UUID()
        let brief = ButlerBrief(greeting: "早上好", text: "牛奶明天到期，青菜今晚吃；下午记得取快递。", basis: "", target: .lot(id),
                                actions: [.init(label: "喝完了", effect: .closeLot(.depleted))], source: .local)
        let scope = ChatScope.brief(BriefConversation(brief: brief, day: "2026-09-29"))
        let chat = sessions.chat(for: scope)
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(chat.scopeContext.utf8)) as? [String: Any])
        XCTAssertEqual(chat.contextTitle, "关于这条管家提醒")
        XCTAssertEqual(context["brief_text"] as? String, brief.text)
        XCTAssertEqual(context["source"] as? String, "home_brief")
        XCTAssertNil(context["lot_id"])
        XCTAssertNil(context["task_id"])
        XCTAssertFalse(chat === sessions.chat(for: .lot(id)))
        XCTAssertFalse(ButlerChat.allowsLocalReminderCreation(in: scope))
        XCTAssertTrue(chat === sessions.chat(for: .brief(BriefConversation(brief: brief, day: "2026-09-29"))))
        var updated = brief
        updated.text = "牛奶已经喝完，明天处理青菜。"
        let other = sessions.chat(for: .brief(BriefConversation(brief: updated, day: "2026-09-29")))
        XCTAssertFalse(chat === other)
        XCTAssertTrue(chat.scopeContext.contains("下午记得取快递"))
        XCTAssertFalse(chat.scopeContext.contains("牛奶已经喝完"))
    }

    func testBriefSnapshotAndIndependentHistorySurviveReloadIncludingNoObjectReminder() throws {
        let (container, directory, defaults, reminders, sessions) = try fixture()
        let brief = ButlerBrief(greeting: "早上好", text: "下午下雨，出门记得带伞。", basis: "", target: nil, actions: [], source: .local)
        let scope = ChatScope.brief(BriefConversation(brief: brief, day: "2026-09-29"))
        let chat = sessions.chat(for: scope)
        chat.draft = "那就晚些出门"
        let turn = ChatTurn(question: "今天这条提醒", answer: "可以调整")
        try ChatSessionFiles(scope: scope, root: directory).saveTurns([turn])
        let restoredScope = try XCTUnwrap(ChatSessionFiles.savedScopes(in: directory).first { $0 == scope })
        let restored = ButlerChat(container: container, reminders: reminders, scope: restoredScope,
                                  connection: chat.connection, jev: chat.jev, directory: directory, defaults: defaults)
        XCTAssertEqual(restored.turns, [turn])
        XCTAssertEqual(restored.draft, "那就晚些出门")
        XCTAssertTrue(restored.scopeContext.contains(brief.text))
        XCTAssertTrue(sessions.chat(for: .general).turns.isEmpty)
        XCTAssertNotEqual(scope, .brief(BriefConversation(brief: brief, day: "2026-09-30")))
        XCTAssertFalse(scope.key.contains("/"))
        XCTAssertFalse(scope.key.contains(brief.text))
    }

    func testUnsaveableTextConfirmationOrCancellationNeverConsumesPendingChanges() throws {
        for text in ["确认", "取消"] {
            let (_, directory, _, _, sessions) = try fixture()
            let chat = sessions.chat(for: .general), tools = try XCTUnwrap(chat.tools)
            tools.add(.note(.init(id: UUID(), title: "待核对", text: "不应写入", quantity: nil, revision: 1)), title: "记一条笔记", detail: nil)
            let pending = tools.pending.map(\.id), notes = tools.notes.records
            let files = ChatSessionFiles(scope: .general, root: directory)
            let pendingBytes = try Data(contentsOf: files.pending)
            try FileManager.default.createDirectory(at: files.transcript, withIntermediateDirectories: false)
            chat.draft = text
            XCTAssertTrue(chat.canSend)
            chat.send()
            XCTAssertEqual(chat.draft, text)
            XCTAssertTrue(chat.turns.isEmpty)
            XCTAssertFalse(chat.working)
            XCTAssertNotNil(chat.error)
            XCTAssertEqual(tools.pending.map(\.id), pending)
            XCTAssertEqual(tools.notes.records, notes)
            XCTAssertEqual(try Data(contentsOf: files.pending), pendingBytes)
        }
    }

    func testPhotoStorageFailurePreservesInputWithoutStartingReply() throws {
        let (_, directory, _, _, sessions) = try fixture()
        let chat = sessions.chat(for: .general)
        let files = ChatSessionFiles(scope: .general, root: directory)
        try Data([44]).write(to: files.photos) // A file blocks creation of the photo directory.
        chat.draft = "我有什么衣服"
        chat.photos = [Data([1, 7]), Data([9, 2, 3])]
        XCTAssertTrue(chat.canSend)
        chat.send()
        XCTAssertFalse(chat.working)
        XCTAssertTrue(chat.turns.isEmpty)
        XCTAssertEqual(chat.draft, "我有什么衣服")
        XCTAssertEqual(chat.photos, [Data([1, 7]), Data([9, 2, 3])])
        XCTAssertEqual(try files.loadDraft().photos, chat.photos)
        XCTAssertEqual(try Data(contentsOf: files.photos), Data([44]))
        XCTAssertNotNil(chat.error)
    }

    func testLocalQueryOnlyClearsDraftAfterSavingAndCanRetryStorageFailure() throws {
        let (_, directory, _, _, sessions) = try fixture()
        let chat = sessions.chat(for: .general)
        let files = ChatSessionFiles(scope: .general, root: directory)
        try FileManager.default.createDirectory(at: files.transcript, withIntermediateDirectories: false)
        chat.draft = "我有什么衣服"
        chat.send()
        XCTAssertEqual(chat.draft, "我有什么衣服")
        XCTAssertTrue(chat.turns.isEmpty)
        XCTAssertFalse(chat.working)
        XCTAssertNotNil(chat.error)
        try FileManager.default.removeItem(at: files.transcript)
        chat.send()
        XCTAssertEqual(chat.turns.count, 1)
        XCTAssertFalse(chat.turns[0].answer.isEmpty)
        XCTAssertTrue(chat.draft.isEmpty)
        XCTAssertNil(chat.error)
        XCTAssertEqual(try JSONDecoder().decode([ChatTurn].self, from: Data(contentsOf: files.transcript)), chat.turns)
        XCTAssertEqual(try files.loadDraft().text, "")
    }

    func testUnsaveableListEditKeepsOriginalListAndDraft() throws {
        let (_, directory, _, _, sessions) = try fixture()
        let files = ChatSessionFiles(scope: .general, root: directory)
        let list = ItemCollection(title: "出门要带", items: [
            .init(id: UUID(), name: "雨伞", reason: "下雨"),
            .init(id: UUID(), name: "纸巾", reason: "备用")
        ])
        let original = ChatTurn(question: "带哪些东西", answer: "看这张清单", collection: list)
        try files.saveTurns([original])
        let chat = sessions.chat(for: .general)
        try FileManager.default.removeItem(at: files.transcript)
        try FileManager.default.createDirectory(at: files.transcript, withIntermediateDirectories: false)
        chat.draft = "去掉雨伞"
        XCTAssertTrue(chat.canSend)
        chat.send()
        XCTAssertEqual(chat.turns, [original])
        XCTAssertEqual(chat.latestCollection, list)
        XCTAssertEqual(chat.draft, "去掉雨伞")
        XCTAssertNotNil(chat.error)
        XCTAssertFalse(chat.working)
    }

    func testReplyFailureRestoresOnlyAnUntouchedWholeDraft() async throws {
        // No credentials or network: attaching a photo bypasses the local answer,
        // and the model transport fails at its credential check.
        for scenario in 0..<4 {
            let (_, directory, _, _, sessions) = try fixture()
            let chat = sessions.chat(for: .general)
            chat.jev.prefetchEnabled = false
            XCTAssertFalse(chat.connection.isLoggedIn)
            chat.draft = "  我有什么衣服\n"
            chat.photos = [Data([2, 9])]
            XCTAssertTrue(chat.canSend)
            chat.send()
            XCTAssertTrue(chat.working)
            XCTAssertEqual(chat.replyProgress.turnID, chat.turns.first?.id)
            XCTAssertEqual(chat.turns.first?.replyState, .answering)
            switch scenario {
            case 1: chat.draft = "新的问题"
            case 2: chat.draft = "输入后又删掉"; chat.draft = ""
            case 3: chat.photos = [Data([8, 6, 4])]
            default: break
            }
            let deadline = ContinuousClock.now + .seconds(2)
            while chat.working && ContinuousClock.now < deadline { await Task.yield() }
            XCTAssertFalse(chat.working, "scenario \(scenario)")
            XCTAssertNil(chat.replyProgress.turnID)
            XCTAssertEqual(chat.replyProgress.text, "")
            XCTAssertEqual(chat.turns.count, 1)
            XCTAssertEqual(chat.turns.last?.failed, true)
            XCTAssertEqual(chat.draft, scenario == 0 ? "  我有什么衣服\n" : scenario == 1 ? "新的问题" : "")
            XCTAssertEqual(chat.photos, scenario == 0 ? [Data([2, 9])] : scenario == 3 ? [Data([8, 6, 4])] : [])
            let saved = try ChatSessionFiles(scope: .general, root: directory).loadDraft()
            XCTAssertEqual(saved.text, chat.draft)
            XCTAssertEqual(saved.photos, chat.photos)
        }
    }

    func testProposalOwnersSurviveLaterMessagesAndStaleConfirmationCannotConsumeNewProposal() throws {
        let (_, directory, _, _, sessions) = try fixture()
        let a = ChatTurn(question: "记住不放辣椒"), b = ChatTurn(question: "记住少放盐"), newer = ChatTurn(question: "今天什么天气")
        let files = ChatSessionFiles(scope: .general, root: directory)
        try files.saveTurns([a, b, newer])
        let chat = sessions.chat(for: .general), tools = try XCTUnwrap(chat.tools)
        tools.beginTurn(request: a.question, previous: nil, turnID: a.id)
        tools.add(.note(.init(id: UUID(), title: "不辣", text: "不放辣椒", quantity: nil, revision: 1)), title: "第一项", detail: nil)
        tools.beginTurn(request: b.question, previous: a.question, turnID: b.id)
        tools.add(.note(.init(id: UUID(), title: "少盐", text: "少放盐", quantity: nil, revision: 1)), title: "第二项", detail: nil)
        tools.endTurn()
        let proposals = try JSONDecoder().decode([PendingChange].self, from: Data(contentsOf: files.pending))
        XCTAssertEqual(proposals.map(\.requestTurnID), [a.id, b.id])
        chat.confirm(ids: [proposals[0].id])
        XCTAssertEqual(tools.notes.records.map(\.title), ["不辣"])
        XCTAssertEqual(chat.turns[2], newer)
        XCTAssertEqual(chat.turns.last?.confirmationResults?.first?.requestTurnID, a.id)
        XCTAssertEqual(chat.turns.last?.confirmationResults?.first?.proposalID, proposals[0].id)
        XCTAssertEqual(chat.turns.last?.confirmationResults?.first?.state, .succeeded)
        let count = chat.turns.count
        chat.confirm(ids: Set(proposals.map(\.id))) // A stale card included the already consumed first item.
        XCTAssertEqual(chat.turns.count, count)
        XCTAssertEqual(tools.pending.map(\.id), [proposals[1].id])
        XCTAssertEqual(tools.notes.records.count, 1)
        XCTAssertNotNil(chat.error)
        chat.discard(ids: [proposals[1].id])
        XCTAssertEqual(chat.turns.last?.confirmationResults?.first?.requestTurnID, b.id)
        XCTAssertEqual(chat.turns.last?.confirmationResults?.first?.state, .notStarted)
        XCTAssertEqual(tools.notes.records.count, 1)
    }

    func testRecoveryUpdatesExistingExecutionInPlaceWithoutDowngradingDurableFinalReceipt() throws {
        for finalSaved in [false, true] {
            let (_, directory, _, _, sessions) = try fixture()
            let request = ChatTurn(question: "原请求"), newest = ChatTurn(question: "新问题", answer: "不要覆盖")
            let initial = ConfirmationResult(proposalID: UUID(), requestTurnID: request.id, title: "操作", state: .notStarted, message: "未开始")
            let filename = ChatScope.general.key.utf8.map { String(format: "%02x", $0) }.joined() + ".json"
            let journal = ConfirmationJournal(file: directory.appendingPathComponent("device-operation-history").appendingPathComponent(filename))
            let id = try journal.begin(ids: [initial.id], titles: [initial.title], results: [initial])
            var running = initial; running.state = .running
            try journal.progress(id, receipts: [running.message], results: [running])
            var result = initial
            if finalSaved { result.state = .succeeded; result.message = "最终回执已保存" }
            let execution = ChatTurn(id: id, question: "确认操作", receipts: [result.message], confirmationIDs: [id],
                confirmationResults: [result], confirmationFinished: finalSaved)
            try ChatSessionFiles(scope: .general, root: directory).saveTurns([request, execution, newest])
            let chat = sessions.chat(for: .general)
            XCTAssertEqual(chat.turns.count, 3)
            XCTAssertEqual(chat.turns[1].id, id)
            XCTAssertEqual(chat.turns[1].confirmationResults?.first?.state, finalSaved ? .succeeded : .needsVerification)
            XCTAssertEqual(chat.turns[2], newest)
            let once = chat.turns
            chat.reloadFromDisk()
            XCTAssertEqual(chat.turns, once)
            XCTAssertTrue(chat.tools?.pending.isEmpty == true)
            XCTAssertTrue(chat.tools?.notes.records.isEmpty == true)
        }
    }

    func testInterruptedReplyAndRestoredRunningEvidenceNeverRestartWork() throws {
        let (_, directory, _, _, sessions) = try fixture()
        let request = ChatTurn(question: "上次没答完", replyState: .answering)
        let running = ConfirmationResult(proposalID: UUID(), requestTurnID: request.id, title: "系统操作", state: .running, message: "正在执行")
        let execution = ChatTurn(question: "确认操作", receipts: [running.message], confirmationResults: [running])
        try ChatSessionFiles(scope: .general, root: directory).saveTurns([request, execution])
        let chat = sessions.chat(for: .general)
        XCTAssertEqual(chat.turns[0].replyState, .interrupted)
        XCTAssertEqual(chat.turns[1].confirmationResults?.first?.state, .needsVerification)
        XCTAssertFalse(chat.working)
        XCTAssertTrue(chat.tools?.pending.isEmpty == true)
    }

    func testEarlySavedCardSurvivesRestartWithoutRestartingReplyOrChangingOtherScope() throws {
        let (_, directory, _, _, sessions) = try fixture()
        let files = ChatSessionFiles(scope: .inventory, root: directory)
        let request = ChatTurn(question: "修车有什么可用", replyState: .answering)
        let card = ItemCollection(title: "修车清单", items: [.init(id: UUID(), name: "扳手", reason: "拆卸")])
        _ = try files.saveReadOnlyCollections(for: request.id, displayed: card, edited: nil, history: [request])
        let chat = sessions.chat(for: .inventory)
        XCTAssertEqual(chat.turns.first?.id, request.id)
        XCTAssertEqual(chat.turns.first?.replyState, .interrupted)
        XCTAssertEqual(chat.latestCollection, card)
        XCTAssertTrue(chat.turns.first?.collectionNotice.contains("回复未完成") == true)
        XCTAssertFalse(chat.working)
        XCTAssertTrue(chat.tools?.pending.isEmpty == true)
        XCTAssertTrue(sessions.chat(for: .general).turns.isEmpty)
        let restored = chat.turns
        chat.reloadFromDisk()
        XCTAssertEqual(chat.turns, restored)
    }

    func testUnchangedSyncKeepsLocalEvidenceButChangedReceiptDoesNotInheritSuccess() throws {
        let (_, directory, _, _, sessions) = try fixture()
        let result = ConfirmationResult(proposalID: UUID(), requestTurnID: UUID(), title: "操作", state: .succeeded, message: "完成")
        let original = ChatTurn(question: "确认操作", receipts: [result.message], confirmationIDs: [UUID()],
            confirmationResults: [result], confirmationFinished: true)
        let files = ChatSessionFiles(scope: .general, root: directory)
        try files.saveTurns([original])
        let chat = sessions.chat(for: .general)
        let sync = ChatSyncData(root: directory, isWorking: { false }, didImport: { sessions.reloadSyncedHistory($0) })
        let key = SyncRecord.Key(kind: .chat, id: original.id)
        let payload = try SyncRecord.encode(SyncedChatTurn(scope: .general, turn: original))
        try sync.replace(key, expected: payload, with: payload)
        XCTAssertEqual(chat.turns[0].confirmationResults, [result])
        var changed = original; changed.receipts = ["另一设备的不同回执"]
        try sync.replace(key, expected: payload, with: SyncRecord.encode(SyncedChatTurn(scope: .general, turn: changed)))
        XCTAssertNil(chat.turns[0].confirmationResults)
        XCTAssertNil(chat.turns[0].confirmationFinished)
        XCTAssertTrue(chat.tools?.pending.isEmpty == true)
    }

    func testStoppedPartialReplySurvivesReloadAndUnchangedSyncButNeverEntersModelHistory() throws {
        let (_, directory, _, _, sessions) = try fixture()
        let original = ChatTurn(question: "核对库存", answer: "已停止", failed: true,
            replyState: .stopped, partialReply: "尚未核实的片段")
        let files = ChatSessionFiles(scope: .general, root: directory)
        try files.saveTurns([original])
        let chat = sessions.chat(for: .general)
        XCTAssertEqual(chat.turns, [original])
        XCTAssertFalse(chat.working)
        let context = ButlerChat.context(from: chat.turns, summary: ConversationSummary())
        XCTAssertEqual(context.count, 1)
        guard case .user(let question) = context.first else { return XCTFail("Only the original question belongs in model context") }
        XCTAssertEqual(question, "核对库存")
        let archive = ConversationArchive(turns: chat.turns, recentStart: 0, summaryThrough: nil)
        let page = archive.read(fromTurn: nil, toTurn: nil, from: nil, to: nil, cursor: nil)
        let bytes = try JSONSerialization.data(withJSONObject: page)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("尚未核实的片段"))

        let sync = ChatSyncData(root: directory, isWorking: { false }, didImport: { sessions.reloadSyncedHistory($0) })
        let key = SyncRecord.Key(kind: .chat, id: original.id)
        let payload = try SyncRecord.encode(SyncedChatTurn(scope: .general, turn: original))
        try sync.replace(key, expected: payload, with: payload)
        XCTAssertEqual(chat.turns[0].partialReply, "尚未核实的片段")
        var changed = original
        changed.answer = "来自另一设备的新内容"
        try sync.replace(key, expected: payload, with: SyncRecord.encode(SyncedChatTurn(scope: .general, turn: changed)))
        XCTAssertNil(chat.turns[0].partialReply)
        XCTAssertEqual(chat.turns[0].answer, "来自另一设备的新内容")
        XCTAssertFalse(chat.working)
        XCTAssertTrue(chat.tools?.pending.isEmpty == true)
    }

    func testReadingPositionIsPerSessionAndOnlySuccessfulSendRequestsLatest() throws {
        let (_, directory, _, _, sessions) = try fixture()
        let generalTurn = ChatTurn(question: "通用历史"), itemTurn = ChatTurn(question: "物品历史")
        let generalFiles = ChatSessionFiles(scope: .general, root: directory)
        let itemFiles = ChatSessionFiles(scope: .inventory, root: directory)
        try generalFiles.prepare(); try generalFiles.saveTurns([generalTurn])
        try itemFiles.prepare(); try itemFiles.saveTurns([itemTurn])
        let general = sessions.chat(for: .general), inventory = sessions.chat(for: .inventory)
        for (chat, turn) in [(general, generalTurn), (inventory, itemTurn)] {
            chat.scrollPolicy.appear(validTurnIDs: [turn.id])
            chat.scrollPolicy.positionChanged(to: turn.id)
            chat.scrollPolicy.phaseChanged(to: .interacting)
            chat.scrollPolicy.phaseChanged(to: .idle)
        }
        inventory.scrollPolicy.disappear()
        XCTAssertEqual(sessions.chat(for: .inventory).scrollPolicy.visibleTurnID, itemTurn.id)

        try FileManager.default.removeItem(at: generalFiles.transcript)
        try FileManager.default.createDirectory(at: generalFiles.transcript, withIntermediateDirectories: false)
        general.draft = "我有什么衣服"
        general.send()
        XCTAssertEqual(general.turns, [generalTurn])
        XCTAssertEqual(general.draft, "我有什么衣服")
        XCTAssertEqual(general.scrollPolicy.visibleTurnID, generalTurn.id)
        XCTAssertFalse(general.scrollPolicy.followingBottom)
        XCTAssertNil(general.scrollPolicy.takeScroll())

        try FileManager.default.removeItem(at: generalFiles.transcript)
        general.send()
        XCTAssertEqual(general.turns.count, 2)
        XCTAssertTrue(general.draft.isEmpty)
        XCTAssertNil(general.scrollPolicy.visibleTurnID)
        XCTAssertTrue(general.scrollPolicy.followingBottom)
        XCTAssertEqual(general.scrollPolicy.takeScroll(), .animated)
        XCTAssertEqual(inventory.scrollPolicy.visibleTurnID, itemTurn.id)
        XCTAssertFalse(inventory.scrollPolicy.followingBottom)
    }

    func testHistoryReloadKeepsExistingReadingAnchorAndClearingDropsIt() throws {
        let (_, directory, _, _, sessions) = try fixture()
        let turn = ChatTurn(question: "正在阅读的历史")
        let files = ChatSessionFiles(scope: .general, root: directory)
        try files.prepare(); try files.saveTurns([turn])
        let chat = sessions.chat(for: .general)
        chat.scrollPolicy.appear(validTurnIDs: [turn.id])
        chat.scrollPolicy.positionChanged(to: turn.id)
        chat.scrollPolicy.phaseChanged(to: .interacting)
        chat.scrollPolicy.phaseChanged(to: .idle)
        try files.saveTurns([turn, ChatTurn(question: "同步收到的新消息")])
        chat.reloadSyncedHistory()
        XCTAssertEqual(chat.scrollPolicy.visibleTurnID, turn.id)
        XCTAssertFalse(chat.scrollPolicy.followingBottom)
        XCTAssertNil(chat.scrollPolicy.takeScroll())
        chat.clearHistory()
        XCTAssertNil(chat.scrollPolicy.visibleTurnID)
        XCTAssertTrue(chat.scrollPolicy.followingBottom)
        XCTAssertEqual(chat.scrollPolicy.takeScroll(), .immediate)
    }

    private func fixture() throws -> (ModelContainer, URL, UserDefaults, ReminderStore, ChatSessions) {
        let container = try ButlerStore.makePreviewContainer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-sessions-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "chat-sessions-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let reminders = ReminderStore(file: directory.appendingPathComponent("reminders.json"), schedules: false)
        let sessions = ChatSessions(container: container, reminders: reminders,
                                    connection: SubscriptionConnection(keychainAccount: suite),
                                    jev: JevClient(defaults: defaults, keychainAccount: suite),
                                    directory: directory, defaults: defaults)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        return (container, directory, defaults, reminders, sessions)
    }

    func testLegacyGeneralHistoryAndDraftMigrateWithoutAssigningObjects() throws {
        let (_, directory, defaults, _, sessions) = try fixture()
        let turn = ChatTurn(question: "上次买了火腿", answer: "请确认")
        try JSONEncoder().encode([turn]).write(to: directory.appendingPathComponent("butler-chat.json"))
        defaults.set("还没有发出的字", forKey: "butlerChatDraft")
        let general = sessions.chat(for: .general)
        XCTAssertEqual(general.turns, [turn])
        XCTAssertEqual(general.draft, "还没有发出的字")
        XCTAssertNil(defaults.string(forKey: "butlerChatDraft"))
        XCTAssertTrue(sessions.chat(for: .lot(UUID())).turns.isEmpty)
        XCTAssertNil(general.turns.first?.relatedScopeKeys)
        XCTAssertEqual(try JSONDecoder().decode(ChatDraft.self,
            from: Data(contentsOf: directory.appendingPathComponent("butler-chat-draft.json"))).text, general.draft)
    }

    func testScopesKeepDraftsPhotosSummariesAndHistoryIndependent() throws {
        let (container, directory, defaults, reminders, sessions) = try fixture()
        let lotScope = ChatScope.lot(UUID())
        let general = sessions.chat(for: .general)
        let lot = sessions.chat(for: lotScope)
        general.draft = "通用草稿"
        lot.draft = "物品草稿"
        lot.photos = [Data([1, 2, 3])]
        XCTAssertTrue(sessions.chat(for: lotScope) === lot)
        XCTAssertTrue(general.connection === lot.connection)
        XCTAssertTrue(general.jev === lot.jev)
        XCTAssertTrue(general.tools?.notes === lot.tools?.notes)
        let turn = ChatTurn(question: "物品专属问题")
        let files = ChatSessionFiles(scope: lotScope, root: directory)
        try files.saveTurns([turn])
        try JSONEncoder().encode(ConversationSummary(text: "物品摘要")).write(to: files.summary)
        let reloaded = ButlerChat(container: container, reminders: reminders, scope: lotScope,
                                  connection: general.connection, jev: general.jev, directory: directory, defaults: defaults)
        XCTAssertEqual(reloaded.draft, "物品草稿")
        XCTAssertEqual(reloaded.photos, [Data([1, 2, 3])])
        XCTAssertEqual(reloaded.turns, [turn])
        XCTAssertEqual(reloaded.summary.text, "物品摘要")
        XCTAssertTrue(general.turns.isEmpty)
        XCTAssertTrue(general.photos.isEmpty)
        XCTAssertEqual(general.draft, "通用草稿")
        XCTAssertNotEqual(general.photoDirectory, reloaded.photoDirectory)
    }

    func testHistoryBeyondTwoThousandTurnsIsPreserved() throws {
        let (_, directory, _, _, sessions) = try fixture()
        let turns = (0..<2005).map { ChatTurn(question: "第 \($0) 次对话") }
        try ChatSessionFiles(scope: .general, root: directory).saveTurns(turns)
        XCTAssertEqual(sessions.chat(for: .general).turns, turns)
    }

    func testDamagedHistoryIsPreservedInsteadOfBecomingAnEmptyConversation() throws {
        let (_, directory, _, _, sessions) = try fixture()
        let file = ChatSessionFiles(scope: .general, root: directory).transcript
        let damaged = Data("not valid history".utf8)
        try damaged.write(to: file)
        let chat = sessions.chat(for: .general)
        chat.draft = "不应该覆盖旧记录"
        chat.send()
        XCTAssertFalse(chat.canSend)
        XCTAssertNotNil(chat.error)
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    func testDamagedDraftIsNotOverwrittenByEditingOrAttachingPhotos() throws {
        let (_, directory, _, _, sessions) = try fixture()
        let scope = ChatScope.settings
        let files = ChatSessionFiles(scope: scope, root: directory)
        try files.prepare()
        let damaged = Data("not a valid draft".utf8)
        try damaged.write(to: files.draft)
        let chat = sessions.chat(for: scope)
        chat.draft = "新输入"
        chat.photos = [Data([9])]
        XCTAssertFalse(chat.canSend)
        XCTAssertNotNil(chat.error)
        XCTAssertEqual(try Data(contentsOf: files.draft), damaged)
    }

    func testRelatedTurnsUseExplicitReferencesAcrossScopesWithoutCopying() throws {
        let (_, directory, _, _, sessions) = try fixture()
        let scope = ChatScope.lot(UUID())
        var related = ChatTurn(question: "从首页修改这个物品")
        related.relatedScopeKeys = [scope.key]
        let unrelated = ChatTurn(question: "同名物品也不能靠猜关联")
        let own = ChatTurn(question: "在物品里聊")
        try ChatSessionFiles(scope: .general, root: directory).saveTurns([related, unrelated])
        try ChatSessionFiles(scope: scope, root: directory).saveTurns([own])
        let found = sessions.relatedTurns(for: scope)
        XCTAssertEqual(Set(found.map(\.turn.id)), [related.id, own.id])
        XCTAssertEqual(found.first { $0.turn.id == related.id }?.scope, .general)
        let objectChat = sessions.chat(for: scope)
        XCTAssertEqual(objectChat.turns, [own])
        let archive = try XCTUnwrap(objectChat.tools?.conversation?())
        XCTAssertEqual(Set(archive.turns.map(\.id)), [related.id, own.id])
        XCTAssertNil(archive.overview()["already_in_context_from_turn"], "Related history is not automatically all present in the model's recent window")
        let page = try XCTUnwrap(archive.read(fromTurn: nil, toTurn: nil, from: nil, to: nil, cursor: nil)["turns"] as? [[String: Any]])
        let source = page.first { $0["turn_id"] as? String == related.id.uuidString }
        XCTAssertEqual(source?["source_scope"] as? String, ChatScope.general.key)
        XCTAssertEqual(source?["user"] as? String, related.question)
        XCTAssertFalse(archive.turns.contains { $0.id == unrelated.id })
        let generalHistory = try XCTUnwrap(sessions.chat(for: .general).tools?.conversation?())
        XCTAssertEqual(Set(generalHistory.turns.map(\.id)), [related.id, unrelated.id, own.id])
        XCTAssertEqual(generalHistory.turns.count, 3, "General history includes all pages without duplicating references")
    }

    func testConfirmingNewInventoryLinksRealLotIDsToOriginalGeneralTurn() async throws {
        let (container, directory, _, _, sessions) = try fixture()
        let turn = ChatTurn(question: "买了一袋纸巾")
        try ChatSessionFiles(scope: .general, root: directory).saveTurns([turn])
        let chat = sessions.chat(for: .general)
        let tools = try XCTUnwrap(chat.tools)
        tools.beginTurn(request: turn.question, previous: nil, turnID: turn.id)
        _ = await tools.execute(LocalToolCall(id: "new-purchase", name: "propose_add_items", arguments: #"{"items":[{"name":"纸巾","quantity":1,"unit":"袋","storage":null,"package_expiry":null,"planned_use_by":null,"track":"quantity"}]}"#))
        XCTAssertEqual(tools.pending.count, 1)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).isEmpty)
        chat.confirm()
        let lot = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).first)
        let scope = ChatScope.lot(lot.id)
        XCTAssertTrue(chat.turns[0].relatedScopeKeys?.contains(scope.key) == true)
        let references = sessions.relatedTurns(for: scope)
        XCTAssertEqual(Set(references.map(\.turn.id)), [turn.id, chat.turns[1].id])
        XCTAssertEqual(references.first?.scope, .general)
        XCTAssertTrue(chat.turns[0].receipts.isEmpty)
        XCTAssertEqual(chat.turns[1].confirmationResults?.first?.requestTurnID, turn.id)
        XCTAssertEqual(chat.turns[1].confirmationResults?.first?.state, .succeeded)
        let saved = try JSONDecoder().decode([ChatTurn].self,
            from: Data(contentsOf: ChatSessionFiles(scope: .general, root: directory).transcript))
        XCTAssertEqual(saved[0].relatedScopeKeys, [scope.key])
    }

    func testLotRenameAndArchiveKeepIdentityAndReadFreshContext() throws {
        let (container, _, _, _, sessions) = try fixture()
        let context = ModelContext(container)
        let product = CatalogProduct(canonicalName: "原来的名称")
        let lot = InventoryLot(productID: product.id, quantity: 2, unit: "袋")
        context.insert(product)
        context.insert(lot)
        try context.save()
        let chat = sessions.chat(for: .lot(lot.id))
        XCTAssertEqual(chat.contextTitle, "原来的名称")
        product.canonicalName = "改后的名称"
        lot.quantity = 1
        lot.state = .archived
        lot.revision = 3
        try context.save()
        XCTAssertTrue(sessions.chat(for: .lot(lot.id)) === chat)
        XCTAssertEqual(chat.contextTitle, "改后的名称")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(chat.scopeContext.utf8)) as? [String: Any])
        XCTAssertEqual(value["lot_id"] as? String, lot.id.uuidString)
        XCTAssertEqual(value["quantity"] as? Int, 1)
        XCTAssertEqual(value["state"] as? String, "archived")
        XCTAssertEqual(value["revision"] as? Int, 3)
    }

    func testScopedDraftPhotosAndHistoryRoundTripThroughBackup() throws {
        let (container, directory, defaults, _, sessions) = try fixture()
        let scope = ChatScope.task(UUID())
        let chat = sessions.chat(for: scope)
        chat.draft = "还要再改一下提醒"
        chat.photos = [Data([4, 5, 6])]
        let files = ChatSessionFiles(scope: scope, root: directory)
        try files.saveTurns([ChatTurn(question: "原来的任务对话")])
        try FileManager.default.createDirectory(at: files.photos, withIntermediateDirectories: true)
        try Data([7, 8, 9]).write(to: files.photos.appendingPathComponent("photo.jpg"))
        let backup = try BackupService.decode(BackupService.encode(
            BackupService.makeBackup(container: container, directory: directory, defaults: defaults)))
        chat.draft = "恢复时应被替换"
        _ = sessions.chat(for: .settings)
        try BackupService.restore(backup, container: container, directory: directory, defaults: defaults)
        sessions.reloadFromDisk()
        XCTAssertEqual(chat.draft, "还要再改一下提醒")
        XCTAssertEqual(chat.photos, [Data([4, 5, 6])])
        XCTAssertEqual(chat.turns.first?.question, "原来的任务对话")
        XCTAssertEqual(try Data(contentsOf: files.photos.appendingPathComponent("photo.jpg")), Data([7, 8, 9]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ChatSessionFiles(scope: .settings, root: directory).directory.path))
    }

    func testUnsafeChatBackupPathIsRejectedBeforeReplacingData() throws {
        let (container, directory, defaults, _, sessions) = try fixture()
        sessions.chat(for: .general).draft = "必须保留"
        var backup = ButlerBackup()
        backup.files["chat-file/chat-sessions/../../outside.json"] = Data("bad".utf8)
        XCTAssertThrowsError(try BackupService.restore(backup, container: container, directory: directory, defaults: defaults))
        sessions.reloadFromDisk()
        XCTAssertEqual(sessions.chat(for: .general).draft, "必须保留")
    }

    func testScopeCodingAndDayPathsAreStableAndSafe() throws {
        let scopes: [ChatScope] = [.general, .inventory, .lot(UUID()), .task(UUID()), .settings, .day("../../today")]
        for scope in scopes {
            XCTAssertEqual(try JSONDecoder().decode(ChatScope.self, from: JSONEncoder().encode(scope)), scope)
            XCTAssertFalse(scope.key.contains("/"))
            XCTAssertFalse(scope.key.contains(".."))
        }
    }

    func testSettingsRefreshUpdatesProfilesAndSharedJevWithoutLosingDrafts() throws {
        let (_, _, defaults, _, sessions) = try fixture()
        let general = sessions.chat(for: .general)
        let settings = sessions.chat(for: .settings)
        general.draft = "还没发送的购买清单"
        defaults.set("家里有两个人", forKey: "butlerProfile")
        defaults.set(false, forKey: "jevEnabled")
        defaults.set(false, forKey: "jevPrefetchEnabled")
        sessions.reloadSettings()
        XCTAssertEqual(general.profile, "家里有两个人")
        XCTAssertEqual(settings.profile, "家里有两个人")
        XCTAssertFalse(general.jev.isEnabled)
        XCTAssertFalse(settings.jev.prefetchEnabled)
        XCTAssertEqual(general.draft, "还没发送的购买清单")
    }

    func testBackupRestoresExtendedSettingsAndSharedJevState() throws {
        let (container, directory, defaults, _, sessions) = try fixture()
        _ = sessions.chat(for: .settings)
        defaults.set("dark", forKey: "appearanceMode")
        defaults.set("ocean", forKey: "accentChoice")
        defaults.set("plain", forKey: "appTheme")
        defaults.set(false, forKey: "jevEnabled")
        defaults.set(false, forKey: "jevPrefetchEnabled")
        defaults.set("恢复后的背景", forKey: "butlerProfile")
        let backup = try BackupService.makeBackup(container: container, directory: directory, defaults: defaults)
        defaults.set("light", forKey: "appearanceMode")
        defaults.set("window", forKey: "appTheme")
        defaults.set(true, forKey: "jevEnabled")
        defaults.set(true, forKey: "jevPrefetchEnabled")
        try BackupService.restore(backup, container: container, directory: directory, defaults: defaults)
        sessions.reloadFromDisk()
        XCTAssertEqual(defaults.string(forKey: "appearanceMode"), "dark")
        XCTAssertEqual(defaults.string(forKey: "accentChoice"), "ocean")
        XCTAssertEqual(defaults.string(forKey: "appTheme"), "plain")
        XCTAssertFalse(sessions.jev.isEnabled)
        XCTAssertFalse(sessions.jev.prefetchEnabled)
        XCTAssertEqual(sessions.chat(for: .settings).profile, "恢复后的背景")
    }

    func testDiaryAggregatesAllScopesWithoutDuplicatingRelatedReferences() throws {
        let (_, directory, _, _, sessions) = try fixture()
        let scope = ChatScope.task(UUID())
        var general = ChatTurn(question: "在首页创建任务")
        general.relatedScopeKeys = [scope.key]
        let task = ChatTurn(question: "在任务页修改")
        try ChatSessionFiles(scope: .general, root: directory).saveTurns([general])
        try ChatSessionFiles(scope: scope, root: directory).saveTurns([task])
        _ = sessions.chat(for: .settings)
        XCTAssertEqual(Set(sessions.allTurns.map(\.id)), [general.id, task.id])
        XCTAssertEqual(sessions.allTurns.count, 2)
    }

    func testTaskScopeDoesNotFallbackToCreatingADifferentReminder() {
        XCTAssertNotNil(LocalReminderParser.parse("明天 9 点提醒我取快递"))
        XCTAssertFalse(ButlerChat.allowsLocalReminderCreation(in: .task(UUID())))
        XCTAssertTrue(ButlerChat.allowsLocalReminderCreation(in: .general))
    }

    func testItemShortcutPreservesUnsentDraftAndPhotosWithoutSendingOrConfirming() throws {
        let (_, _, _, _, sessions) = try fixture()
        let chat = sessions.chat(for: .inventory)
        chat.draft = "还没写完的原草稿"
        chat.photos = [Data([1, 2, 3])]
        let pending = chat.tools?.pending.count
        chat.receiveItemShortcut("牛奶两瓶")
        XCTAssertTrue(chat.draft.hasPrefix("还没写完的原草稿"))
        XCTAssertTrue(chat.draft.contains("牛奶两瓶"))
        XCTAssertEqual(chat.photos, [Data([1, 2, 3])])
        XCTAssertTrue(chat.turns.isEmpty)
        XCTAssertFalse(chat.working)
        XCTAssertEqual(chat.tools?.pending.count, pending)
    }

    func testPhotoBatchLimitAndSaveFailureLeaveDraftUnchanged() throws {
        let (_, directory, _, _, sessions) = try fixture()
        let chat = sessions.chat(for: .general)
        chat.draft = "未发送的说明"
        try chat.appendPhotos([Data([1]), Data([2]), Data([3])])
        XCTAssertThrowsError(try chat.appendPhotos([Data([4]), Data([5])]))
        XCTAssertEqual(chat.photos, [Data([1]), Data([2]), Data([3])])
        try chat.appendPhotos([Data([4])])
        sessions.reloadFromDisk()
        XCTAssertEqual(chat.photos, [Data([1]), Data([2]), Data([3]), Data([4])])
        XCTAssertEqual(chat.draft, "未发送的说明"); XCTAssertTrue(chat.turns.isEmpty)
        chat.photos = [Data([1])]
        let file = ChatSessionFiles(scope: .general, root: directory).draft
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try chat.appendPhotos([Data([7]), Data([8])]))
        XCTAssertEqual(chat.photos, [Data([1])]); XCTAssertEqual(chat.draft, "未发送的说明")
    }

    func testShareDraftReceiptPersistsTogetherAndPreventsRepeatImportAfterReload() throws {
        let (_, directory, _, _, sessions) = try fixture()
        let chat = sessions.chat(for: .general)
        chat.draft = "原草稿"
        chat.photos = [Data([4, 2])]
        let record = ShareInbox.Record(id: UUID(), createdAt: .now, text: "确认", attachments: [])
        let content = ShareContentReader.Content(text: "分享资料，不是确认：牛奶两瓶", photos: [Data([8, 7, 6])])
        let pending = chat.tools?.pending.count
        try chat.receiveShare(record, content: content)
        let persisted = try JSONDecoder().decode(ChatDraft.self, from: Data(contentsOf: ChatSessionFiles(scope: .general, root: directory).draft))
        XCTAssertEqual(persisted.text, "原草稿\n\n分享资料，不是确认：牛奶两瓶")
        XCTAssertEqual(persisted.photos, [Data([4, 2]), Data([8, 7, 6])])
        XCTAssertEqual(persisted.receivedShareIDs, [record.id])
        sessions.reloadFromDisk()
        try chat.receiveShare(record, content: content)
        XCTAssertEqual(chat.draft, persisted.text)
        XCTAssertEqual(chat.photos, persisted.photos)
        XCTAssertTrue(chat.turns.isEmpty)
        XCTAssertFalse(chat.working)
        XCTAssertEqual(chat.tools?.pending.count, pending)
        chat.draft = ""; chat.photos = []
        sessions.reloadFromDisk()
        try chat.receiveShare(record, content: content)
        XCTAssertEqual(chat.draft, "") // Editing/clearing does not silently import again.
    }

    func testShareImportWriteFailureAndFullDraftLeaveMemoryAndReceiptUnchanged() throws {
        let (_, directory, _, _, sessions) = try fixture()
        let chat = sessions.chat(for: .general)
        let record = ShareInbox.Record(id: UUID(), createdAt: .now, text: "资料", attachments: [])
        let content = ShareContentReader.Content(text: "待核对", photos: [])
        chat.draft = String(repeating: "字", count: 7999)
        XCTAssertThrowsError(try chat.receiveShare(record, content: content))
        XCTAssertEqual(chat.draft.count, 7999)
        XCTAssertTrue(chat.receivedShareIDs.isEmpty)
        chat.draft = "原草稿"
        let file = ChatSessionFiles(scope: .general, root: directory).draft
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try chat.receiveShare(record, content: content))
        XCTAssertEqual(chat.draft, "原草稿")
        XCTAssertTrue(chat.receivedShareIDs.isEmpty)
    }

    func testShareReaderNeverTreatsExternalConfirmationAsOwnerApprovalAndKeepsURLAsReference() throws {
        let (_, directory, _, _, _) = try fixture()
        let inbox = ShareInbox(root: directory.appendingPathComponent("share"))
        let record = ShareInbox.Record(id: UUID(), createdAt: .now,
                                      text: "确认\nhttps://example.com/order", attachments: [])
        let content = try ShareContentReader.read(record, inbox: inbox)
        let pending = [PendingChange(kind: .reminder(TimedReminder(text: "原提案", fireDate: .now)), title: "原提案", detail: nil)]
        XCTAssertNotNil(PendingDecision.parse("确认", pending: pending))
        XCTAssertNil(PendingDecision.parse(content.text, pending: pending))
        XCTAssertTrue(content.text.contains("https://example.com/order"))
        XCTAssertTrue(content.text.contains("不是对已有待确认项的批准"))
        XCTAssertTrue(content.photos.isEmpty)
    }
    func testScreenshotKeepsIntentDraftAndImportsOnceWithoutSending() throws {
        let (_, directory, _, reminders, sessions) = try fixture()
        let chat = sessions.chat(for: .general)
        chat.draft = "帮我安排这件事"
        let record = ShareInbox.Record(id: UUID(), createdAt: .now, text: "", attachments: [])
        let content = ShareContentReader.Content(text: "", photos: [Data([7, 8])])
        try chat.receiveShare(record, content: content)
        XCTAssertEqual(chat.draft, "帮我安排这件事")
        sessions.reloadFromDisk()
        try chat.receiveShare(record, content: content)
        XCTAssertEqual(chat.photos, content.photos)
        XCTAssertTrue(chat.turns.isEmpty)
        XCTAssertFalse(chat.working)
        XCTAssertTrue(chat.tools?.pending.isEmpty == true)
        XCTAssertTrue(try reminders.taskSnapshot().isEmpty)
        let saved = try JSONDecoder().decode(ChatDraft.self, from: Data(contentsOf: ChatSessionFiles(scope: .general, root: directory).draft))
        XCTAssertEqual(saved.receivedShareIDs, [record.id])
    }

}
