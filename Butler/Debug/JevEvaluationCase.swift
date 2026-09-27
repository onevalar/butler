#if DEBUG
import Foundation
import SwiftData

struct JevEvaluationCase: Codable, Identifiable {
    enum Action: String, Codable { case quantity, add, expiry, move }
    let id: String
    let title: String
    let input: String
    let action: Action
    let target: UUID
    let quantity: Int
    let value: String?
    var expected: String {
        switch action {
        case .quantity: "只把\(target == Self.cold ? "冷藏" : "冷冻")牛奶设为剩余 \(quantity) 瓶；其他字段和批次不变"
        case .add: "新增一批牛奶 \(quantity) 瓶，冷藏，包装日期和用户计划均为空；旧批次不变（保存后允许产品已有的系统默认计划）"
        case .expiry: "只把冷藏牛奶包装日期改为 \(value!)；其他字段和批次不变"
        case .move: "只把冷藏牛奶移到\(value!)；其他字段和批次不变"
        }
    }
    static let product = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let cold = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    static let frozen = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
    static let all: [Self] = [
        .init(id: "remaining", title: "普通：剩余数量", input: "冷藏的牛奶还剩1瓶，帮我改一下。", action: .quantity, target: cold, quantity: 1, value: nil),
        .init(id: "correction-target", title: "同名目标更正", input: "不是冷藏那批，是冷冻的牛奶还剩2瓶。冷藏那批不要动。", action: .quantity, target: frozen, quantity: 2, value: nil),
        .init(id: "consumed", title: "喝掉不是剩余", input: "冷藏的牛奶喝掉1瓶，帮我扣掉。", action: .quantity, target: cold, quantity: 2, value: nil),
        .init(id: "new-purchase", title: "新购不是更正", input: "又新买了2瓶牛奶，放冷藏。这是新的一批，旧的别动，没看包装日期。", action: .add, target: cold, quantity: 2, value: nil),
        .init(id: "quantity-correction", title: "更正不是新购", input: "冷藏牛奶之前数量记错了，应该是5瓶，不是新买。", action: .quantity, target: cold, quantity: 5, value: nil),
        .init(id: "explicit-date", title: "明确包装日期", input: "冷藏那批牛奶包装上写的到期日是2030年10月9日，请更正。", action: .expiry, target: cold, quantity: 3, value: "2030-10-09"),
        .init(id: "missing-date", title: "没有日期不能继承", input: "新买1瓶牛奶放冷藏，保质期没看见，不要沿用家里旧牛奶的日期。", action: .add, target: cold, quantity: 1, value: nil),
        .init(id: "move", title: "普通：只改位置", input: "把冷藏那批牛奶的位置更正为常温，数量和日期都不变。", action: .move, target: cold, quantity: 3, value: "常温")
    ]

    static func date(_ day: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)!
    }

    static func seed(_ container: ModelContainer) throws {
        let context = ModelContext(container)
        context.insert(CatalogProduct(id: product, canonicalName: "牛奶"))
        context.insert(InventoryLot(id: cold, productID: product, quantity: 3, unit: "瓶",
            packageExpiryDate: date("2030-10-01"), storageLocation: "冷藏"))
        context.insert(InventoryLot(id: frozen, productID: product, quantity: 6, unit: "瓶",
            packageExpiryDate: date("2030-10-15"), storageLocation: "冷冻"))
        try context.save()
    }

    /// Expectations are declared above, not derived from tool output or model prose.
    func proposalMatches(_ pending: [PendingChange]) -> Bool {
        guard pending.count == 1 else { return false }
        switch (action, pending[0].kind) {
        case (.quantity, .setQuantity(let lot, let count)): return lot.id == target && count == quantity
        case (.add, .add(let item)):
            return item.name == "牛奶" && item.quantity == quantity && item.unit == "瓶"
                && item.storage == "冷藏" && item.packageExpiry == nil && item.plannedUseBy == nil
        case (.expiry, .setDate(let lot, let kind, let date)):
            return lot.id == target && kind == .packageExpiry && date?.isoDay == value
        case (.move, .move(let lot, let location)): return lot.id == target && location == value
        default: return false
        }
    }

    func stateMatches(before: [JevEvaluationLot], after: [JevEvaluationLot]) -> Bool {
        var expected = before
        if action == .add {
            let oldIDs = Set(before.map(\.id))
            guard after.filter({ oldIDs.contains($0.id) }) == before else { return false }
            let added = after.filter { !oldIDs.contains($0.id) }
            guard added.count == 1, let lot = added.first else { return false }
            return lot.name == "牛奶" && lot.quantity == quantity && lot.unit == "瓶"
                && lot.storage == "冷藏" && lot.expiry == nil && lot.state == "active"
        }
        guard let i = expected.firstIndex(where: { $0.id == target }) else { return false }
        switch action {
        case .quantity: expected[i].quantity = quantity
        case .expiry: expected[i].expiry = value
        case .move: expected[i].storage = value
        case .add: break
        }
        return expected == after
    }
}

struct JevEvaluationLot: Codable, Equatable {
    let id: UUID
    let name: String
    var quantity: Int
    let unit: String
    var storage: String?
    var expiry: String?
    let planned: String?
    let state: String

    @MainActor static func read(_ container: ModelContainer) throws -> [Self] {
        let context = ModelContext(container)
        let products = try context.fetch(FetchDescriptor<CatalogProduct>())
        return try context.fetch(FetchDescriptor<InventoryLot>()).map { lot in
            Self(id: lot.id, name: products.first { $0.id == lot.productID }?.canonicalName ?? "",
                 quantity: lot.quantity, unit: lot.unit, storage: lot.storageLocation,
                 expiry: lot.packageExpiryDate?.isoDay, planned: lot.plannedUseByDate?.isoDay, state: lot.stateRawValue)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
#endif
