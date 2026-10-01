import Foundation

@MainActor final class ContactsStore {
    struct Operation: Codable {
        enum State: String, Codable { case attempted, verified, closedUnverified }
        let id: UUID
        var contactID: String?
        var state: State
    }
    private let device: any ContactsDevice
    private let file: URL
    private var failed = false
    private var busy = false
    private var generation = UUID()
    private var candidates: [String: ContactCandidate] = [:]
    private var selections: [UUID: ContactSelection] = [:]
    private var consumed: Set<UUID> = []
    private var journal: [Operation] = []
    private(set) var allowed = false
    var access: ContactAccess { device.access }

    init(file: URL, device: any ContactsDevice, preparationFailed: Bool = false) {
        self.file = file; self.device = device; failed = preparationFailed
        guard !failed else { return }
        do { journal = try JSONDecoder().decode([Operation].self, from: Data(contentsOf: file)) }
        catch {
            let e = error as NSError
            failed = e.domain != NSCocoaErrorDomain || e.code != NSFileReadNoSuchFileError
        }
    }
    nonisolated deinit {}
    func ready() throws {
        guard !failed, allowed else { throw ContactFailure("通讯录是可选能力；仅在需要时确认对话访问许可，未启用不影响其他功能。记录不可读时停止访问。") }
        guard access == .limited || access == .full else { throw ContactFailure("系统未允许通讯录访问。可在系统设置调整，不会自动再次请求或扩大权限。") }
        try Task.checkCancellation()
    }
    func search(_ query: String) throws -> [ContactCandidate] {
        try ready()
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(name.count) else { throw ContactFailure("请提供1–80字的具体姓名；不支持空白查询或导出通讯录。") }
        let result = try device.search(name, limit: 21)
        guard result.count <= 20 else { throw ContactFailure("匹配超过20人，请缩小姓名范围；没有返回整本通讯录。") }
        candidates = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return result
    }
    func candidate(_ id: String) throws -> ContactCandidate {
        try ready()
        guard let value = candidates[id] else { throw ContactFailure("请先按姓名查询，并从本次候选中选择联系人，不按同名替代。") }
        return value
    }
    func updateProposal(token: UUID, values: [ContactValue]) throws -> ContactChange {
        try ready()
        guard let before = selections[token] else { throw ContactFailure("字段读取凭据已失效，请重新选择并确认读取。") }
        try before.field.validate(values)
        guard values != before.values else { throw ContactFailure("该字段没有变化，不需要写入。") }
        return .update(before, values)
    }
    func createProposal(_ draft: ContactDraft) throws -> ContactChange {
        try ready(); try draft.validate()
        let matches = try device.search(draft.name, limit: 21)
        guard matches.count <= 20 else { throw ContactFailure("同名候选过多，请先核对已有联系人。") }
        return .create(draft, existingIDs: matches.map(\.id).sorted())
    }
    func operations() throws -> [Operation] { try ready(); return journal }

    func apply(_ change: ContactChange, operationID: UUID) async throws -> String {
        if case .access(false) = change {
            allowed = false; generation = UUID(); candidates = [:]; selections = [:]
            return "已关闭后续通讯录访问，其他功能不受影响；不会删除联系人，已发送内容和历史无法撤回。"
        }
        guard !busy, !failed else { throw ContactFailure("通讯录操作仍在进行或记录不可读，本次未开始。") }
        busy = true; defer { busy = false }
        try Task.checkCancellation()
        if case .access(true) = change {
            let expected = generation
            try await device.authorize()
            try Task.checkCancellation()
            guard expected == generation else { throw ContactFailure("等待授权期间对话许可已关闭。") }
            guard access == .limited || access == .full else { throw ContactFailure("未取得通讯录权限，其他功能仍可正常使用。") }
            allowed = true
            return "已允许本次运行按需查询获准联系人；只发送候选姓名/单位，详细字段另行选择确认，重启需重新许可。系统访问范围：\(access.rawValue)。"
        }
        try ready()
        if consumed.contains(operationID) || journal.contains(where: { $0.id == operationID }) {
            return "此确认已有记录，未重复读取或写入；旧回执不是当前通讯录状态。"
        }
        switch change {
        case .read(let candidate, let field):
            let selection = try device.read(candidate.id, field: field)
            guard selection.candidate == candidate else { throw ContactFailure("联系人身份资料已变化，请重新查询选择。") }
            // Bound detailed output too; never truncate a list and then use it as a replacement baseline.
            try field.validate(selection.values)
            let token = UUID(); selections[token] = selection; consumed.insert(operationID)
            struct Result: Encodable { let token: UUID; let selection: ContactSelection }
            return String(decoding: try JSONEncoder().encode(Result(token: token, selection: selection)), as: UTF8.self)
        case .closeUnknown(let id):
            guard let i = journal.firstIndex(where: { $0.id == id && $0.state == .attempted }) else {
                throw ContactFailure("没有这项待人工核对的操作。")
            }
            var values = journal; values[i].state = .closedUnverified; try save(values)
            consumed.insert(operationID)
            return "已按人工确认结束等待，仍标记未核实；没有重试、回滚或宣称原操作成功。"
        case .create, .update: break
        default: throw ContactFailure("不支持的通讯录操作。")
        }
        guard !journal.contains(where: { $0.state == .attempted }) else {
            throw ContactFailure("有结果未知的写入，请先在系统通讯录人工核对并确认结束等待，防止重复创建或覆盖。查询仍可使用。")
        }
        switch change {
        case .create(let draft, let expected):
            guard try createProposal(draft) == .create(draft, existingIDs: expected) else {
                throw ContactFailure("同名候选已变化，请重新核对，不重复创建。")
            }
        case .update(let before, let values):
            try before.field.validate(values)
            guard try device.read(before.candidate.id, field: before.field) == before else {
                throw ContactFailure("联系人字段已被外部修改或无权读取，请重新读取并确认，不覆盖新值。")
            }
        default: break
        }
        var operation = Operation(id: operationID, contactID: nil, state: .attempted)
        try save(journal + [operation]) // Before any external side effect; never auto-resume this record.
        do {
            switch change {
            case .create(let draft, _):
                operation.contactID = try device.create(draft)
                try replace(operation)
                for field in ContactField.allCases {
                    guard try device.read(operation.contactID!, field: field).values == draft.values(field) else {
                        throw ContactFailure("新联系人读回不一致。")
                    }
                }
            case .update(let before, let values):
                operation.contactID = before.candidate.id; try replace(operation)
                try device.update(before, values: values)
                guard try device.read(before.candidate.id, field: before.field).values == values else {
                    throw ContactFailure("字段读回不一致。")
                }
                selections = selections.filter { $0.value.candidate.id != before.candidate.id }
            default: break
            }
            operation.state = .verified; try replace(operation)
            return "已写入并读回核对指定字段；联系人编号：\(operation.contactID ?? "未知")。其他字段未要求修改。"
        } catch {
            throw ContactFailure("操作\(operationID)：写入可能已生效，结果未知；未重试。请在系统通讯录核对后确认结束等待，再提出新修改。")
        }
    }
    private func replace(_ value: Operation) throws { try save(journal.map { $0.id == value.id ? value : $0 }) }
    private func save(_ values: [Operation]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: file, options: .atomic); journal = values
    }
}
