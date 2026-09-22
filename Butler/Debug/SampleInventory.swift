#if DEBUG
import Foundation
import SwiftData

/// Launch with `--seed-sample-inventory` to fill an empty store with a realistic household,
/// written through the real repository so evidence and history look exactly like production.
@MainActor
enum SampleInventory {
    private struct Sample {
        let name: String
        let brand: String?
        let category: String?
        let quantity: Int
        let unit: String
        let storage: String?
        let boughtDaysAgo: Int
        let packageIn: Int?
        let plannedIn: Int?
    }

    private static let samples: [Sample] = [
        .init(name: "简爱原味酸奶", brand: "简爱", category: nil, quantity: 2, unit: "杯", storage: "冷藏", boughtDaysAgo: 12, packageIn: 0, plannedIn: nil),
        .init(name: "土鸡蛋", brand: nil, category: nil, quantity: 6, unit: "枚", storage: "冷藏", boughtDaysAgo: 20, packageIn: nil, plannedIn: 2),
        .init(name: "光明鲜牛奶", brand: "光明", category: nil, quantity: 1, unit: "瓶", storage: "冷藏", boughtDaysAgo: 0, packageIn: nil, plannedIn: nil),
        .init(name: "苹果", brand: nil, category: nil, quantity: 5, unit: "个", storage: "冷藏", boughtDaysAgo: 3, packageIn: nil, plannedIn: 5),
        .init(name: "奶酪片", brand: "妙可蓝多", category: nil, quantity: 1, unit: "袋", storage: "冷藏", boughtDaysAgo: 4, packageIn: 21, plannedIn: nil),
        .init(name: "李锦记蚝油", brand: "李锦记", category: nil, quantity: 1, unit: "瓶", storage: "冷藏", boughtDaysAgo: 30, packageIn: 120, plannedIn: nil),
        .init(name: "哈根达斯冰激凌", brand: "哈根达斯", category: nil, quantity: 1, unit: "个", storage: StorageLocation.ambiguousFridge, boughtDaysAgo: 0, packageIn: nil, plannedIn: 60),
        .init(name: "湾仔码头水饺", brand: "湾仔码头", category: nil, quantity: 2, unit: "袋", storage: "冷冻", boughtDaysAgo: 9, packageIn: 150, plannedIn: nil),
        .init(name: "冻虾仁", brand: nil, category: nil, quantity: 1, unit: "袋", storage: "冷冻", boughtDaysAgo: 15, packageIn: 90, plannedIn: nil),
        .init(name: "方便面", brand: nil, category: nil, quantity: 3, unit: "包", storage: "零食柜", boughtDaysAgo: 0, packageIn: nil, plannedIn: 90),
        .init(name: "布洛芬缓释胶囊", brand: "芬必得", category: "medicine", quantity: 1, unit: "盒", storage: "药箱", boughtDaysAgo: 18, packageIn: 6, plannedIn: nil),
        .init(name: "创可贴", brand: "邦迪", category: nil, quantity: 1, unit: "盒", storage: "药箱", boughtDaysAgo: 100, packageIn: 500, plannedIn: nil),
    ]

    static func seed(into container: ModelContainer) {
        let context = ModelContext(container)
        guard (try? context.fetchCount(FetchDescriptor<InventoryLot>())) == 0 else { return }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }

        var operations: [PlannedInventoryOperation] = []
        for sample in samples {
            let productID = UUID()
            var productEvidence = [ProposedFieldEvidence(fieldKey: .canonicalName, source: .userStated, confidence: 1, rawText: sample.name)]
            if sample.brand != nil { productEvidence.append(.init(fieldKey: .brand, source: .ocr, confidence: 0.9, rawText: sample.brand)) }
            if sample.category != nil { productEvidence.append(.init(fieldKey: .category, source: .modelInference, confidence: 0.9, rawText: nil)) }
            operations.append(.init(operationID: UUID(), operation: .createProduct(.init(
                productID: productID, canonicalName: sample.name, brand: sample.brand,
                categoryRawValue: sample.category, defaultUnit: nil, evidence: productEvidence))))

            var lotEvidence: [ProposedFieldEvidence] = [
                .init(fieldKey: .quantity, source: .userStated, confidence: 1, rawText: "\(sample.quantity)"),
                .init(fieldKey: .unit, source: .userStated, confidence: 1, rawText: sample.unit),
                .init(fieldKey: .purchasedAt, source: .userStated, confidence: 1, rawText: nil),
            ]
            if let storage = sample.storage {
                let source: EvidenceSourceKind = sample.category == "medicine" ? .habitInference : .userStated
                lotEvidence.append(.init(fieldKey: .storageLocation, source: source, confidence: 0.9, rawText: storage))
            }
            if sample.packageIn != nil {
                lotEvidence.append(.init(fieldKey: .packageExpiryDate, source: .ocr, confidence: 1, rawText: nil))
            }
            if sample.plannedIn != nil {
                lotEvidence.append(.init(fieldKey: .plannedUseByDate, source: .systemEstimate, confidence: 0.7, rawText: nil))
            }
            operations.append(.init(operationID: UUID(), operation: .addLot(.init(
                lotID: UUID(), productID: productID, quantity: sample.quantity, unit: sample.unit,
                purchasedAt: day(-sample.boughtDaysAgo),
                packageExpiryDate: sample.packageIn.map(day), estimatedExpiryDate: nil,
                plannedUseByDate: sample.plannedIn.map(day), storageLocation: sample.storage,
                evidence: lotEvidence))))
        }

        let plan = InventoryOperationPlan(schemaVersion: InventoryOperationPlan.currentSchemaVersion,
                                          planID: UUID(), inputID: UUID(), operations: operations, unresolvedFields: [])
        var receipts: [TrustedInventoryConfirmation] = []
        if case .requiresConfirmation(let requirements) = InventoryPolicy.evaluate(plan) {
            receipts = requirements.map { InventoryConfirmationAuthority.issue(for: $0) }
        }
        do {
            _ = try InventoryRepository(modelContainer: container).execute(plan, trustedConfirmations: receipts, actor: .system)
        } catch {
            assertionFailure("Sample inventory failed: \(error)")
        }
    }
}
#endif
