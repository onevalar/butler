import SwiftUI
import SwiftData

enum Route: Hashable {
    case inventory
    case lot(UUID)
    case day(Date)
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
    /// Shared by home (to show reminders) and the chat (to set them).
    @State private var reminders = ReminderStore.openOnDevice()
    @State private var calendarFeed = CalendarFeed()
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    @State private var chosenReminder: TimedReminder?
    @AppStorage("onboardingDone") private var onboardingDone = false
    @Environment(\.openURL) private var openURL
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
        let agenda = HomeAgenda.build(lots: facts, reminders: reminders.upcoming, events: calendarFeed.events)
        NavigationStack(path: $path) {
            HomeView(
                agenda: agenda,
                selectedDay: $selectedDay,
                onOpen: open,
                onOpenDay: { path.append(.day($0)) },
                onOpenInventory: { path.append(.inventory) },
                onSettings: { showingSettings = true },
                onChat: { chatStart = $0 }
            )
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .inventory:
                    InventoryView(facts: facts, history: history, onOpenLot: { path.append(.lot($0)) }, onChat: { chatStart = $0 })
                case .lot(let id):
                    LotDetailView(lotID: id)
                case .day(let day):
                    DayScheduleView(agenda: agenda, day: day, onOpen: open)
                }
            }
        }
        .environment(calendarFeed)
        .fullScreenCover(isPresented: Binding(get: { showsOnboarding }, set: { if !$0 { onboardingDone = true } })) {
            if let chat {
                OnboardingView(chat: chat, calendarFeed: calendarFeed) { onboardingDone = true }
                    .interactiveDismissDisabled()
            }
        }
        .confirmationDialog(chosenReminder?.text ?? "", isPresented: Binding(
            get: { chosenReminder != nil }, set: { if !$0 { chosenReminder = nil } }
        ), titleVisibility: .visible) {
            if let reminder = chosenReminder {
                Button("删除这个提醒", role: .destructive) { try? reminders.remove(reminder.id) }
            }
        } message: {
            Text(chosenReminder?.whenLabel ?? "")
        }
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
            if chat == nil { chat = ButlerChat(container: modelContext.container, reminders: reminders) }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--seed-sample-reminders"), reminders.upcoming.isEmpty {
                let calendar = Calendar.current
                let later = calendar.date(byAdding: .hour, value: 2, to: .now) ?? .now
                let evening = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: .now) ?? .now
                let friday = calendar.date(byAdding: .day, value: 3, to: calendar.date(bySettingHour: 15, minute: 30, second: 0, of: .now) ?? .now) ?? .now
                try? reminders.add(TimedReminder(text: "热剩饭", fireDate: later))
                try? reminders.add(TimedReminder(text: "吃药", fireDate: evening, repeats: .daily))
                try? reminders.add(TimedReminder(text: "取快递", fireDate: friday))
            }
            #endif
            await calendarFeed.refresh()
            // Items with dates already exist but reminders were never allowed: ask once (the guide asks new users).
            if !Self.isTesting, onboardingDone, facts.contains(where: { $0.governingDate != nil }) {
                await NotificationManager.shared.requestAuthorizationIfUndecided()
            }
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
            guard phase == .active else { return }
            refreshID = UUID()
            // A new day since the app was last open: start from today again.
            let today = Calendar.current.startOfDay(for: .now)
            if selectedDay < today { selectedDay = today }
            Task { await calendarFeed.refresh() }
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

    private func open(_ target: AgendaEntry.Target) {
        switch target {
        case .lot(let id): path.append(.lot(id))
        case .reminder(let id): chosenReminder = reminders.upcoming.first { $0.id == id }
        case .calendarEvent:
            if let url = URL(string: "calshow:\(selectedDay.timeIntervalSinceReferenceDate)") { openURL(url) }
        }
    }

    private var showsOnboarding: Bool {
        guard !onboardingDone, chat != nil, !Self.isTesting else { return false }
        #if DEBUG
        // Screenshot and seed runs go straight to the screen they test.
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--seed-") || $0 == "--butler-chat" }) { return false }
        #endif
        return true
    }

    private static var isTesting: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }
}
