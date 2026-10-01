import Foundation
import SwiftData
import WidgetKit

/// Shares only bounded display rows, never grants the extension access to SwiftData or chat history.
@MainActor final class WidgetSnapshotPublisher {
    static let shared = WidgetSnapshotPublisher()
    private var container: ModelContainer?

    func configure(container: ModelContainer) {
        self.container = container
        refresh()
    }

    func refresh(now: Date = .now) {
        guard let container, let file = WidgetSnapshot.fileURL() else { return }
        let calendar = Calendar.current
        let snapshot: WidgetSnapshot
        do {
            let context = ModelContext(container)
            let products = try context.fetch(FetchDescriptor<CatalogProduct>())
            let byID = Dictionary(products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let lots = try context.fetch(FetchDescriptor<InventoryLot>())
            let facts = lots.filter { $0.state == .active }.map { LotFacts(lot: $0, product: byID[$0.productID], now: now, calendar: calendar) }
                .filter { !$0.quantityOnly && ($0.daysLeft.map { $0 <= 7 } ?? false) }
                .sorted {
                    if $0.governingDate != $1.governingDate { return ($0.governingDate ?? .distantFuture) < ($1.governingDate ?? .distantFuture) }
                    return $0.id.uuidString < $1.id.uuidString
                }
            let tasks = try ReminderStore.openOnDevice().todayTaskSnapshot(now: now, calendar: calendar)
            snapshot = WidgetSnapshot(now: now, calendar: calendar,
                tasks: tasks.map { .init(id: $0.id, title: String($0.text.prefix(100)), detail: String($0.whenLabel.prefix(100))) },
                items: facts.map { .init(id: $0.id, title: String($0.name.prefix(100)), detail: $0.dateStatusLabel) },
                nextChange: tasks.compactMap(\.autoCompleteAt).min())
        } catch {
            // Fail closed: inaccessible task or inventory storage is not an empty household.
            snapshot = WidgetSnapshot(now: now, calendar: calendar, tasks: [], items: [], available: false)
        }
        do { try snapshot.write(to: file) }
        catch {
            // Prefer an unavailable widget over a previously successful projection after a failed write.
            try? FileManager.default.removeItem(at: file)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.kind)
    }
}
