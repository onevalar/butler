#if DEBUG
import SwiftUI
import SwiftData

struct M2InputHarnessView: View {
    @Query(sort: \CatalogProduct.createdAt) private var products: [CatalogProduct]
    @Query(sort: \InventoryLot.createdAt) private var lots: [InventoryLot]
    @State private var coordinator: InventoryInputCoordinator

    init(modelContainer: ModelContainer) {
        _coordinator = State(initialValue: InventoryInputCoordinator(
            provider: LocalInventoryPlanProvider(), lookup: CatalogProductLookup(modelContainer: modelContainer),
            repository: InventoryRepository(modelContainer: modelContainer)))
    }

    var body: some View {
        NavigationStack {
            List {
                V2InventoryInputView(coordinator: coordinator)
                if coordinator.state == .completed {
                    Section("V2 Products / Lots") {
                        ForEach(products) { product in Text("Product · \(product.canonicalName) · \(product.id.uuidString.prefix(8))") }
                        ForEach(lots) { lot in Text("Lot · \(lot.quantity) \(lot.unit) · \(lot.productID.uuidString.prefix(8))") }
                    }
                }
            }.navigationTitle("M2 Input Harness")
        }
    }
}
#endif
