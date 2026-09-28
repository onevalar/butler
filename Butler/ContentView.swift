import SwiftUI
import SwiftData

enum Route: Hashable {
    case lot(UUID)
    case day(Date)
    case overview
    case memories
    /// 家里: everything at home.
    case items
    /// 管家与设置.
    case butler
}

struct ContentView: View {
    @Query private var lots: [InventoryLot]
    @Query private var products: [CatalogProduct]
    @Environment(\.scenePhase) private var scenePhase

    @State private var path: [Route] = Self.launchPath
    @State private var refreshID = UUID()
    #if DEBUG
    @State private var capturing = ProcessInfo.processInfo.environment["BUTLER_CAPTURE_TEXT"] != nil
    #else
    @State private var capturing = false
    #endif
    /// Opens the conversation ready to type (tap on the orb) or with something already said.
    @State private var chatRequest: ChatRequest?
    @State private var showingChat = Self.launchesChat
    @State private var orbDock = OrbDock()
    @AppStorage(AccentChoice.modeKey) private var appearanceMode: AppearanceMode = .system
    @AppStorage(AccentChoice.storageKey) private var accentChoice: AccentChoice = .glass
    @State private var chat: ButlerChat?
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
        let brief = DailyBrief.compose(agenda: agenda, lotCount: facts.count, reminderCount: reminders.upcoming.count,
                                       usesCalendar: calendarFeed.enabled && calendarFeed.canRead)
        NavigationStack(path: $path) {
            HomeView(
                agenda: agenda,
                selectedDay: $selectedDay,
                onOpen: open,
                onOpenDay: { path.append(.day($0)) },
                onOpenInventory: { path.append(.items) },
                onOpenOverview: { path.append(.overview) },
                onOpenButler: { path.append(.butler) },
                brief: brief
            )
            .navigationDestination(for: Route.self) { destination($0, facts: facts) }
        }
        // Every page scrolls clear of the orb.
        .contentMargins(.bottom, 96, for: .scrollContent)
        .overlay {
            GeometryReader { geometry in
                OrbDockView(working: chat?.working ?? false, safeBottom: geometry.safeAreaInsets.bottom,
                            onOpenChat: { chatRequest = nil; showingChat = true }, onSend: sendSpoken)
            }
        }
        .environment(orbDock)
        .environment(calendarFeed)
        .sheet(isPresented: $showingChat) {
            if let chat {
                ButlerChatView(chat: chat, request: $chatRequest, onQuickCapture: {
                    showingChat = false
                    Task { try? await Task.sleep(for: .milliseconds(450)); capturing = true }
                }, onClose: { showingChat = false })
                .environment(calendarFeed)
            }
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
            showingChat = false
            path = [.lot(id)]
            NotificationManager.shared.clearPendingRoute()
        }
        .onContinueUserActivity("com.apple.corespotlightitem") { activity in
            if let id = (activity.userInfo?["kCSSearchableItemActivityIdentifier"] as? String).flatMap(UUID.init) {
                showingChat = false
                path = [.lot(id)]
            }
        }
        .butlerAppearance(mode: appearanceMode, accent: accentChoice)
    }

    @ViewBuilder
    private func destination(_ route: Route, facts: [LotFacts]) -> some View {
        switch route {
        case .lot(let id):
            LotDetailView(lotID: id)
        case .day(let day):
            DayScheduleView(agenda: yearAgenda, day: day, onOpen: open)
        case .overview:
            CalendarOverviewView(agenda: yearAgenda, onOpenDay: { path.append(.day($0)) }, onOpen: open)
                .task {
                    calendarFeed.horizonDays = 370
                    await calendarFeed.refresh()
                }
        case .memories:
            if let chat { MemoriesView(chat: chat) }
        case .items:
            InventoryView(facts: facts, history: history, onOpenLot: { path.append(.lot($0)) },
                          onChat: openChat, onAsk: ask)
        case .butler:
            if let chat {
                ButlerSettingsView(chat: chat)
            }
        }
    }

    /// A year ahead, for the overview and for days opened from it.
    private var yearAgenda: HomeAgenda {
        HomeAgenda.build(lots: facts, reminders: reminders.upcoming, events: calendarFeed.events, dayCount: 366)
    }

    private func openChat(_ start: ChatStart) {
        chatRequest = ChatRequest(start: start)
        showingChat = true
    }

    /// Opens the conversation with a sentence already started, e.g. "买了".
    private func ask(_ text: String) {
        chat?.draft = text
        openChat(.typing)
    }

    /// Held the orb and spoke: send it straight away and show the conversation.
    private func sendSpoken(_ text: String) {
        guard let chat else { return }
        let existing = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        chat.draft = existing.isEmpty ? text : existing + " " + text
        if chat.canSend { chat.send() }
        chatRequest = nil
        showingChat = true
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

    /// Debug launches can open a page (`--open=items`, `--open=butler`) or the conversation (`--butler-chat`).
    private static var launchPath: [Route] {
        #if DEBUG
        switch ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--open=") })?.dropFirst(7) {
        case "items": return [.items]
        case "butler": return [.butler]
        case "overview": return [.overview]
        default: break
        }
        #endif
        return []
    }

    private static var launchesChat: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--butler-chat")
        #else
        return false
        #endif
    }

    private static var isTesting: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }
}
