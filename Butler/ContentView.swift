import SwiftUI
import SwiftData

enum Route: Hashable {
    case lot(UUID)
    case task(UUID)
    case tasks
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
    @State private var sessions: ChatSessions?
    @State private var voiceScope: ChatScope?
    @State private var notificationError: String?
    /// Shared by home (to show reminders) and the chat (to set them).
    @State private var reminders = ReminderStore.openOnDevice()
    @State private var calendarFeed = CalendarFeed()
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)

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
                onOpenTasks: { path.append(.tasks) },
                brief: brief
            )
            .navigationDestination(for: Route.self) { destination($0, facts: facts) }
        }
        // Every page scrolls clear of the orb.
        .contentMargins(.bottom, 96, for: .scrollContent)
        .overlay {
            GeometryReader { geometry in
                OrbDockView(working: chat?.working ?? false, safeBottom: geometry.safeAreaInsets.bottom,
                            onOpenChat: { openChat(.typing) }, onSend: sendSpoken,
                            onBeginVoice: { voiceScope = currentScope })
            }
        }
        .environment(orbDock)
        .environment(calendarFeed)
        .sheet(isPresented: $showingChat) {
            if let chat {
                ButlerChatView(chat: chat, request: $chatRequest, onQuickCapture: {
                    showingChat = false
                    Task { try? await Task.sleep(for: .milliseconds(450)); capturing = true }
                }, onGeneralChat: { selectChat(.general) },
                onSettingsChat: { selectChat(.settings) }, hasOtherWork: sessions?.working ?? false,
                diaryTurns: sessions?.allTurns, onClose: { showingChat = false })
                .id(chat.scope.key)
                .environment(calendarFeed)
            }
        }
        .fullScreenCover(isPresented: Binding(get: { showsOnboarding }, set: { if !$0 { onboardingDone = true } })) {
            if let chat {
                OnboardingView(chat: chat, calendarFeed: calendarFeed) { onboardingDone = true }
                    .interactiveDismissDisabled()
            }
        }
        .task {
            // Shared services, independently persisted conversations.
            if sessions == nil {
                let store = ChatSessions(container: modelContext.container, reminders: reminders)
                sessions = store
                chat = store.chat(for: .general)
                NotificationManager.shared.reminderStore = reminders
                reminders.rescheduleAll()
            }
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
            reminders.rescheduleAll()
            // A new day since the app was last open: start from today again.
            let today = Calendar.current.startOfDay(for: .now)
            if selectedDay < today { selectedDay = today }
            Task { await calendarFeed.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .butlerSettingsChanged)) { _ in
            sessions?.reloadSettings()
            calendarFeed.enabled = UserDefaults.standard.bool(forKey: "showSystemCalendar")
            refreshID = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: .butlerBackupRestored)) { _ in
            sessions?.reloadFromDisk()
            reminders.reload()
            calendarFeed.enabled = UserDefaults.standard.bool(forKey: "showSystemCalendar")
            refreshID = UUID()
        }
        .onChange(of: NotificationManager.shared.reminderActionError, initial: true) { _, error in
            notificationError = error
        }
        .alert("提醒操作未完成", isPresented: Binding(get: { notificationError != nil }, set: { if !$0 { notificationError = nil } })) {
            Button("知道了", role: .cancel) { notificationError = nil }
        } message: { Text(notificationError ?? "") }
        .onChange(of: NotificationManager.shared.pendingReminderID, initial: true) { _, id in
            guard let id else { return }
            showingChat = false
            path = [.task(id)]
            NotificationManager.shared.clearPendingRoute()
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
                .toolbar { ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { RelatedConversationView(scope: .lot(id), sessions: sessions) { scope in selectChat(scope); showingChat = true } } label: { Image(systemName: "bubble.left.and.bubble.right") }
                        .accessibilityLabel("相关对话")
                } }
        case .task(let id):
            TaskDetailView(id: id, store: reminders, sessions: sessions, onChat: { selectChat(.task(id)); showingChat = true }, onOpenScope: { scope in selectChat(scope); showingChat = true })
        case .tasks:
            TaskListView(store: reminders, onOpen: { path.append(.task($0)) }, onCreate: {
                selectChat(.general)
                prefillDraft("帮我安排一个任务：")
                showingChat = true
            })
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
            if let sessions {
                ButlerSettingsView(chat: sessions.chat(for: .settings), hasOtherWork: sessions.working, diaryTurns: sessions.allTurns)
            }
        }
    }

    /// A year ahead, for the overview and for days opened from it.
    private var yearAgenda: HomeAgenda {
        HomeAgenda.build(lots: facts, reminders: reminders.upcoming, events: calendarFeed.events, dayCount: 366)
    }

    private func openChat(_ start: ChatStart) {
        selectChat(currentScope)
        chatRequest = ChatRequest(start: start)
        showingChat = true
    }

    /// Opens the conversation with a sentence already started, e.g. "买了".
    private func ask(_ text: String) {
        openChat(.typing)
        prefillDraft(text)
    }

    private func prefillDraft(_ text: String) {
        guard let chat else { return }
        let existing = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        chat.draft = existing.isEmpty ? text : existing + "\n" + text
    }

    /// Held the orb and spoke: send it straight away and show the conversation.
    private func sendSpoken(_ text: String) {
        selectChat(voiceScope ?? currentScope)
        voiceScope = nil
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
        case .reminder(let id): path.append(.task(id))
        case .calendarEvent:
            if let url = URL(string: "calshow:\(selectedDay.timeIntervalSinceReferenceDate)") { openURL(url) }
        }
    }

    private var currentScope: ChatScope {
        switch path.last {
        case .lot(let id): .lot(id)
        case .task(let id): .task(id)
        case .butler, .memories: .settings
        case .items: .inventory
        case .day(let date): .day(date.isoDay)
        default: .general
        }
    }

    private func selectChat(_ scope: ChatScope) {
        guard let sessions else { return }
        chat = sessions.chat(for: scope)
        chatRequest = nil
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
