import Foundation

/// An allow-list of saved conversation fields. Never serializes proposals, drafts,
/// summaries, model credentials, derived collection cards or local health results.
struct SyncedChatTurn: Codable {
    let scope: ChatScope
    let id: UUID
    let question: String
    let answer: String
    let failed: Bool
    let receipts: [String]
    let date: Date
    let photos: [String]?
    let relatedScopeKeys: [String]?

    init(scope: ChatScope, turn: ChatTurn) {
        self.scope = scope; id = turn.id; question = turn.question; answer = turn.answer
        failed = turn.failed; receipts = turn.receipts; date = turn.date
        photos = turn.photos; relatedScopeKeys = turn.relatedScopeKeys
    }
    func validate() throws {
        let names = Set((0..<4).map { "\(id.uuidString)-\($0).jpg" })
        guard scope.key.utf8.count <= 200, question.utf8.count <= 100_000,
              answer.utf8.count <= 300_000, receipts.count <= 1000,
              photos.map({ $0.count <= 4 && Set($0).count == $0.count && Set($0).isSubset(of: names) }) ?? true,
              relatedScopeKeys.map({ $0.count <= 1000 && $0.allSatisfy { $0.utf8.count <= 200 } }) ?? true else {
            throw SyncFailure("对话内容或图片引用无效，未覆盖本机记录。")
        }
    }
    var turn: ChatTurn {
        ChatTurn(id: id, question: question, answer: answer, failed: failed, receipts: receipts,
                 date: date, photos: photos, relatedScopeKeys: relatedScopeKeys)
    }
}

/// A separate opt-in stream: a disabled stream is never snapshotted, fetched or imported.
/// Import only while all conversations are idle; do not overwrite an in-progress answer.
@MainActor final class ChatSyncData: SyncLocalData {
    nonisolated deinit {}

    let root: URL
    private let isWorking: () -> Bool
    private let didImport: (ChatScope) -> Void
    init(root: URL, isWorking: @escaping () -> Bool, didImport: @escaping (ChatScope) -> Void) {
        self.root = root; self.isWorking = isWorking; self.didImport = didImport
    }
    private func records() throws -> [UUID: SyncedChatTurn] {
        guard !isWorking() else { throw SyncFailure("对话正在处理，聊天历史将在本轮结束后同步；当前输入和待确认操作保留。") }
        var result: [UUID: SyncedChatTurn] = [:]
        for scope in try ChatSessionFiles.syncScopes(in: root) {
            let url = ChatSessionFiles(scope: scope, root: root).transcript
            if !FileManager.default.fileExists(atPath: url.path) { continue }
            let turns = try JSONDecoder().decode([ChatTurn].self, from: Data(contentsOf: url))
            for turn in turns {
                guard result[turn.id] == nil else { throw SyncFailure("本机对话编号重复，停止而非覆盖。") }
                let record = SyncedChatTurn(scope: scope, turn: turn)
                try record.validate(); result[turn.id] = record
            }
        }
        return result
    }
    func snapshot() throws -> [SyncRecord.Key: Data] {
        try Dictionary(uniqueKeysWithValues: records().map { (.init(kind: .chat, id: $0.key), try SyncRecord.encode($0.value)) })
    }
    func replace(_ key: SyncRecord.Key, expected: Data?, with payload: Data?) throws {
        guard key.kind == .chat else { throw SyncFailure("不是聊天同步记录。") }
        let records = try records(), old = records[key.id]
        guard try old.map(SyncRecord.encode) == expected else { throw SyncFailure("本机聊天刚发生变化，未覆盖。") }
        let incoming = try payload.map { try JSONDecoder().decode(SyncedChatTurn.self, from: $0) }
        if let incoming {
            try incoming.validate()
            guard incoming.id == key.id, old.map({ $0.scope == incoming.scope }) ?? true else {
                throw SyncFailure("聊天编号或所属会话不匹配。")
            }
        }
        guard let scope = incoming?.scope ?? old?.scope else { return }
        let files = ChatSessionFiles(scope: scope, root: root)
        var turns = FileManager.default.fileExists(atPath: files.transcript.path)
            ? try JSONDecoder().decode([ChatTurn].self, from: Data(contentsOf: files.transcript)) : []
        let previous = turns.first { $0.id == key.id }
        turns.removeAll { $0.id == key.id }
        if let incoming {
            var turn = incoming.turn
            // A local-only display card does not disappear when unchanged text is received.
            if previous?.question == turn.question, previous?.answer == turn.answer { turn.collection = previous?.collection }
            if previous?.question == turn.question, previous?.answer == turn.answer,
               previous?.receipts == turn.receipts, previous?.failed == turn.failed {
                turn.confirmationResults = previous?.confirmationResults
                turn.confirmationFinished = previous?.confirmationFinished
                turn.confirmationIDs = previous?.confirmationIDs
                turn.replyState = previous?.replyState
                turn.partialReply = previous?.partialReply
            }
            turns.append(turn)
        }
        turns.sort { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
        // Invalidate a possibly stale summary before publishing the new transcript. A crash
        // here may lose a derived summary, never original turns or an execution decision.
        if FileManager.default.fileExists(atPath: files.summary.path) { try FileManager.default.removeItem(at: files.summary) }
        try files.saveTurns(turns)
        didImport(scope)
    }
}
