import Foundation
import Observation
import SwiftData
import UIKit
import UserNotifications

extension ButlerChat {
    // MARK: - Sending

    /// Commit an entire picker batch, never a partially decoded selection.
    func appendPhotos(_ additions: [Data]) throws {
        guard !working, draftReadable, let files, !additions.isEmpty,
              additions.count <= 4, photos.count + additions.count <= 4,
              additions.allSatisfy({ !$0.isEmpty && $0.count <= 4_000_000 }) else {
            throw ShareInbox.Failure("草稿不可用、正在回复或图片超限；每条消息最多4张。本次未添加，原草稿保留。")
        }
        let saved = ChatDraft(text: draft, photos: photos + additions, receivedShareIDs: receivedShareIDs)
        try files.prepare()
        try JSONEncoder().encode(saved).write(to: files.draft, options: .atomic)
        loadingDraft = true
        photos = saved.photos
        loadingDraft = false
        draftRevision &+= 1
    }

    /// Commit content and receipt together before updating memory. No send or tool execution here.
    func receiveShare(_ record: ShareInbox.Record, content: ShareContentReader.Content) throws {
        guard scope == .general, !working, draftReadable, let files else {
            throw ShareInbox.Failure("请等通用对话空闲且草稿可读取后再试。分享原件仍保留。")
        }
        guard !receivedShareIDs.contains(record.id) else { return }
        let combined = draft + (draft.isEmpty || content.text.isEmpty ? "" : "\n\n") + content.text
        guard combined.count <= 8000, photos.count + content.photos.count <= 4 else {
            throw ShareInbox.Failure("原草稿较长或附件已满，请先处理原草稿，再加入这条分享。没有覆盖原草稿。")
        }
        let saved = ChatDraft(text: combined, photos: photos + content.photos, receivedShareIDs: receivedShareIDs + [record.id])
        try files.prepare()
        try JSONEncoder().encode(saved).write(to: files.draft, options: .atomic)
        loadingDraft = true
        draft = saved.text
        photos = saved.photos
        receivedShareIDs = saved.receivedShareIDs ?? []
        loadingDraft = false
        draftRevision &+= 1
    }

    /// An external capture is a new request, never confirmation of pending inventory changes.
    func receiveItemShortcut(_ text: String) {
        let request = "请将以下物品描述整理为待核对的记录提案，不要执行已有待确认项：\n" + text
        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty || working {
            draft += (draft.isEmpty ? "" : "\n\n") + request
            error = "已保留原草稿和快捷指令内容，请核对后发送。"
            return
        }
        draft = request
        send() // Existing send/confirmation boundary; if not configured, the draft remains.
    }

    func send() {
        guard canSend, let tools else { return }
        let submittedAt = ContinuousClock.now
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attached = photos
        let submitted = ChatDraft(text: draft, photos: attached, receivedShareIDs: receivedShareIDs)
        let text = typed.isEmpty ? Self.photoPrompt : typed
        if attached.isEmpty, let decision = localDecision {
            guard commitInput(ChatTurn(question: text)) else { return }
            if decision.confirm { confirm(ids: decision.ids) } else { discard(ids: decision.ids) }
            return
        }
        // Signed-in conversation always keeps semantic qualifiers and prior context. Local matching is
        // only an offline/sign-out convenience, never a shortcut around the model's understanding.
        if attached.isEmpty, !connection.isLoggedIn, answerOnPhone(text, tools: tools) { return }
        let previousTurn = turns.last
        // Build context before appending this request, so it isn't included twice.
        rebuildContext()
        var turn = ChatTurn(question: text)
        turn.relatedScopeKeys = scope == .general ? nil : [scope.key]
        turn.replyState = .answering
        guard commitInput(turn) else { return }
        let submittedRevision = draftRevision
        replyStarted = submittedAt
        working = true
        workingStage = "正在准备相关资料…"
        replyProgress.begin(turn.id)
        tools.inputPhotos = attached
        tools.beginTurn(request: text, previous: previousTurn?.question, hasPhotos: !attached.isEmpty, turnID: turn.id)
        let index = turns.count - 1
        // Keep going for a while if the owner switches away while the butler is answering.
        let background = UIApplication.shared.beginBackgroundTask(withName: "butler-answer")
        recordReplyTiming("input_saved chars=\(text.count) photos=\(attached.count)")
        task = Task {
            defer {
                tools.inputPhotos = []
                tools.endTurn()
                let keys = Set(turns[index].relatedScopeKeys ?? []).union(tools.relatedScopes.map(\.key))
                turns[index].relatedScopeKeys = keys.isEmpty ? nil : keys.sorted()
                working = false
                workingStage = ""
                replyProgress.finish()
                replyStarted = nil
                task = nil
                save()
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            }
            do {
                turns[index].answer = try await run(attached.isEmpty ? .user(text) : .userPhotos(text, attached),
                                                   tools: tools, previous: previousTurn, turnID: turn.id)
                turns[index].replyState = .completed
                recordReplyTiming("done")
                compactIfNeeded()
            } catch {
                recordReplyTiming("failed \(ChatDiagnostics.describe(error))")
                // No connection: a reminder can still be understood and set on the phone.
                if Self.isConnectivity(error), attached.isEmpty, Self.allowsLocalReminderCreation(in: scope, hasHomeBrief: homeBrief != nil),
                   let local = LocalReminderParser.parse(text) {
                    var reminder = TimedReminder(text: local.text, fireDate: local.fireDate, repeats: local.repeats)
                    reminder.timePeriod = local.timePeriod
                    tools.proposeReminder(reminder)
                    turns[index].answer = "暂时连不上模型服务，先为你整理了「\(reminder.text)」：\(reminder.whenLabel)。请在下面确认，也可以直接调整时间。"
                    turns[index].replyState = .completed
                    ChatDiagnostics.log("local reminder \(reminder.whenLabel)")
                    return
                }
                let message = SubscriptionConnection.message(error)
                turns[index].failed = true
                turns[index].replyState = error is CancellationError || Task.isCancelled ? .stopped : .failed
                turns[index].partialReply = replyProgress.text.isEmpty ? nil : replyProgress.text
                turns[index].answer = message
                self.error = message
                // Restore one complete input, never mix old photos with a newer draft.
                // Even typing then erasing counts as a newer edit.
                if draftRevision == submittedRevision {
                    loadingDraft = true
                    draft = submitted.text
                    photos = submitted.photos
                    loadingDraft = false
                    saveDraft()
                }
            }
        }
    }

    /// No tool execution, model request, or in-memory consumption before durable storage.
    @discardableResult
    private func commitInput(_ turn: ChatTurn, history: [ChatTurn]? = nil) -> Bool {
        guard historyReadable, draftReadable, let files else {
            error = "对话存储暂时不可用，输入已保留，本次没有发送。"
            return false
        }
        let previous = history ?? turns
        do {
            let saved = try files.saveSendingTurn(turn, history: previous,
                draft: ChatDraft(text: draft, photos: photos, receivedShareIDs: receivedShareIDs))
            turns = previous + [saved]
        } catch {
            self.error = "消息没能完整保存到手机，文字和照片已保留，本次没有发送：\(error.localizedDescription)"
            return false
        }
        error = nil
        loadingDraft = true
        draft = ""
        photos = []
        loadingDraft = false
        // If cleanup fails, the persisted marker reconciles against the committed turn on relaunch.
        saveDraft()
        // Every successful input path (including the orb and shortcuts) has the
        // same navigation intent. Failed storage must not move a reading user.
        scrollPolicy.sendToLatest()
        return true
    }

    func stop() { task?.cancel() }

    // MARK: - Lists shown in the conversation

    /// The most recent list the conversation showed; "去掉…" and the model's list edits apply to it.
    var latestCollection: ItemCollection? {
        turns.last(where: { $0.collection != nil })?.collection
    }

    /// Takes one line off a shown list. The thing itself stays at home.
    func removeFromCollection(_ collectionID: UUID, lot: UUID) {
        guard !working, historyReadable, let files,
              let index = turns.lastIndex(where: { $0.collection?.id == collectionID }),
              turns[index].collection?.items.contains(where: { $0.id == lot }) == true else { return }
        var next = turns
        next[index].collection?.items.removeAll { $0.id == lot }
        do {
            try files.saveTurns(next)
            turns = next
        } catch {
            self.error = "清单修改没能保存，仍保留原清单；库存没有变化：\(error.localizedDescription)"
        }
    }

    /// Plain questions ("我有什么衣服", "冷藏里有什么") and "去掉…" on the list that's showing are handled on
    /// the phone at once; nothing else is.
    private func answerOnPhone(_ text: String, tools: ButlerTools) -> Bool {
        if tools.pending.isEmpty, let list = latestCollection, let owner = turns.lastIndex(where: { $0.collection?.id == list.id }),
           let removed = ShownListEdit.removals(text, from: list) {
            let ids = Set(removed.map(\.id))
            var history = turns
            history[owner].collection?.items.removeAll { ids.contains($0.id) }
            if commitInput(ChatTurn(question: text, answer: "好，已从清单去掉「\(removed.map(\.name).joined(separator: "、"))」，东西还在家里。"), history: history) {
                ChatDiagnostics.log("local list edit removed=\(removed.count)")
            }
            return true
        }
        guard LocalInventoryQuery.isCandidate(text), let facts = try? tools.activeFacts(),
              let answer = LocalInventoryQuery.answer(text, facts: facts) else { return false }
        var turn = ChatTurn(question: text, answer: answer.text)
        turn.collection = LocalInventoryQuery.collection(answer)
        turn.relatedScopeKeys = scope == .general ? nil : [scope.key]
        if commitInput(turn) { ChatDiagnostics.log("local inventory answer count=\(answer.lots.count)") }
        return true
    }

    static func isConnectivity(_ error: Error) -> Bool {
        if case SubscriptionError.unreachable = error { return true }
        if let url = error as? URLError { return SubscriptionModel.isTransient(url) }
        return false
    }

    static func allowsLocalReminderCreation(in scope: ChatScope, hasHomeBrief: Bool = false) -> Bool {
        // "晚点提醒我" may correct the visible brief, not create an unrelated new task.
        if hasHomeBrief { return false }
        if case .task = scope { return false }
        if case .brief = scope { return false }
        return true
    }

    func run(_ message: LocalAgentMessage, tools: ButlerTools, previous: ChatTurn?, turnID: UUID) async throws -> String {
        guard let model else { throw SubscriptionError.signInRequired }
        let start = messages.count
        let pendingBefore = tools.pending
        messages.append(message)
        do {
            let request: String
            let hasPhotos: Bool
            switch message {
            case .user(let text): request = text; hasPhotos = false
            case .userPhotos(let text, _): request = text; hasPhotos = true
            default: request = ""; hasPhotos = false
            }
            let prefetched = try await ButlerPrefetch.prepare(request: request,
                previousQuestion: previous?.question, previousAnswer: previous?.failed == false ? previous?.answer : nil,
                hasPhotos: hasPhotos, enabled: jev.prefetchEnabled, tools: tools)
            recordReplyTiming("context_ready")
            var savedFirstResult = false
            var conversation = messages
            let answer = try await ToolConversationLoop.run(model: model, messages: &conversation, prefetched: prefetched,
                execute: { call in
                    let output = await tools.execute(call)
                    try Task.checkCancellation()
                    if call.name == "show_inventory" || call.name == "update_shown_list" {
                        guard let files = self.files else { throw ButlerTools.ToolError("清单存储暂时不可用") }
                        self.turns = try files.saveReadOnlyCollections(for: turnID, displayed: tools.displayedCollection,
                            edited: tools.shownListEdit, history: self.turns)
                        if !savedFirstResult, tools.displayedCollection != nil || tools.shownListEdit != nil {
                            savedFirstResult = true
                            self.recordReplyTiming("first_result_saved")
                        }
                    }
                    return output
                },
                progress: { [weak self] stage in
                    self?.workingStage = stage
                    self?.replyProgress.prepareNextPass()
                })
            messages = conversation
            return answer ?? "这件事步骤有点多，我先停在这里。你可以换个说法再试一次。"
        } catch {
            tools.restorePending(pendingBefore)
            messages.removeSubrange(start...)
            throw error
        }
    }

    var localDecision: PendingDecision? {
        guard photos.isEmpty, let tools else { return nil }
        return PendingDecision.parse(draft, pending: tools.pending)
    }
}
