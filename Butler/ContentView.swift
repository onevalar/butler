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
    @State private var chatStart: ChatStart? = ProcessInfo.processInfo.arguments.contains("--butler-chat") ? .typing : nil
    #else
    @State private var capturing = false
    @State private var chatStart: ChatStart?
    #endif
    @State private var chat: ButlerChat?
    @State private var showingSettings = false
    @Environment(\.modelContext) private var modelContext

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
                onChat: { chatStart = $0 },
                onSettings: { showingSettings = true }
            )
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .inventory:
                    InventoryView(facts: facts, history: history, onOpenLot: { path.append(.lot($0)) }, onChat: { chatStart = $0 })
                case .lot(let id):
                    LotDetailView(lotID: id)
                }
            }
        }
        .tint(Theme.ink)
        .fullScreenCover(item: $chatStart) { start in
            if let chat {
                ButlerChatView(chat: chat, start: start, onQuickCapture: {
                    chatStart = nil
                    Task { try? await Task.sleep(for: .milliseconds(450)); capturing = true }
                })
            }
        }
        .sheet(isPresented: $showingSettings) {
            if let chat { ButlerSettingsView(chat: chat) }
        }
        .task {
            // One conversation for the whole app, so it survives closing and reopening the chat.
            if chat == nil { chat = ButlerChat(container: modelContext.container) }
        }
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
            chatStart = nil
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
