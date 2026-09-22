import SwiftUI
import SwiftData

enum Route: Hashable {
    case inventory
    case lot(UUID)
}

struct ContentView: View {
    @Query(filter: #Predicate<InventoryLot> { $0.stateRawValue == "active" }) private var lots: [InventoryLot]
    @Query private var products: [CatalogProduct]

    @State private var path: [Route] = []
    #if DEBUG
    @State private var capturing = ProcessInfo.processInfo.environment["BUTLER_CAPTURE_TEXT"] != nil
    #else
    @State private var capturing = false
    #endif

    private var facts: [LotFacts] {
        let byID = Dictionary(products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return lots.map { LotFacts(lot: $0, product: byID[$0.productID]) }
    }

    /// Changes whenever anything a reminder depends on changes.
    private var syncSignature: [String] {
        lots.map { "\($0.id)|\($0.revision)" }.sorted()
    }

    var body: some View {
        let facts = facts
        NavigationStack(path: $path) {
            HomeView(
                facts: facts,
                onOpenLot: { path.append(.lot($0)) },
                onOpenShelf: { path.append(.inventory) },
                onSpeak: { capturing = true }
            )
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .inventory:
                    InventoryView(facts: facts, onOpenLot: { path.append(.lot($0)) }, onSpeak: { capturing = true })
                case .lot(let id):
                    LotDetailView(lotID: id)
                }
            }
        }
        .tint(Theme.ink)
        .fullScreenCover(isPresented: $capturing) {
            CaptureView()
        }
        .task(id: syncSignature) {
            await NotificationManager.shared.resync(facts)
            await SpotlightManager.shared.resync(facts)
        }
        .onContinueUserActivity("com.apple.corespotlightitem") { activity in
            if let id = (activity.userInfo?["kCSSearchableItemActivityIdentifier"] as? String).flatMap(UUID.init) {
                path = [.lot(id)]
            }
        }
    }
}
