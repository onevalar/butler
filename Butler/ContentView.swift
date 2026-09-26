import SwiftUI
import SwiftData

enum Route: Hashable {
    case inventory
    case lot(UUID)
}

struct ContentView: View {
    @Query private var lots: [InventoryLot]
    @Query private var products: [CatalogProduct]
    @Environment(\.scenePhase) private var scenePhase

    @State private var path: [Route] = []
    @State private var refreshID = UUID()
    #if DEBUG
    @State private var capturing = ProcessInfo.processInfo.environment["BUTLER_CAPTURE_TEXT"] != nil
    @State private var agentTesting = ProcessInfo.processInfo.arguments.contains("--agent-test")
    #else
    @State private var capturing = false
    #endif

    private var facts: [LotFacts] {
        let byID = Dictionary(products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return lots.filter { $0.state == .active }.map { LotFacts(lot: $0, product: byID[$0.productID]) }
    }

    private var history: [LotFacts] {
        lots.filter { $0.state != .active }.sorted { $0.updatedAt > $1.updatedAt }.map { lot in
            LotFacts(lot: lot, product: products.first { $0.id == lot.productID })
        }
    }

    /// Changes whenever anything a reminder depends on changes.
    private var syncSignature: [String] {
        lots.map { "\($0.id)|\($0.revision)" }.sorted() + [refreshID.uuidString]
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
                    InventoryView(facts: facts, history: history, onOpenLot: { path.append(.lot($0)) }, onSpeak: { capturing = true })
                case .lot(let id):
                    LotDetailView(lotID: id)
                }
            }
        }
        .tint(Theme.ink)
        #if DEBUG
        .safeAreaInset(edge: .top) {
            Button { agentTesting = true } label: {
                Label("与管家聊聊 · 本机记忆试用", systemImage: "bubble.left.and.bubble.right")
                    .font(.footnote).frame(maxWidth: .infinity).padding(12)
            }.background(Theme.surface).accessibilityIdentifier("agent.open")
        }
        .fullScreenCover(isPresented: $agentTesting) { AgentTestView() }
        #endif
        .fullScreenCover(isPresented: $capturing) {
            CaptureView()
        }
        .task(id: syncSignature) {
            await NotificationManager.shared.resync(facts)
            await SpotlightManager.shared.resync(facts)
        }
        .onReceive(NotificationCenter.default.publisher(for: .butlerNotificationAuthorizationChanged)) { _ in
            refreshID = UUID()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshID = UUID() }
        }
        .onChange(of: NotificationManager.shared.pendingLotID, initial: true) { _, id in
            guard let id else { return }
            capturing = false
            path = [.lot(id)]
            NotificationManager.shared.clearPendingRoute()
        }
        .onContinueUserActivity("com.apple.corespotlightitem") { activity in
            if let id = (activity.userInfo?["kCSSearchableItemActivityIdentifier"] as? String).flatMap(UUID.init) {
                path = [.lot(id)]
            }
        }
    }
}
