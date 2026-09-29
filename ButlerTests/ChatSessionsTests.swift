import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor
final class ChatSessionsTests: XCTestCase {
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
        XCTAssertEqual(sessions.chat(for: .general).tools?.conversation?().turns, [related, unrelated])
    }

    func testConfirmingNewInventoryLinksRealLotIDsToOriginalGeneralTurn() async throws {
        let (container, directory, _, _, sessions) = try fixture()
        let turn = ChatTurn(question: "买了一袋纸巾")
        try ChatSessionFiles(scope: .general, root: directory).saveTurns([turn])
        let chat = sessions.chat(for: .general)
        let tools = try XCTUnwrap(chat.tools)
        tools.beginTurn(request: turn.question, previous: nil)
        _ = await tools.execute(LocalToolCall(id: "new-purchase", name: "propose_add_items", arguments: #"{"items":[{"name":"纸巾","quantity":1,"unit":"袋","storage":null,"package_expiry":null,"planned_use_by":null,"track":"quantity"}]}"#))
        XCTAssertEqual(tools.pending.count, 1)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).isEmpty)
        chat.confirm()
        let lot = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).first)
        let scope = ChatScope.lot(lot.id)
        XCTAssertTrue(chat.turns[0].relatedScopeKeys?.contains(scope.key) == true)
        let references = sessions.relatedTurns(for: scope)
        XCTAssertEqual(references.map(\.turn.id), [turn.id])
        XCTAssertEqual(references.first?.scope, .general)
        XCTAssertTrue(references.first?.turn.receipts.first?.hasPrefix("✓") == true)
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
}
