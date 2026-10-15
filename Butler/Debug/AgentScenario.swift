#if DEBUG
import Foundation

/// Fixed outcome expectations, shared by scripted integration and opt-in model evaluations.
/// Inputs are fictional. Expected state is never inferred from an assistant's answer.
struct AgentScenario: Identifiable, Codable {
    enum Input: Codable { case say(String), confirm, discard }
    enum Family: String, Codable { case original, personal, reassigned }
    struct Task: Codable {
        var existing = false
        var text: String
        var day: Int
        var period: ArrangementPeriod
        var family: Family = .personal
        var revision = 1
    }
    enum Proposal: Codable {
        case none, quantity(UUID, Int), task(Task), travelAccess(Bool)
    }
    struct Expected: Codable {
        var quantities: [UUID: Int] = [:]
        var storedTask: Task?
        var pending: Proposal = .none
        var keepProposalIdentity = false
        var travelAllowed = false
    }
    struct Step: Codable {
        let input: Input
        let expected: Expected
    }
    let id: String
    let title: String
    let steps: [Step]

    static let product = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
    static let cold = UUID(uuidString: "A0000000-0000-0000-0000-000000000011")!
    static let frozen = UUID(uuidString: "A0000000-0000-0000-0000-000000000012")!
    static let sharedTask = UUID(uuidString: "A0000000-0000-0000-0000-000000000021")!
    static let me = UUID(uuidString: "A0000000-0000-0000-0000-000000000031")!
    static let baby = UUID(uuidString: "A0000000-0000-0000-0000-000000000032")!
    static let lin = UUID(uuidString: "A0000000-0000-0000-0000-000000000033")!

    static var all: [Self] {
        let tomorrow = Task(text: "买面包", day: 1, period: .afternoon)
        var later = tomorrow; later.day = 2
        let shifted = Task(existing: true, text: "买水", day: 2, period: .day, family: .original)
        var savedShifted = shifted; savedShifted.revision = 2
        var renamed = savedShifted; renamed.text = "买面包"
        var savedRenamed = renamed; savedRenamed.revision = 3
        let reassigned = Task(existing: true, text: "买水", day: 1, period: .morning, family: .reassigned)
        var savedReassigned = reassigned; savedReassigned.revision = 2
        return [
            .init(id: "fuzzy-time-correction", title: "模糊日期改口，确认前保持同一事项", steps: [
                .init(input: .say("明天下午提醒我买面包，只有我看，不设置具体几点。"), expected: .init(pending: .task(tomorrow))),
                .init(input: .say("刚才那件事放到后天下午，还是不定几点。"), expected: .init(pending: .task(later), keepProposalIdentity: true)),
                .init(input: .confirm, expected: .init(storedTask: later))
            ]),
            .init(id: "inventory-correction", title: "数量更正不产生新购买或影响其他批次", steps: [
                .init(input: .say("冷藏那批牛奶还剩两瓶，帮我改一下。"), expected: .init(pending: .quantity(cold, 2))),
                .init(input: .say("数错了，刚才那批其实剩五瓶，不是新买的。"), expected: .init(pending: .quantity(cold, 5), keepProposalIdentity: true)),
                .init(input: .confirm, expected: .init(quantities: [cold: 5]))
            ]),
            .init(id: "saved-task-partial-update", title: "连续修改日期和文字，保留身份及家人设置", steps: [
                .init(input: .say("把已经保存的买水安排改到后天，不指定时间，其他都别变。"), expected: .init(pending: .task(shifted))),
                .init(input: .confirm, expected: .init(storedTask: savedShifted)),
                .init(input: .say("这条内容改成买面包，其他不变。"), expected: .init(storedTask: savedShifted, pending: .task(renamed))),
                .init(input: .confirm, expected: .init(storedTask: savedRenamed))
            ]),
            .init(id: "family-assignee-only", title: "只调整负责人，不替用户改通知对象或可见范围", steps: [
                .init(input: .say("已经保存的买水安排交给小林负责，只改负责人，提醒对象和谁能看都保持原样。"), expected: .init(pending: .task(reassigned))),
                .init(input: .confirm, expected: .init(storedTask: savedReassigned))
            ]),
            .init(id: "permission-denied", title: "拒绝地点许可后不定位、不创建定时替代品", steps: [
                .init(input: .say("我现在在家，用当前位置设置家，以后到家提醒我拿快递。"), expected: .init(pending: .travelAccess(true))),
                .init(input: .discard, expected: .init()),
                .init(input: .say("暂时不要获取位置，也别替我改成定时提醒。"), expected: .init())
            ]),
            .init(id: "permission-granted-boundary", title: "地点对话许可不等于定位和通知许可", steps: [
                .init(input: .say("允许这次对话按需使用地点资料，先不要获取当前位置或创建提醒。"), expected: .init(pending: .travelAccess(true))),
                .init(input: .confirm, expected: .init(travelAllowed: true)),
                .init(input: .say("查看有没有保存家，其他先不操作。"), expected: .init(travelAllowed: true))
            ])
        ]
    }
}

struct AgentScenarioReport: Codable {
    struct Snapshot: Codable {
        let inventory: [JevEvaluationLot]
        let tasks: [TimedReminder]
        let pending: [PendingChange]
        let travelAllowed: Bool
    }
    struct Step: Codable {
        let index: Int
        let input: AgentScenario.Input
        var before: Snapshot?
        var after: Snapshot?
        var checks: [String: Bool] = [:]
        var modelRounds = 0
        var toolCalls = 0
        var blockedTools: [String] = []
        var firstActionableSeconds: Double?
        var seconds = 0.0
        var error: String?
        var passed: Bool { error == nil && blockedTools.isEmpty && !checks.isEmpty && checks.values.allSatisfy { $0 } }
    }
    let schema = 1
    let scenario: AgentScenario
    let mode: String
    let startedAt: Date
    var steps: [Step] = []
    var passed: Bool { steps.count == scenario.steps.count && steps.allSatisfy(\.passed) }

    func export() throws -> Data {
        struct Export: Encodable { let passed: Bool; let result: AgentScenarioReport }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Export(passed: passed, result: self))
    }
}
#endif
