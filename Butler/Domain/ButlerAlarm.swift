import Foundation

/// Separate from a task: stopping an alarm never completes the thing it was reminding about.
struct ButlerAlarm: Codable, Equatable, Identifiable, Sendable {
    enum Rule: Codable, Equatable, Sendable {
        case once(Date)
        /// ISO weekdays: Monday = 1, Sunday = 7. Follows the device's local clock.
        case weekly(hour: Int, minute: Int, weekdays: [Int])
        case timer(seconds: Int)

        func validate(now: Date) throws {
            switch self {
            case .once(let date):
                guard date.timeIntervalSince1970.isFinite, date > now else {
                    throw AlarmFailure("响铃时间必须在未来，请重新确认时间")
                }
            case .weekly(let hour, let minute, let days):
                guard (0...23).contains(hour), (0...59).contains(minute), !days.isEmpty,
                      days.count <= 7, Set(days).count == days.count,
                      days.allSatisfy({ (1...7).contains($0) }) else {
                    throw AlarmFailure("重复闹钟需要有效时分和不重复的星期一至星期日")
                }
            case .timer(let seconds):
                guard (1...86_400).contains(seconds) else {
                    throw AlarmFailure("倒计时目前支持 1 秒至 24 小时")
                }
            }
        }

        var summary: String {
            switch self {
            case .once(let date):
                let f = DateFormatter()
                f.locale = Locale(identifier: "zh_CN")
                f.timeZone = .current
                f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
                return "\(f.string(from: date))，仅响一次（固定时刻）"
            case .weekly(let hour, let minute, let days):
                let names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
                let weekdays = days.sorted().compactMap { (1...7).contains($0) ? names[$0 - 1] : nil }.joined(separator: "、")
                return "每\(weekdays) \(String(format: "%02d:%02d", hour, minute))，跟随手机当地时间；不自动排除节假日"
            case .timer(let seconds): return "确认并获系统接受后开始倒计时 \(seconds) 秒"
            }
        }
    }

    enum Action: String, Codable, Sendable {
        case cancel, enable, stop, pause, resume
        var summary: String {
            switch self {
            case .cancel: "取消后续响铃，保留记录"
            case .enable: "重新启用响铃；倒计时将从头开始"
            case .stop: "停止本次响铃，不完成任务，也不取消每周重复规则"
            case .pause: "暂停正在进行的倒计时"
            case .resume: "继续已暂停的倒计时"
            }
        }
    }

    enum Change: Codable, Sendable {
        case set(id: UUID, title: String, rule: Rule, expectedRevision: Int?)
        case action(id: UUID, action: Action, expectedRevision: Int, expiresAt: Date)

        var id: UUID {
            switch self { case .set(let id, _, _, _), .action(let id, _, _, _): id }
        }
        var expectedRevision: Int? {
            switch self {
            case .set(_, _, _, let revision): revision
            case .action(_, _, let revision, _): revision
            }
        }
    }

    struct Operation: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case schedule, cancel, stop, pause, resume }
        let kind: Kind
        /// Old system IDs are retained until their removal is observed, even across another edit.
        var retiredIDs: [UUID]
    }

    let id: UUID
    var title: String
    var rule: Rule
    var revision: Int
    var systemID: UUID
    var enabled: Bool
    var operationID: UUID
    var operation: Operation?
    var lastError: String?
}

struct AlarmFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct SystemAlarm: Equatable, Sendable {
    enum State: String, Sendable { case scheduled, countdown, paused, alerting, unknown }
    let id: UUID
    let state: State
    var remainingSeconds: TimeInterval? = nil
}

/// Only this boundary touches AlarmKit; the journal and its failure tests also run without iOS.
@MainActor protocol AlarmDevice {
    var authorization: String { get }
    func authorize() async throws -> Bool
    func read() throws -> [SystemAlarm]
    func schedule(id: UUID, title: String, rule: ButlerAlarm.Rule) async throws
    func cancel(id: UUID) throws
    func stop(id: UUID) throws
    func pause(id: UUID) throws
    func resume(id: UUID) throws
}
