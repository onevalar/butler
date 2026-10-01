import Foundation
import HealthKit
import UIKit

@MainActor final class HealthKitDevice: HealthDevice {
    private let store = HKHealthStore()
    private struct Prepared {
        let sample: HKQuantitySample
        let original: HKQuantitySample?
    }
    private var prepared: [UUID: Prepared] = [:]
    private static let prefix = "com.anvalar.Butler.health."
    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    private func ready() throws {
        guard available, UIApplication.shared.isProtectedDataAvailable else {
            throw HealthFailure("请先解锁手机；当前设备可能不支持健康数据。")
        }
    }
    func authorize(read: Set<HealthMetric>, write: Set<HealthMetric>) async throws {
        try ready()
        guard UIApplication.shared.applicationState == .active else { throw HealthFailure("请保持小当家在前台，再确认健康操作。") }
        try await store.requestAuthorization(toShare: Set(write.map { type($0) }), read: Set(read.map { type($0) }))
        // Success means the authorization sheet finished, not that reading was granted.
    }
    func canWrite(_ metric: HealthMetric) -> Bool {
        available && store.authorizationStatus(for: type(metric)) == .sharingAuthorized
    }
    private func type(_ metric: HealthMetric) -> HKQuantityType {
        let identifier: HKQuantityTypeIdentifier
        switch metric {
        case .steps: identifier = .stepCount
        case .walkingDistance: identifier = .distanceWalkingRunning
        case .activeEnergy: identifier = .activeEnergyBurned
        case .water: identifier = .dietaryWater
        case .dietaryEnergy: identifier = .dietaryEnergyConsumed
        case .protein: identifier = .dietaryProtein
        case .carbohydrates: identifier = .dietaryCarbohydrates
        case .fat: identifier = .dietaryFatTotal
        }
        return HKQuantityType(identifier)
    }
    private func unit(_ metric: HealthMetric) -> HKUnit { HKUnit(from: metric.unit) }
    private func timePredicate(_ range: HealthRange) -> NSPredicate {
        // Exact [start,end) selection of sample start times; no hidden out-of-range reads.
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "%K >= %@", HKPredicateKeyPathStartDate, range.start as NSDate),
            NSPredicate(format: "%K < %@", HKPredicateKeyPathStartDate, range.end as NSDate)
        ])
    }
    private var localNotice: String {
        "仅本次在手机显示，不发送AI、不保存到对话历史或备份；重启后消失。无可读数据不等于零，可能尚无记录、权限受限或同步未完成。结果不是医疗判断。"
    }
    func summary(_ metrics: [HealthMetric], range: HealthRange) async throws -> String {
        try ready()
        var lines = ["健康摘要（本机）", range.label, "按此范围内开始的样本统计，跨边界样本未按时间比例拆分；可能不等于健康App按天显示的总量。"]
        for metric in metrics {
            try Task.checkCancellation()
            let query = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: type(metric), predicate: timePredicate(range)), options: .cumulativeSum)
            do {
                let result = try await query.result(for: store)
                let value = result?.sumQuantity()?.doubleValue(for: unit(metric))
                lines.append("\(metric.label)：" + (value.map { "\($0) \(metric.unit)（当前可读范围）" } ?? "没有可读取的数据"))
            } catch is CancellationError { throw CancellationError() }
            catch { lines.append("\(metric.label)：本次读取未完成，不能视为零。") }
        }
        try ready()
        return (lines + [localNotice]).joined(separator: "\n")
    }
    private func samples(_ metric: HealthMetric, predicate: NSPredicate, limit: Int) async throws -> [HKQuantitySample] {
        try ready()
        return try await HKSampleQueryDescriptor(predicates: [.quantitySample(type: type(metric), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\HKQuantitySample.startDate, order: .reverse)], limit: limit).result(for: store)
    }
    private func identity(_ sample: HKQuantitySample) -> (UUID, Int)? {
        guard sample.sourceRevision.source == HKSource.default(),
              let identifier = sample.metadata?[HKMetadataKeySyncIdentifier] as? String,
              identifier.hasPrefix(Self.prefix), let id = UUID(uuidString: String(identifier.dropFirst(Self.prefix.count))),
              let version = sample.metadata?[HKMetadataKeySyncVersion] as? NSNumber,
              version.intValue > 0, version.intValue < Int.max else { return nil }
        return (id, version.intValue)
    }
    func ownRecords(_ metric: HealthMetric, range: HealthRange) async throws -> String {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [timePredicate(range), HKQuery.predicateForObjects(from: HKSource.default())])
        let rows = try await samples(metric, predicate: predicate, limit: 101)
        let visible = rows.prefix(100).filter { identity($0) != nil }
        let lines = visible.map { sample in
            "编号 \(sample.uuid.uuidString) · \(metric.label) \(sample.quantity.doubleValue(for: unit(metric))) \(metric.unit) · \(ISO8601DateFormatter().string(from: sample.startDate))"
        }
        try ready()
        return (["Butler自己的记录（本机）", range.label] + lines
            + [rows.count > 100 ? "结果已截断，请缩短查询时间范围。" : "已列出本次可读取的匹配记录；空列表不证明记录不存在。", localNotice]).joined(separator: "\n")
    }
    private func original(_ id: UUID, metric: HealthMetric) async throws -> HKQuantitySample {
        let rows = try await samples(metric, predicate: HKQuery.predicateForObject(with: id), limit: 2)
        guard rows.count == 1, identity(rows[0]) != nil else {
            throw HealthFailure("原记录不可读取、已经改变或不是Butler创建的记录。不会重建或修改其他来源。")
        }
        return rows[0]
    }
    func prepare(_ change: HealthChange, operationID: UUID) async throws -> HealthWriteToken {
        try ready()
        let sample: HKQuantitySample
        let old: HKQuantitySample?
        let syncID: UUID
        let version: Int
        let action: HealthWriteToken.Action
        switch change {
        case .create(let entry), .correct(_, let entry):
            if case .correct(let id, _) = change {
                old = try await original(id, metric: entry.metric)
                let identity = identity(old!)!
                syncID = identity.0; version = identity.1 + 1
            } else { old = nil; syncID = operationID; version = 1 }
            sample = HKQuantitySample(type: type(entry.metric), quantity: HKQuantity(unit: unit(entry.metric), doubleValue: entry.value),
                start: entry.date, end: entry.date, metadata: [HKMetadataKeySyncIdentifier: Self.prefix + syncID.uuidString,
                    HKMetadataKeySyncVersion: version, HKMetadataKeyWasUserEntered: true])
            action = .save
        case .delete(let id, let metric):
            sample = try await original(id, metric: metric); old = sample
            let identity = identity(sample)!
            syncID = identity.0; version = identity.1; action = .delete
        default: throw HealthFailure("这项操作不写入健康记录。")
        }
        prepared[sample.uuid] = Prepared(sample: sample, original: old)
        return .init(action: action, sampleID: sample.uuid, syncID: syncID, version: version)
    }
    func discard(_ token: HealthWriteToken) { prepared.removeValue(forKey: token.sampleID) }
    func commit(_ token: HealthWriteToken) async throws {
        try ready()
        guard let pending = prepared[token.sampleID],
              store.authorizationStatus(for: pending.sample.quantityType) == .sharingAuthorized else {
            throw HealthFailure("写入权限或本次操作已失效。")
        }
        if let old = pending.original {
            guard let metric = HealthMetric.allCases.first(where: { type($0) == old.quantityType }) else { throw HealthFailure("类型不支持。") }
            _ = try await original(old.uuid, metric: metric) // Reject stale immutable IDs after confirmation.
        }
        try Task.checkCancellation()
        if token.action == .delete { try await store.delete(pending.sample) }
        else { try await store.save(pending.sample) }
    }
    func verify(_ token: HealthWriteToken) async throws -> Bool {
        try ready()
        guard token.action == .save else { return false }
        // Only exact own UUID + sync identity can resolve an interrupted write. Never recreate it.
        for metric in HealthMetric.allCases where metric.writable {
            let rows = try await samples(metric, predicate: HKQuery.predicateForObject(with: token.sampleID), limit: 2)
            if rows.count == 1, let identity = identity(rows[0]), identity.0 == token.syncID, identity.1 == token.version { return true }
        }
        return false
    }
}

extension HealthStore {
    static let shared: HealthStore = {
        let directory = URL.applicationSupportDirectory.appendingPathComponent("DeviceHealth", isDirectory: true)
        var failed = false
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            var excluded = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
        } catch { failed = true }
        return HealthStore(file: directory.appendingPathComponent("operations.json"), device: HealthKitDevice(), preparationFailed: failed)
    }()
}
