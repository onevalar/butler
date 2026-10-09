import Foundation
import Observation
import SwiftData
import UIKit
import UserNotifications

extension ButlerChat {
    func loadPending() {
        do {
            let consumed = try confirmationJournal?.consumedIDs() ?? []
            guard let file = files?.pending, FileManager.default.fileExists(atPath: file.path) else { return }
            tools?.restorePending(try JSONDecoder().decode([PendingChange].self, from: Data(contentsOf: file))
                .filter { $0.persists && !consumed.contains($0.id) })
        }
        catch { pendingReadable = false; self.error = "待确认修改暂时无法读取，原文件已保留。" }
    }

    func recoverConfirmations() {
        guard historyReadable, pendingReadable, let journal = confirmationJournal else { return }
        do {
            let records = try journal.records().filter { !$0.reported }
            guard !records.isEmpty else { return }
            for entry in records {
                if turns.contains(where: { $0.id == entry.id && $0.confirmationFinished == true }) { continue }
                let explanation = entry.finished
                    ? "恢复上次执行回执；未重复执行。"
                    : "上次执行中断。下列回执是已保存的进度；没有回执的操作可能未开始，也可能已完成但未留下结果，请先核查，不能当作失败重试。没有自动续跑或撤销。"
                if let results = entry.results {
                    let recovered = results.map(\.recovered)
                    let value = ChatTurn(id: entry.id, question: "执行记录恢复", answer: explanation,
                        receipts: recovered.map(\.message), date: entry.date, confirmationIDs: [entry.id],
                        confirmationResults: recovered, confirmationFinished: true)
                    if let index = turns.firstIndex(where: { $0.id == entry.id }) { turns[index] = value }
                    else { turns.append(value) }
                    ChatTurn.updateConfirmation(entry.id, results: recovered, in: &turns)
                } else if !turns.contains(where: { $0.id == entry.id || $0.confirmationIDs?.contains(entry.id) == true }) {
                    turns.append(ChatTurn(id: entry.id, question: "执行记录恢复", answer: explanation,
                        receipts: ["原确认项目：" + entry.titles.joined(separator: "；")] + entry.receipts, date: entry.date))
                }
            }
            try files?.saveTurns(turns)
            try journal.acknowledge(Set(records.map(\.id)))
        } catch { self.error = "执行记录恢复未能保存；没有自动重试操作。" }
    }

    func acceptFolderSelection(_ url: URL, request: UUID) throws {
        guard !working, historyReadable, let tools, tools.folderSelectionRequest == request else {
            throw FolderFailure("本次文件夹选择已失效，请重新发起。")
        }
        tools.folderSelectionRequest = nil
        let grant: FolderGrant
        do { grant = try tools.folders.authorize(url) }
        catch {
            updateFolderSelection(request, state: .needsVerification, message: "文件夹授权未能核实：\(error.localizedDescription)")
            throw error
        }
        let receipt = "已授权文件夹：\(grant.name)（ID：\(grant.id)）。未扫描或写入文件；可在对话中要求查找文件名、新增文件或撤销授权。"
        updateFolderSelection(request, state: .succeeded, message: receipt)
        messages.append(.receipt(summary: receipt))
    }

    func cancelFolderSelection(_ request: UUID) {
        guard tools?.folderSelectionRequest == request else { return }
        tools?.folderSelectionRequest = nil
        updateFolderSelection(request, state: .notStarted, message: "已取消选择，没有增加文件夹授权。")
    }

    private func updateFolderSelection(_ request: UUID, state: ConfirmationResult.State, message: String) {
        guard let owner = turns.firstIndex(where: { $0.confirmationResults?.contains(where: { $0.proposalID == request }) == true }),
              var results = turns[owner].confirmationResults,
              let index = results.firstIndex(where: { $0.proposalID == request }) else { return }
        results[index].state = state
        results[index].message = message
        let id = turns[owner].id
        ChatTurn.updateConfirmation(id, results: results, in: &turns)
        save()
    }

    func savePending() {
        guard pendingReadable, let file = files?.pending, let tools else { return }
        do { try JSONEncoder().encode(tools.pending.filter(\.persists)).write(to: file, options: .atomic) }
        catch { self.error = "待确认修改没能保存到手机：\(error.localizedDescription)" }
    }

    // MARK: - Confirmation

    func confirm(ids: Set<UUID>? = nil) {
        guard !working, historyReadable, pendingReadable, let files, let journal = confirmationJournal,
              let tools, !tools.pending.isEmpty else { return }
        if let ids, !ids.isSubset(of: Set(tools.pending.map(\.id))) {
            error = "待确认项已改变，请核对当前卡片后再确认。本次没有执行。"
            return
        }
        let selected = tools.pending.filter { ids == nil || ids!.contains($0.id) }
        guard !selected.isEmpty else { return }
        guard selected.count <= 1 || !selected.contains(where: \.requiresSoleConfirmation) else {
            error = "此操作须单独确认；本批没有执行，所有提案均已保留。"
            return
        }
        let hasDates = selected.contains {
            switch $0.kind {
            case .add(let item): item.packageExpiry != nil || item.plannedUseBy != nil
            case .setDate(_, _, let date): date != nil
            default: false
            }
        }
        let hasReminders = selected.contains {
            switch $0.kind {
            case .reminder, .cancelReminder, .taskPlan, .taskAction, .taskSharing: return true
            default: return false
            }
        }
        let startsNotifications = selected.contains {
            switch $0.kind {
            case .reminder, .taskAction(_, .resume, _), .taskAction(_, .reopen, _): return true
            case .taskPlan(let value, _): return value.status == .active
            default: return false
            }
        }
        // Consume the persisted authorization queue before writes. An interrupted commit must
        // never reappear as a fresh Add proposal after relaunch.
        let initial = selected.map { $0.result(.notStarted, "\($0.title)：未开始执行。") }
        let id: UUID
        do { id = try journal.begin(ids: selected.map(\.id), titles: selected.map(\.title), results: initial) }
        catch { self.error = error.localizedDescription; return }
        do {
            let selectedIDs = Set(selected.map(\.id))
            try JSONEncoder().encode(tools.pending.filter { $0.persists && !selectedIDs.contains($0.id) }).write(to: files.pending, options: .atomic)
            let turn = ChatTurn(id: id, question: "确认操作", receipts: initial.map(\.message), confirmationIDs: [id], confirmationResults: initial)
            try files.saveTurns(turns + [turn])
            turns.append(turn)
            confirmationID = id
            error = nil
        } catch {
            selected.forEach { tools.removePending($0.id) }
            try? journal.progress(id, receipts: initial.map(\.message), finished: true, results: initial)
            self.error = "无法保存确认状态，本次没有执行修改；请核查后重新提议。"
            return
        }
        if let previous = tools.folderSelectionRequest,
           selected.contains(where: { if case .folder(.authorize) = $0.kind { return true }; return false }) {
            cancelFolderSelection(previous)
        }
        if selected.contains(where: \.requiresAsyncConfirmation) {
            working = true
            workingStage = "正在核对系统操作…"
            task = Task {
                defer { working = false; workingStage = ""; task = nil; confirmationID = nil }
                let results = await tools.confirmResults(ids: Set(selected.map(\.id))) { [self] results in
                    try recordConfirmationProgress(id, results: results)
                }
                finishConfirmation(id, results: results, tools: tools, hasDates: hasDates,
                                   hasReminders: hasReminders, startsNotifications: startsNotifications)
            }
            return
        }
        defer { confirmationID = nil }
        do { try recordConfirmationProgress(id, results: selected.map { $0.result(.running, "\($0.title)：正在执行。") }) }
        catch {
            selected.forEach { tools.removePending($0.id) }
            finishConfirmation(id, results: initial, tools: tools, hasDates: false, hasReminders: false, startsNotifications: false)
            self.error = "执行进度无法保存，本批没有开始修改。"
            return
        }
        let values = tools.confirmLocalResults(ids: Set(selected.map(\.id)))
        let results = selected.compactMap { proposal in values.first { $0.proposalID == proposal.id } }
        finishConfirmation(id, results: results, tools: tools, hasDates: hasDates,
                           hasReminders: hasReminders, startsNotifications: startsNotifications)
    }

    private func recordConfirmationProgress(_ id: UUID, results: [ConfirmationResult]) throws {
        try confirmationJournal?.progress(id, receipts: results.map(\.message), results: results)
        ChatTurn.updateConfirmation(id, results: results, in: &turns)
    }

    private func finishConfirmation(_ id: UUID, results: [ConfirmationResult], tools: ButlerTools, hasDates: Bool,
                                    hasReminders: Bool, startsNotifications: Bool) {
        var journalSaved = false
        do {
            try confirmationJournal?.progress(id, receipts: results.map(\.message), finished: true, results: results)
            journalSaved = true
        } catch { self.error = "执行结果未能写入恢复记录，请核查回执，不要重复操作。" }
        if (hasDates || hasReminders), results.contains(where: { $0.state == .succeeded }) {
            let reminders = tools.reminders
            let turnID = id
            let generation = historyGeneration
            Task {
                if hasDates || startsNotifications {
                    await NotificationManager.shared.requestAuthorizationIfUndecided()
                    reminders.rescheduleAll()
                }
                await reminders.waitForScheduling()
                let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                guard generation == historyGeneration, hasReminders,
                      let turn = turns.firstIndex(where: { $0.id == turnID }) else { return }
                var warnings: [String] = []
                if startsNotifications, status == .denied {
                    warnings.append("✗ 通知被关掉了，到点不会弹出提醒。可以在设置里打开。")
                }
                if let warning = reminders.scheduleWarning { warnings.append("提醒安排：\(warning)") }
                if !warnings.isEmpty {
                    turns[turn].receipts.append(contentsOf: warnings)
                    messages.append(.receipt(summary: warnings.joined(separator: "\n")))
                    save()
                }
            }
        }
        if let index = turns.firstIndex(where: { $0.id == id }) {
            turns[index].confirmationFinished = true
        }
        ChatTurn.updateConfirmation(id, results: results, in: &turns)
        messages.append(.receipt(summary: results.map { "[\($0.state.label)] \($0.message)" }.joined(separator: "\n")))
        do {
            try files?.saveTurns(turns)
            if journalSaved { try confirmationJournal?.acknowledge([id]) }
        } catch { self.error = "执行回执未能完整保存，下次打开会尝试恢复记录，不会重做操作。" }
    }

    func discard(ids: Set<UUID>? = nil) {
        guard !working, historyReadable, pendingReadable, let files, let tools, !tools.pending.isEmpty else { return }
        if let ids, !ids.isSubset(of: Set(tools.pending.map(\.id))) {
            error = "待确认项已改变，请核对当前卡片后再取消。"
            return
        }
        let selected = tools.pending.filter { ids == nil || ids!.contains($0.id) }
        guard !selected.isEmpty else { return }
        let selectedIDs = Set(selected.map(\.id))
        let remaining = tools.pending.filter { !selectedIDs.contains($0.id) }
        do { try JSONEncoder().encode(remaining.filter(\.persists)).write(to: files.pending, options: .atomic) }
        catch { self.error = "取消状态未能保存，待确认项已保留。"; return }
        tools.restorePending(remaining)
        let results = selected.map { $0.result(.notStarted, "\($0.title)：已取消，没有执行。") }
        turns.append(ChatTurn(question: "取消待确认修改", receipts: results.map(\.message), confirmationResults: results, confirmationFinished: true))
        messages.append(.receipt(summary: "用户取消了选中的待确认修改，没有保存；其余内容以get_pending_changes为准。"))
        save()
    }
}

extension ButlerChat {
    /// Who can see / who does / who is reminded, changed by a tap on the card. The butler is told, so it can
    /// offer to remember the correction as a household rule.
    func reviseFamily(of id: UUID, to sharing: TaskSharing) {
        guard !working, pendingReadable, let tools, let revised = tools.reviseFamily(of: id, to: sharing) else { return }
        messages.append(.receipt(summary: "用户在确认卡片上把「\(revised.title)」的家人设置改为：\(HouseholdStore.shared.names.summary(revised.taskFamily))。仍待确认。"))
        save()
    }
}
