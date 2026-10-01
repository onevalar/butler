import Foundation

struct HomeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct HomeControl: Codable, Equatable {
    enum Kind: String, Codable {
        case power, brightness, lock, garage, security, temperature, currentLock, currentDoor, currentSecurity, obstruction
        var readOnly: Bool { [.temperature, .currentLock, .currentDoor, .currentSecurity, .obstruction].contains(self) }
    }
    let id: UUID
    let accessoryID: UUID
    let room: String
    let accessory: String
    let service: String
    let kind: Kind
    let writable: Bool
    let risky: Bool
    let reachable: Bool
    var value: Double?
    let minimum: Double?
    let maximum: Double?
    let step: Double?

    var requiresSeparateConfirmation: Bool { risky || [.lock, .garage, .security].contains(kind) }
    var label: String { "\(room) / \(accessory) / \(service) / \(kind.rawValue)" }
    func validate(_ target: Double) throws {
        guard writable, reachable, target.isFinite else { throw HomeFailure("设备离线、只读或数值无效。") }
        guard [minimum, maximum, step].compactMap({ $0 }).allSatisfy(\.isFinite),
              step == nil || step! > 0 else { throw HomeFailure("设备属性范围无效。") }
        switch kind {
        case .power, .lock, .garage:
            guard target == 0 || target == 1 else { throw HomeFailure("此属性只支持0或1。") }
        case .brightness:
            guard (0...100).contains(target), target.rounded() == target else { throw HomeFailure("亮度须为0–100整数。") }
        case .security:
            guard (0...3).contains(target), target.rounded() == target else { throw HomeFailure("安防模式须为0–3。") }
        case .temperature, .currentLock, .currentDoor, .currentSecurity, .obstruction:
            throw HomeFailure("此状态只读，不能写入。")
        }
        if let minimum, target < minimum { throw HomeFailure("低于设备允许范围。") }
        if let maximum, target > maximum { throw HomeFailure("超过设备允许范围。") }
        if let step, step > 0 {
            let steps = (target - (minimum ?? 0)) / step
            guard abs(steps - steps.rounded()) < 0.000001 else { throw HomeFailure("不符合设备允许的步长。") }
        }
    }
    func targetLabel(_ target: Double) -> String {
        guard target.isFinite else { return "未知" }
        switch kind {
        case .power: return target == 1 ? "开启供电" : "关闭供电"
        case .brightness: return "亮度\(target)%"
        case .lock: return target == 1 ? "上锁" : "解锁（允许进入）"
        case .garage: return target == 1 ? "关闭车库门（注意夹伤风险）" : "打开车库门（允许进入）"
        case .security:
            guard (0...3).contains(target), target.rounded() == target else { return "未知模式" }
            return ["居家布防", "离家布防", "夜间布防", "撤防（关闭安防保护）"][Int(target)]
        default: return "只读状态\(target)"
        }
    }
}

struct HomeAction: Codable, Equatable {
    var control: HomeControl
    let target: Double
}
struct HomeScene: Codable, Equatable {
    let id: UUID
    let name: String
    let actions: [HomeAction]
    let unsupportedActions: Int
}
struct HomeSnapshot: Codable, Equatable {
    let id: UUID
    let name: String
    let rooms: [String]
    let controls: [HomeControl]
    let scenes: [HomeScene]
}
struct HomePlan: Codable, Equatable {
    let homeID: UUID
    let homeName: String
    let sceneID: UUID?
    let sceneName: String?
    let actions: [HomeAction]
    var risky: Bool { actions.contains { $0.control.requiresSeparateConfirmation } }

    func validate() throws {
        guard !actions.isEmpty, actions.count <= 20,
              Set(actions.map { $0.control.id }).count == actions.count else {
            throw HomeFailure("场景为空、超过20项或重复写同一属性，不能安全执行。")
        }
        guard !risky || actions.allSatisfy({ $0.control.requiresSeparateConfirmation }) else {
            throw HomeFailure("场景混合普通与高风险动作；请分别提议设备操作，不能整组确认。")
        }
        for action in actions { try action.control.validate(action.target) }
    }
    /// Exclude volatile reported values, but retain identity, names, capabilities and targets.
    var signature: String {
        var actions = actions
        for i in actions.indices { actions[i].control.value = nil }
        let canonical = HomePlan(homeID: homeID, homeName: homeName, sceneID: sceneID, sceneName: sceneName, actions: actions)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try! encoder.encode(canonical)).base64EncodedString()
    }
}
enum HomeChange: Codable {
    case access(Bool)
    case execute(HomePlan)
    var risky: Bool { if case .execute(let plan) = self { plan.risky } else { false } }
}

@MainActor protocol HomeDevice {
    func connect() async throws
    func disconnect()
    func homes() throws -> [(UUID, String)]
    func snapshot(_ id: UUID) async throws -> HomeSnapshot
    /// Writes exactly the supplied identity/value; must never execute a mutable native scene.
    func write(homeID: UUID, action: HomeAction) async throws
    func read(homeID: UUID, controlID: UUID) async throws -> Double?
}
