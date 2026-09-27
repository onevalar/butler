import SwiftUI
import SwiftData

enum Route: Hashable {
    case lot(UUID)
    case day(Date)
    case overview
    case memories
}

enum AppTab: String, Hashable {
    case today, chat, home, butler
}

struct ContentView: View {
    @Query private var lots: [InventoryLot]
    @Query private var products: [CatalogProduct]
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab: AppTab = Self.launchTab
    @State private var todayPath: [Route] = []
    @State private var homePath: [Route] = []
    @State private var butlerPath: [Route] = []
    @State private var refreshID = UUID()
    #if DEBUG
    @State private var capturing = ProcessInfo.processInfo.environment["BUTLER_CAPTURE_TEXT"] != nil
    #else
    @State private var capturing = false
    #endif
    /// Set by other tabs to open the conversation ready to type or listen.
    @State private var chatRequest: ChatRequest?
    @AppStorage(AccentChoice.modeKey) private var appearanceMode: AppearanceMode = .system
    @AppStorage(AccentChoice.storageKey) private var accentChoice: AccentChoice = .glass
    @Environment(\.colorScheme) private var colorScheme
    @State private var chat: ButlerChat?
    @State private var showingSettings = false
    /// Shared by home (to show reminders) and the chat (to set them).
    @State private var reminders = ReminderStore.openOnDevice()
    @State private var calendarFeed = CalendarFeed()
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    @State private var chosenReminder: TimedReminder?
    @AppStorage("onboardingDone") private var onboardingDone = false
    /// Home's camera button opens the camera straight away; the photo then goes into the chat.
    @State private var takingPhoto = false
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
        let brief = DailyBrief.compose(agenda: agenda, lotCount: facts.count, reminderCount: reminders.upcoming.count,
                                       usesCalendar: calendarFeed.enabled && calendarFeed.canRead)
        TabView(selection: $tab) {
            Tab("今天", systemImage: "sun.horizon", value: AppTab.today) {
                NavigationStack(path: $todayPath) {
                    HomeView(
                        agenda: agenda,
                        selectedDay: $selectedDay,
                        onOpen: open,
                        onOpenDay: { todayPath.append(.day($0)) },
                        onOpenInventory: { tab = .home },
                        onOpenOverview: { todayPath.append(.overview) },
                        brief: brief,
                        onChat: startChat
                    )
                    .navigationDestination(for: Route.self, destination: destination)
                }
            }
            Tab("对话", systemImage: "bubble.left.and.text.bubble.right", value: AppTab.chat) {
                if let chat {
                    ButlerChatView(chat: chat, request: $chatRequest, onQuickCapture: { capturing = true },
                                   onSettings: { showingSettings = true })
                } else {
                    ProgressView()
                }
            }
            Tab("家里", systemImage: "house", value: AppTab.home) {
                NavigationStack(path: $homePath) {
                    InventoryView(facts: facts, history: history, onOpenLot: { homePath.append(.lot($0)) },
                                  onChat: startChat, onAsk: ask)
                        .navigationDestination(for: Route.self, destination: destination)
                }
            }
            Tab(value: AppTab.butler) {
                NavigationStack(path: $butlerPath) {
                    if let chat {
                        ButlerProfileView(chat: chat, onSettings: { showingSettings = true },
                                          onMemories: { butlerPath.append(.memories) }, onChat: startChat)
                            .navigationDestination(for: Route.self, destination: destination)
                    }
                }
            } label: {
                Label {
                    Text("管家")
                } icon: {
                    Image(uiImage: OrbTabIcon.image(dark: colorScheme == .dark))
                }
            }
        }
        .environment(calendarFeed)
        .fullScreenCover(isPresented: $takingPhoto) {
            PhotoCapture(onPhoto: { image in
                if let data = image.chatJPEG() { chat?.photos.append(data) }
                takingPhoto = false
                // The photo waits in the conversation, ready to send.
                tab = .chat
                chatRequest = ChatRequest(start: .typing)
            }, onCancel: { takingPhoto = false })
            .ignoresSafeArea()
        }
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
        .sheet(isPresented: $showingSettings) {
            if let chat { ButlerSettingsView(chat: chat) }
        }
        .task {
            // One conversation for the whole app, so it survives closing and reopening the chat.
            if chat == nil { chat = ButlerChat(container: modelContext.container, reminders: reminders) }
            if UserDefaults.standard.double(forKey: "butlerSince") == 0 {
                let since = min(Date.now, chat?.turns.first?.date ?? .now)
                UserDefaults.standard.set(since.timeIntervalSince1970, forKey: "butlerSince")
            }
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
            tab = .home
            homePath = [.lot(id)]
            NotificationManager.shared.clearPendingRoute()
        }
        .onContinueUserActivity("com.apple.corespotlightitem") { activity in
            if let id = (activity.userInfo?["kCSSearchableItemActivityIdentifier"] as? String).flatMap(UUID.init) {
                tab = .home
                homePath = [.lot(id)]
            }
        }
        .butlerAppearance(mode: appearanceMode, accent: accentChoice)
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .lot(let id):
            LotDetailView(lotID: id)
        case .day(let day):
            DayScheduleView(agenda: yearAgenda, day: day, onOpen: open)
        case .overview:
            CalendarOverviewView(agenda: yearAgenda, onOpenDay: { todayPath.append(.day($0)) }, onOpen: open)
                .task {
                    calendarFeed.horizonDays = 370
                    await calendarFeed.refresh()
                }
        case .memories:
            if let chat { MemoriesView(chat: chat) }
        }
    }

    /// A year ahead, for the overview and for days opened from it.
    private var yearAgenda: HomeAgenda {
        HomeAgenda.build(lots: facts, reminders: reminders.upcoming, events: calendarFeed.events, dayCount: 366)
    }

    private func startChat(_ start: ChatStart) {
        if start == .camera {
            takingPhoto = true
        } else {
            tab = .chat
            chatRequest = ChatRequest(start: start)
        }
    }

    /// Opens the conversation with a sentence already started, e.g. "买了".
    private func ask(_ text: String) {
        chat?.draft = text
        startChat(.typing)
    }

    private func open(_ target: AgendaEntry.Target) {
        switch target {
        case .lot(let id): todayPath.append(.lot(id))
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

    /// Debug launches can open a specific tab (`--tab=home`); `--butler-chat` opens the conversation.
    private static var launchTab: AppTab {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--butler-chat") { return .chat }
        if let value = arguments.first(where: { $0.hasPrefix("--tab=") })?.dropFirst(6), let tab = AppTab(rawValue: String(value)) {
            return tab
        }
        #endif
        return .today
    }

    private static var isTesting: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }
}

/// The 管家 tab shows the glass orb itself, in colour, instead of a template symbol.
enum OrbTabIcon {
    private static var cache: [Bool: UIImage] = [:]

    static func image(dark: Bool) -> UIImage {
        if let image = cache[dark] { return image }
        let renderer = ImageRenderer(content: ButlerOrb(size: 28).environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 3
        let image = (renderer.uiImage ?? UIImage()).withRenderingMode(.alwaysOriginal)
        cache[dark] = image
        return image
    }
}
