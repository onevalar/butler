import Foundation

struct HealthFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Deliberately excludes diagnoses, clinical records, heart rate and medication.
enum HealthMetric: String, Codable, CaseIterable, Sendable {
    case steps, walkingDistance, activeEnergy, water, dietaryEnergy, protein, carbohydrates, fat

    var writable: Bool { ![.steps, .walkingDistance, .activeEnergy].contains(self) }
    var label: String {
        switch self {
        case .steps: "步数"
        case .walkingDistance: "步行和跑步距离"
        case .activeEnergy: "活动能量"
        case .water: "饮水"
        case .dietaryEnergy: "膳食能量"
        case .protein: "蛋白质"
        case .carbohydrates: "碳水化合物"
        case .fat: "脂肪"
        }
    }
    var unit: String {
        switch self {
        case .steps: "count"
        case .walkingDistance: "m"
        case .activeEnergy, .dietaryEnergy: "kcal"
        case .water: "mL"
        case .protein, .carbohydrates, .fat: "g"
        }
    }
    func canonical(_ value: Double, unit input: String) throws -> Double {
        let scale: Double
        switch (self, input) {
        case (_, unit): scale = 1
        case (.water, "L"): scale = 1000
        case (.activeEnergy, "kJ"), (.dietaryEnergy, "kJ"): scale = 1 / 4.184
        case (.protein, "mg"), (.carbohydrates, "mg"), (.fat, "mg"): scale = 0.001
        case (.walkingDistance, "km"): scale = 1000
        default: throw HealthFailure("单位与数据类型不匹配，不会把杯、份或食物重量猜成营养数值。")
        }
        let result = value * scale
        guard result.isFinite, result > 0 else { throw HealthFailure("健康记录的数值必须为有限的正数。") }
        return result
    }
}

struct HealthRange: Codable, Equatable, Sendable {
    let start: Date
    let end: Date // Exclusive.
    func validate(now: Date) throws {
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
              start < end, end <= now, end.timeIntervalSince(start) <= 31 * 86400 else {
            throw HealthFailure("查询须为明确的过去时间范围，结束时间不包含在内，每次最多31天。")
        }
    }
    var label: String {
        let format = ISO8601DateFormatter()
        return "\(format.string(from: start)) 至 \(format.string(from: end))（不含结束时刻）"
    }
}

struct HealthEntry: Codable, Equatable, Sendable {
    let metric: HealthMetric
    let value: Double // Canonical unit, never an estimate from an inventory item.
    let date: Date
    func validate(now: Date) throws {
        guard metric.writable, date.timeIntervalSince1970.isFinite, date <= now else {
            throw HealthFailure("只允许记录已经发生、用户明确给出数值的饮水或营养，不写未来计划或设备活动数据。")
        }
        _ = try metric.canonical(value, unit: metric.unit)
    }
    var label: String { "\(metric.label) \(value) \(metric.unit)，\(ISO8601DateFormatter().string(from: date))" }
}

enum HealthChange: Codable, Equatable {
    case summary([HealthMetric], HealthRange)
    case ownRecords(HealthMetric, HealthRange)
    case create(HealthEntry)
    case correct(UUID, HealthEntry) // Exact immutable HealthKit sample UUID, not a guessed title.
    case delete(UUID, HealthMetric)
    case verify(UUID)
    case closeVerification(UUID)

    func validate(now: Date = .now) throws {
        switch self {
        case .summary(let metrics, let range):
            guard !metrics.isEmpty, metrics.count <= HealthMetric.allCases.count,
                  Set(metrics).count == metrics.count else { throw HealthFailure("请选择不重复的健康数据类型。") }
            try range.validate(now: now)
        case .ownRecords(let metric, let range):
            guard metric.writable else { throw HealthFailure("Butler不写入这个类型。") }
            try range.validate(now: now)
        case .create(let entry), .correct(_, let entry): try entry.validate(now: now)
        case .delete(_, let metric):
            guard metric.writable else { throw HealthFailure("只能删除Butler创建的饮水或营养记录。") }
        case .verify, .closeVerification: break
        }
    }
    var readTypes: Set<HealthMetric> {
        switch self {
        case .summary(let metrics, _): Set(metrics)
        case .ownRecords(let metric, _), .delete(_, let metric): [metric]
        case .correct(_, let entry): [entry.metric]
        case .create, .verify, .closeVerification: []
        }
    }
    var writeTypes: Set<HealthMetric> {
        switch self {
        case .create(let entry), .correct(_, let entry): [entry.metric]
        case .delete(_, let metric): [metric]
        default: []
        }
    }
}

/// Only these opaque identities enter the device-local recovery journal: no dates or quantities.
struct HealthWriteToken: Codable, Equatable {
    enum Action: String, Codable { case save, delete }
    let action: Action
    let sampleID: UUID
    let syncID: UUID
    let version: Int
}

struct HealthLocalResult {
    let receipt: String // Safe for ordinary conversation history. Never native health values.
    let localText: String? // Display only: never Codable, a tool output, or model context.
}

@MainActor protocol HealthDevice {
    var available: Bool { get }
    func authorize(read: Set<HealthMetric>, write: Set<HealthMetric>) async throws
    func canWrite(_ metric: HealthMetric) -> Bool
    func summary(_ metrics: [HealthMetric], range: HealthRange) async throws -> String
    func ownRecords(_ metric: HealthMetric, range: HealthRange) async throws -> String
    func prepare(_ change: HealthChange, operationID: UUID) async throws -> HealthWriteToken
    func commit(_ token: HealthWriteToken) async throws
    func discard(_ token: HealthWriteToken)
    func verify(_ token: HealthWriteToken) async throws -> Bool
}
