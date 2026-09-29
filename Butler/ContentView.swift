import Combine
import SwiftUI
import SwiftData

enum Route: Hashable {
    case lot(UUID)
    case task(UUID)
    case tasks
    case day(Date)
    case overview
    /// 这周还有…: the schedule overview opened on its list.
    case upcoming
    case memories
    /// 物品: everything at home, as tiles.
    case items
    /// One tile opened from 物品.
    case itemGroup(InventoryGroup.Key)
    /// 物品 › 已处理的东西.
    case itemHistory
    /// 管家与设置.
    case butler
}

/// The year-long agenda is worth keeping until what it is built from changes.
final class AgendaCache {
    var key: AgendaKey?
    var agenda: HomeAgenda?
}

struct AgendaKey: Hashable {
    let lots: [String]
    let products: [String]
    let tasks: [String]
    let events: Int
    let minute: Int
    let browsingMonths: [Date]
}

struct ContentView: View {
    @Query private var lots: [InventoryLot]
    @Query private var products: [CatalogProduct]
    @Environment(\.scenePhase) private var scenePhase

    @State private var path: [Route] = Self.launchPath
    @State private var refreshID = UUID()
    @State private var agendaNow = Date.now
    #if DEBUG
    @State private var capturing = ProcessInfo.processInfo.environment["BUTLER_CAPTURE_TEXT"] != nil
    #else
    @State private var capturing = false
    #endif
    /// Opens the conversation ready to type (tap on the orb) or with something already said.
    @State private var chatRequest: ChatRequest?
    @State private var showingChat = Self.launchesChat
    /// One conversation panel everywhere: half height after speaking (the page stays in view), full height to type.
    @State private var chatDetent: PresentationDetent = .large
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
    @State private var listDay = Calendar.current.startOfDay(for: .now)
    @State private var browsingMonth = Calendar.current.startOfDay(for: .now)
    @State private var snoozingTarget: BriefTarget?
    @State private var agendaCache = AgendaCache()
    @State private var briefService = BriefService()
    @State private var snoozeRevision = 0
    /// A brief button that changes medicine stock asks once more.
    @State private var confirmingBrief: (action: BriefAction, target: BriefTarget)?
    @State private var briefError: String?

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

    /// What the butler might raise right now, most pressing first (things already snoozed are left out).
    private func briefCandidates(facts: [LotFacts], agenda: HomeAgenda) -> [BriefCandidate] {
        BriefCandidates.make(facts: facts, agenda: agenda, now: agendaNow, snoozed: BriefSnoozes.active(now: agendaNow))
    }

    var body: some View {
        let facts = facts
        // A year ahead: home swipes between days, the date panel shows dots, and the overview needs the same.
        let agenda = yearAgenda(facts: facts)
        let candidates = briefCandidates(facts: facts, agenda: agenda)
        let briefKey = BriefCandidates.signature(candidates, now: agendaNow) + "|\(facts.count)|\(reminders.active.count)|\(calendarFeed.enabled)"
        NavigationStack(path: $path) {
            HomeView(
                agenda: agenda,
                facts: facts,
                listDay: $listDay,
                isActive: path.isEmpty && scenePhase == .active,
                now: agendaNow,
                brief: briefService.brief,
                briefBusy: briefService.isThinking,
                pendingTaskCount: agenda.pending(on: agenda.today, at: agendaNow).count,
                onOpen: open,
                onOpenInventory: { path.append(.items) },
                onOpenOverview: { path.append(.overview) },
                onOpenUpcoming: { path.append(.upcoming) },
                onOpenButler: { path.append(.butler) },
                onOpenTasks: { path.append(.tasks) },
                onBriefAction: { action, target in briefTapped(action, target, facts: facts) },
                onBriefOther: { visibleBrief in
                    briefService.beginInteraction()
                    openChat(scope: .brief(BriefConversation(brief: visibleBrief, day: agendaNow.isoDay)), .typing)
                },
                onBriefInteraction: { briefService.beginInteraction() },
                onBrowseMonth: { browsingMonth = $0 }
            )
            .navigationDestination(for: Route.self) { destination($0, facts: facts) }
        }
        .onChange(of: briefKey + "|\(snoozeRevision)|\(WeatherStore.shared.snapshot?.fetchedAt.timeIntervalSince1970 ?? 0)", initial: true) {
            briefService.update(candidates: candidates, lotCount: facts.count, taskCount: reminders.active.count,
                                usesCalendar: calendarFeed.enabled && calendarFeed.canRead, now: agendaNow, weather: WeatherStore.shared.snapshot)
        }
        .sheet(isPresented: Binding(get: { snoozingTarget != nil }, set: { if !$0 { snoozingTarget = nil } })) {
            if let target = snoozingTarget {
                BriefSnoozeSheet(onChoose: { date in
                    guard date > Date.now else { return }
                    BriefSnoozes.snooze(target, until: date)
                    snoozingTarget = nil
                    agendaNow = .now
                    snoozeRevision += 1
                })
            }
        }
        .onChange(of: listDay) {
            browsingMonth = listDay
        }
        .onChange(of: browsingMonth, initial: true) {
            calendarFeed.focusedDate = browsingMonth
            Task { await calendarFeed.refresh() }
        }
        .alert("\(confirmingBrief?.action.label ?? "")？", isPresented: Binding(get: { confirmingBrief != nil }, set: { if !$0 { confirmingBrief = nil } })) {
            Button("确认") {
                if let pending = confirmingBrief { runBrief(pending.action, pending.target, facts: facts) }
                confirmingBrief = nil
            }
            Button("取消", role: .cancel) { confirmingBrief = nil }
        } message: {
            Text("这是药品，确认后才会更新库存。")
        }
        .alert("没能完成", isPresented: Binding(get: { briefError != nil }, set: { if !$0 { briefError = nil } })) {
            Button("知道了", role: .cancel) { briefError = nil }
        } message: { Text(briefError ?? "") }
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
                onSettingsChat: { selectChat(.settings) }, onOpenLot: { id in
                    showingChat = false; path.append(.lot(id))
                }, hasOtherWork: sessions?.working ?? false,
                diaryTurns: sessions?.allTurns, onNeedsRoom: { chatDetent = .large }, onClose: { showingChat = false })
                .id(chat.scope.key)
                .environment(calendarFeed)
                .presentationDetents([.medium, .large], selection: $chatDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
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
                briefService.attach(store.connection)
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
            calendarFeed.horizonDays = 370
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
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now in
            guard scenePhase == .active else { return }
            let previousDay = Calendar.current.startOfDay(for: agendaNow)
            agendaNow = now
            if !Calendar.current.isDate(previousDay, inSameDayAs: now) {
                if listDay == previousDay { listDay = Calendar.current.startOfDay(for: now) }
                reminders.rescheduleAll()
                Task { await calendarFeed.refresh() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshID = UUID()
            let wasToday = Calendar.current.isDate(listDay, inSameDayAs: agendaNow)
            agendaNow = .now
            if wasToday { listDay = Calendar.current.startOfDay(for: agendaNow) }
            reminders.rescheduleAll()
            Task { await WeatherStore.shared.refresh() }
            // Preserve a deliberately selected history date when returning to the app.
            Task { await calendarFeed.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .butlerSettingsChanged)) { _ in
            sessions?.reloadSettings()
            calendarFeed.enabled = UserDefaults.standard.bool(forKey: "showSystemCalendar")
            refreshID = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: .butlerBackupRestored)) { _ in
            sessions?.reloadFromDisk()
            let weatherLocation = UserDefaults.standard.data(forKey: "weatherLocation").flatMap { try? JSONDecoder().decode(WeatherLocation.self, from: $0) } ?? WeatherLocation()
            try? WeatherStore.shared.setLocation(weatherLocation)
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
                    NavigationLink { RelatedConversationView(scope: .lot(id), sessions: sessions) { scope in selectChat(scope); presentChat() } } label: { Image(systemName: "bubble.left.and.bubble.right") }
                        .accessibilityLabel("相关对话")
                } }
        case .task(let id):
            TaskDetailView(id: id, store: reminders, sessions: sessions, onChat: { selectChat(.task(id)); presentChat() }, onOpenScope: { scope in selectChat(scope); presentChat() })
        case .tasks:
            TaskListView(store: reminders, onOpen: { path.append(.task($0)) }, onCreate: {
                selectChat(.general)
                prefillDraft("帮我安排一个任务：")
                presentChat()
            })
        case .day(let day):
            DayScheduleView(agenda: yearAgenda(facts: facts), day: day, onOpen: open)
        case .overview:
            CalendarOverviewView(agenda: yearAgenda(facts: facts), onOpenDay: { path.append(.day($0)) }, onOpen: open)
                .task {
                    calendarFeed.horizonDays = 370
                    await calendarFeed.refresh()
                }
        case .upcoming:
            CalendarOverviewView(agenda: yearAgenda(facts: facts), initialMode: .list, onOpenDay: { path.append(.day($0)) }, onOpen: open)
                .task {
                    calendarFeed.horizonDays = 370
                    await calendarFeed.refresh()
                }
        case .memories:
            if let chat { MemoriesView(chat: chat) }
        case .items:
            InventoryView(facts: facts, historyCount: lots.count - facts.count,
                          onOpenGroup: { path.append(.itemGroup($0)) }, onOpenHistory: { path.append(.itemHistory) })
        case .itemGroup(let key):
            InventoryGroupView(key: key, facts: facts, onOpenLot: { path.append(.lot($0)) })
        case .itemHistory:
            InventoryHistoryView(history: history, onOpenLot: { path.append(.lot($0)) })
        case .butler:
            if let sessions {
                ButlerSettingsView(chat: sessions.chat(for: .settings), hasOtherWork: sessions.working, diaryTurns: sessions.allTurns)
            }
        }
    }

    /// A year ahead, for home, the overview and the days opened from it. Rebuilt only when its inputs change.
    private func yearAgenda(facts: [LotFacts]) -> HomeAgenda {
        let calendar = Calendar.current
        let months = Array(Set([listDay, browsingMonth].map { calendar.dateInterval(of: .month, for: $0)?.start ?? $0 })).sorted()
        let key = AgendaKey(
            lots: lots.map { "\($0.id)|\($0.revision)|\($0.stateRawValue)|\($0.storageLocation ?? "")" },
            products: products.map { "\($0.id)|\($0.revision)" },
            tasks: reminders.reminders.map { "\($0.id)|\($0.revision)|\($0.status)|\($0.activity.count)" },
            events: calendarFeed.events.hashValue,
            minute: Int(agendaNow.timeIntervalSince1970 / 60), browsingMonths: months)
        if agendaCache.key == key, let cached = agendaCache.agenda { return cached }
        let built = HomeAgenda.build(lots: facts, reminders: reminders.reminders, events: calendarFeed.events, now: agendaNow, dayCount: 366, additionalDays: months.flatMap { HomeAgenda.browsingDays(around: $0) })
        agendaCache.key = key
        agendaCache.agenda = built
        return built
    }

    private func openChat(_ start: ChatStart) {
        openChat(scope: currentScope, start)
    }

    /// Opens the conversation that belongs to one thing (an item, a task), so what is said stays about that thing.
    private func openChat(scope: ChatScope, _ start: ChatStart) {
        selectChat(scope)
        chatRequest = ChatRequest(start: start)
        presentChat()
    }

    /// Typing, a photo or reading back: the panel opens full height (the keyboard needs the room).
    private func presentChat(_ detent: PresentationDetent = .large) {
        chatDetent = detent
        showingChat = true
    }

    private func briefTapped(_ action: BriefAction, _ target: BriefTarget, facts: [LotFacts]) {
        briefService.beginInteraction()
        if case .snooze = action.effect {
            snoozingTarget = target
            return
        }
        if action.effect.changesData, case .lot(let id) = target, facts.first(where: { $0.id == id })?.isMedicine == true {
            confirmingBrief = (action, target)
        } else {
            runBrief(action, target, facts: facts)
        }
    }

    private func runBrief(_ action: BriefAction, _ target: BriefTarget, facts: [LotFacts]) {
        let runner = BriefActionRunner(container: modelContext.container, reminders: reminders)
        Task {
            switch await runner.run(action, target: target, facts: facts, now: agendaNow) {
            case .done: snoozeRevision += 1
            case .open:
                switch target {
                case .lot(let id): path.append(.lot(id))
                case .task(let id): path.append(.task(id))
                }
            case .failed(let message): briefError = message
            }
        }
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
        // Spoken while looking at a page: half height, so the page (and any change to it) stays in view.
        presentChat(.medium)
    }

    private func open(_ target: AgendaEntry.Target) {
        switch target {
        case .lot(let id): path.append(.lot(id))
        case .reminder(let id): path.append(.task(id))
        case .calendarEvent:
            if let url = URL(string: "calshow:\(listDay.timeIntervalSinceReferenceDate)") { openURL(url) }
        }
    }

    private var currentScope: ChatScope {
        switch path.last {
        case .lot(let id): .lot(id)
        case .task(let id): .task(id)
        case .butler, .memories: .settings
        case .items, .itemGroup, .itemHistory: .inventory
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

/// Explicitly snoozes the home suggestion; it does not alter task notifications or expiry dates.
private struct BriefSnoozeSheet: View {
    let onChoose: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var customDate = Date.now.addingTimeInterval(3600)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("1 小时后") { onChoose(Date.now.addingTimeInterval(3600)) }
                    Button("明天上午 9 点") { choose(days: 1) }
                    Button("3 天后上午 9 点") { choose(days: 3) }
                } header: { Text("什么时候再提这件事？") }
                footer: { Text("仅暂停首页建议，清单仍保留。任务通知照常，物品日期不变。") }
                Section("自己选时间") {
                    DatePicker("再次提示", selection: $customDate, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                    Button("按这个时间") { onChoose(customDate) }.disabled(customDate <= Date.now)
                }
            }
            .navigationTitle("先放放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func choose(days: Int) {
        let calendar = Calendar.current
        guard let day = calendar.date(byAdding: .day, value: days, to: Date.now),
              let date = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) else { return }
        onChoose(date)
    }
}
