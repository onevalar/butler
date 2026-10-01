import Foundation

@MainActor final class HomeStore {
    struct Operation: Codable {
        let id: UUID
        let homeID: UUID
        let actions: [HomeAction]
        var attempted = 0
        var matched = 0
        var finished = false
    }
    private let device: any HomeDevice
    private let file: URL
    private var failed = false
    private var busy = false
    private var generation = UUID()
    private(set) var allowed = false // Session-local: relaunch requires a new conversation consent.
    private var journal: [Operation] = []

    init(file: URL, device: any HomeDevice, preparationFailed: Bool = false) {
        self.file = file; self.device = device; failed = preparationFailed
        guard !failed else { return }
        do { journal = try JSONDecoder().decode([Operation].self, from: Data(contentsOf: file)) }
        catch {
            let e = error as NSError
            failed = e.domain != NSCocoaErrorDomain || e.code != NSFileReadNoSuchFileError
        }
    }
    nonisolated deinit {}
    private func ready(_ expected: UUID? = nil) throws {
        guard !failed, allowed, expected == nil || expected == generation else {
            throw HomeFailure("请先确认允许本次运行期间的家庭对话访问；许可已关闭或操作记录不可读时停止访问。")
        }
    }
    func homes() throws -> [(UUID, String)] { try ready(); return try device.homes() }
    func snapshot(_ id: UUID) async throws -> HomeSnapshot {
        try ready(); let consent = generation
        let value = try await device.snapshot(id)
        try ready(consent); try Task.checkCancellation()
        return value
    }
    func read(homeID: UUID, controlID: UUID) async throws -> Double? {
        try ready(); let consent = generation
        let value = try await device.read(homeID: homeID, controlID: controlID)
        try ready(consent); try Task.checkCancellation()
        return value
    }
    func operations() throws -> [Operation] { try ready(); return journal }

    static func plan(_ home: HomeSnapshot, controlID: UUID?, target: Double?, sceneID: UUID?) throws -> HomePlan {
        let plan: HomePlan
        if let sceneID, controlID == nil, target == nil {
            guard let scene = home.scenes.first(where: { $0.id == sceneID }), scene.unsupportedActions == 0 else {
                throw HomeFailure("场景不存在或包含无法核验的动作，不能忽略这些动作后执行。")
            }
            plan = .init(homeID: home.id, homeName: home.name, sceneID: scene.id, sceneName: scene.name, actions: scene.actions)
        } else if let controlID, let target, sceneID == nil, let control = home.controls.first(where: { $0.id == controlID }) {
            plan = .init(homeID: home.id, homeName: home.name, sceneID: nil, sceneName: nil, actions: [.init(control: control, target: target)])
        } else { throw HomeFailure("请按查询返回的准确家庭/属性或场景编号指定唯一操作。") }
        try plan.validate()
        return plan
    }
    private func check(_ plan: HomePlan, consent: UUID) async throws {
        try ready(consent)
        let home = try await device.snapshot(plan.homeID)
        try ready(consent); try Task.checkCancellation()
        let current = try Self.plan(home, controlID: plan.sceneID == nil ? plan.actions.first?.control.id : nil,
            target: plan.sceneID == nil ? plan.actions.first?.target : nil, sceneID: plan.sceneID)
        guard current.signature == plan.signature else { throw HomeFailure("家庭、设备或场景内容已变化，请重新查询并确认。") }
    }
    func apply(_ change: HomeChange, operationID: UUID, soleConfirmation: Bool) async throws -> String {
        if case .access(false) = change {
            allowed = false; generation = UUID(); device.disconnect()
            return "已关闭后续家庭对话访问；正在发出的指令不能撤回，历史对话内容不会自动删除。"
        }
        guard !busy, !failed else { throw HomeFailure("家庭操作仍在执行或记录不可读，本次未开始。") }
        busy = true; defer { busy = false }
        try Task.checkCancellation()
        if case .access(true) = change {
            let consent = generation
            try await device.connect()
            try Task.checkCancellation()
            guard consent == generation else { throw HomeFailure("等待授权期间访问已关闭。") }
            allowed = true
            return "已允许本次运行期间按请求把家庭名称、房间、设备及状态用于当前模型；重启后需重新确认，控制设备仍逐次确认。"
        }
        try ready(); let consent = generation
        guard case .execute(let plan) = change else { return "" }
        try plan.validate()
        guard !plan.risky || soleConfirmation else { throw HomeFailure("高风险家庭操作必须单独确认，不能与任何其他提案一起执行。") }
        if journal.contains(where: { $0.id == operationID }) {
            return "这次确认已有操作记录，没有重新发送。请查询回执和当前设备状态，不把旧结果当作现在的状态。"
        }
        try await check(plan, consent: consent)
        var operation = Operation(id: operationID, homeID: plan.homeID, actions: plan.actions)
        try save(journal + [operation])
        do {
            for action in plan.actions {
                try await check(plan, consent: consent)
                // Each attempted command is durable before the await. Never resume commands after a kill.
                operation.attempted += 1; try replace(operation)
                try await device.write(homeID: plan.homeID, action: action)
                try ready(consent); try Task.checkCancellation()
                let value = try await device.read(homeID: plan.homeID, controlID: action.control.id)
                try ready(consent)
                guard value == action.target else { throw HomeFailure("目标值读回不一致或不可读。") }
                operation.matched += 1; try replace(operation)
            }
            operation.finished = true; try replace(operation)
            return "已逐项发送并读回\(operation.matched)项目标设置。目标值匹配不证明门已到位、设备实际动作完成或无人受影响；请按需查询实际状态。场景非原子执行。"
        } catch {
            throw HomeFailure("操作\(operationID.uuidString)：尝试\(operation.attempted)项、目标读回匹配\(operation.matched)项；其余已停止。可能部分成功或结果未知，不自动重试、不反向回滚。请查询设备状态后再明确新的意图。")
        }
    }
    private func replace(_ operation: Operation) throws { try save(journal.map { $0.id == operation.id ? operation : $0 }) }
    private func save(_ values: [Operation]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: file, options: .atomic); journal = values
    }
}
