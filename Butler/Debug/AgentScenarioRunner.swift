#if DEBUG
import Foundation
import SwiftData

/// The mobile loop and real local tools, with disposable stores and an explicit model dependency.
/// Nothing here opens a subscription, reads credentials, or contacts the network by itself.
/// A caller choosing .liveModel must provide the model and explicitly authorize its usage.
@MainActor
final class AgentScenarioRunner {
    enum Mode: String { case scripted, liveModel }
    struct ModelContext {
        let instructions: String
        let toolsJSON: String
    }
    enum Failure: Error { case liveModelNotAuthorized, roundsExceeded, unsafeProposal, timeout }
    typealias ModelFactory = (ModelContext) throws -> any LocalAgentModel

    static let allowedTools: Set<String> = [
        "get_product_guide", "get_current_context", "search_inventory", "propose_set_quantity", "propose_reminder",
        "get_tasks", "propose_task_time", "propose_task_update", "get_pending_changes",
        "revise_pending_change", "discard_pending_changes", "get_travel_capabilities",
        "propose_travel_access", "get_saved_places"
    ]

    let directory: URL
    let tools: ButlerTools
    let now: Date
    private let seedTask: TimedReminder
    private let seedLots: [JevEvaluationLot]
    private let device: AgentScenarioTravelDevice

    init(root: URL = .temporaryDirectory, now: Date = .now) throws {
        self.now = now
        directory = root.appendingPathComponent("agent-scenario-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let container = try ButlerStore.makePreviewContainer()
            let context = SwiftData.ModelContext(container)
            context.insert(CatalogProduct(id: AgentScenario.product, canonicalName: "牛奶"))
            context.insert(InventoryLot(id: AgentScenario.cold, productID: AgentScenario.product,
                quantity: 3, unit: "瓶", packageExpiryDate: now.addingTimeInterval(86400 * 20), storageLocation: "冷藏"))
            context.insert(InventoryLot(id: AgentScenario.frozen, productID: AgentScenario.product,
                quantity: 6, unit: "瓶", packageExpiryDate: now.addingTimeInterval(86400 * 40), storageLocation: "冷冻"))
            try context.save()
            let household = HouseholdStore(directory: directory.appendingPathComponent("household"))
            household.begin(.init(id: UUID(), name: "合成评估家庭", role: .owner, zoneName: "fictional",
                zoneOwner: "fictional", me: AgentScenario.me, joinedAt: now),
                me: .init(id: AgentScenario.me, name: "小安", isOwner: true, joinedAt: now))
            household.upsert(.init(id: AgentScenario.baby, name: "宝宝", isOwner: false, joinedAt: now))
            household.upsert(.init(id: AgentScenario.lin, name: "小林", isOwner: false, joinedAt: now))
            let reminders = ReminderStore(file: directory.appendingPathComponent("reminders.json"), schedules: false, publishesChanges: false)
            reminders.actor = { AgentScenario.me }
            var seed = TimedReminder(id: AgentScenario.sharedTask, text: "买水",
                fireDate: Self.day(1, from: now), createdAt: now)
            seed.timePeriod = .morning
            var sharing = TaskSharing(scope: .household, createdBy: AgentScenario.me, assignee: AgentScenario.baby)
            sharing.notify = [AgentScenario.baby]
            seed.sharing = sharing
            try reminders.add(seed)
            seedTask = reminders.reminders[0]
            tools = ButlerTools(container: container,
                notes: try LocalMemoryStore(file: directory.appendingPathComponent("notes.json")),
                reminders: reminders, jev: AgentScenarioNoJudge(), household: household, publishesChanges: false)
            device = AgentScenarioTravelDevice()
            tools.travel = TravelStore(file: directory.appendingPathComponent("places.json"), device: device)
            seedLots = try JevEvaluationLot.read(container)
            tools.currentContext = { [weak tools] in
                guard let tools else { return "{}" }
                let context: [String: Any] = ["today": now.isoDay,
                    "time_zone": TimeZone.current.identifier,
                    "household": tools.householdContext() as Any? ?? NSNull()]
                return (try? tools.encode(context)) ?? "{}"
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    nonisolated deinit {}

    func clean() { try? FileManager.default.removeItem(at: directory) }

    static func day(_ offset: Int, from now: Date) -> Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    func dateText(_ offset: Int) -> String { Self.day(offset, from: now).isoDay }

    /// Real model evaluation is opt-in at this boundary and never an automatic test fallback.
    /// Local change publication is disabled as well as system scheduling and cloud adapters.
    func run(_ scenario: AgentScenario, mode: Mode = .scripted, authorizeLiveModel: Bool = false,
             maxSeconds: TimeInterval = 120,
             modelFactory: ModelFactory) async throws -> AgentScenarioReport {
        guard mode != .liveModel || authorizeLiveModel else { throw Failure.liveModelNotAuthorized }
        let definitions = try JSONSerialization.jsonObject(with: Data(tools.toolJSON.utf8)) as! [[String: Any]]
        let isolatedDefinitions = definitions.filter { Self.allowedTools.contains($0["name"] as? String ?? "") }
        let toolsJSON = String(decoding: try JSONSerialization.data(withJSONObject: isolatedDefinitions), as: UTF8.self)
        let model = try modelFactory(.init(instructions: ButlerChat.instructions(jev: false)
            + "\n本次仅操作隔离的合成资料；未提供的能力不能调用。当前日期：\(now.isoDay)。", toolsJSON: toolsJSON))
        let measured = AgentScenarioMeasuredModel(base: model, deadline: .now.addingTimeInterval(max(0, maxSeconds)))
        var report = AgentScenarioReport(scenario: scenario, mode: mode.rawValue, startedAt: .now)
        var messages: [LocalAgentMessage] = [.context(tools.currentContext?() ?? "{}")]
        var previous: String?
        for (index, step) in scenario.steps.enumerated() {
            let began = Date.now
            let previousIDs = tools.pending.map(\.id)
            let roundsBefore = measured.rounds
            var result = AgentScenarioReport.Step(index: index, input: step.input)
            do {
                try Task.checkCancellation()
                guard Date.now < measured.deadline else { throw Failure.timeout }
                result.before = try snapshot()
                switch step.input {
                case .say(let text):
                    tools.beginTurn(request: text, previous: previous, turnID: UUID())
                    messages.append(.context("当前尚未保存的修改：" + tools.pendingContext))
                    messages.append(.user(text))
                    let originalFingerprints = try tools.pending.map { try $0.editFingerprint }
                    var firstActionable: Date?
                    guard let _ = try await ToolConversationLoop.run(model: measured, messages: &messages,
                        rounds: 8, execute: { call in
                            result.toolCalls += 1
                            guard Self.allowedTools.contains(call.name) else {
                                result.blockedTools.append(call.name)
                                return #"{"error":"tool_not_available_in_isolated_evaluation","executed":false}"#
                            }
                            let raw = await self.tools.execute(call)
                            let output = call.name == "get_product_guide"
                                ? try Self.isolatedGuide(raw, definitions: isolatedDefinitions) : raw
                            let currentFingerprints = try self.tools.pending.map { try $0.editFingerprint }
                            if firstActionable == nil, !currentFingerprints.isEmpty,
                               currentFingerprints != originalFingerprints { firstActionable = .now }
                            return output
                        }, log: { _ in }) else { throw Failure.roundsExceeded }
                    result.firstActionableSeconds = firstActionable.map { $0.timeIntervalSince(began) }
                    previous = text
                    tools.endTurn()
                case .confirm:
                    // Validate kinds as well as tool names before invoking the real confirmation boundary.
                    // No injected model can commit a hidden system operation using a permitted tool.
                    guard tools.pending.allSatisfy(Self.safeToConfirm) else { throw Failure.unsafeProposal }
                    result.checks["confirmation_has_proposal"] = !tools.pending.isEmpty
                    let receipts = await tools.confirmResults()
                    result.checks["confirmation_has_successful_receipt"] = !receipts.isEmpty
                        && receipts.allSatisfy { $0.state == .succeeded || $0.state == .reported }
                    messages.append(.note(receipts.map(\.message).joined(separator: "\n")))
                case .discard:
                    result.checks["discard_has_proposal"] = !tools.pending.isEmpty
                    tools.clearPending()
                    messages.append(.note("用户取消了全部待确认修改，没有执行。"))
                }
                result.checks.merge(try checks(step.expected, previousProposalIDs: previousIDs)) { _, new in new }
            } catch {
                // Export bounded failure categories only, never a provider's response or auth material.
                result.error = error is CancellationError ? "cancelled" : String(describing: type(of: error))
            }
            result.after = try? snapshot()
            result.modelRounds = measured.rounds - roundsBefore
            result.seconds = Date.now.timeIntervalSince(began)
            report.steps.append(result)
            if result.error != nil || Task.isCancelled { break }
        }
        return report
    }

    private func snapshot() throws -> AgentScenarioReport.Snapshot {
        .init(inventory: try JevEvaluationLot.read(tools.container), tasks: tools.reminders.reminders,
              pending: tools.pending, travelAllowed: tools.travel.allowed)
    }

    /// Keep the product guide's capability directory truthful for this deliberately limited host.
    private static func isolatedGuide(_ raw: String, definitions: [[String: Any]]) throws -> String {
        guard var value = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              value["error"] == nil else { return raw }
        let names = definitions.compactMap { $0["name"] as? String }
        if let entries = value["tools"] as? [[String: String]] {
            value["tools"] = entries.filter { allowedTools.contains($0["name"] ?? "") }
        }
        if let topics = value["topics"] as? [[String: Any]] {
            value["topics"] = topics.compactMap { topic -> [String: Any]? in
                let count = names.filter { AgentProductGuide.topic(forTool: $0).rawValue == (topic["topic"] as? String) }.count
                guard count > 0 else { return nil }
                var result = topic; result["tool_count"] = count; return result
            }
            value["tool_count"] = names.count
        }
        value["evaluation_scope"] = "仅列出当前隔离评估实际提供的工具"
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    static func safeToConfirm(_ change: PendingChange) -> Bool {
        switch change.kind {
        case .setQuantity, .reminder, .taskPlan: true
        case .travel(.access): true
        default: false
        }
    }

    func checks(_ expected: AgentScenario.Expected, previousProposalIDs: [UUID]) throws -> [String: Bool] {
        var wantedLots = seedLots
        for index in wantedLots.indices {
            if let quantity = expected.quantities[wantedLots[index].id] { wantedLots[index].quantity = quantity }
        }
        let stored = tools.reminders.reminders
        var checks: [String: Bool] = [
            "inventory_exactly_matches_expected_batches": try JevEvaluationLot.read(tools.container) == wantedLots,
            "no_unrequested_notes": tools.notes.records.isEmpty,
            "travel_permission_matches": tools.travel.allowed == expected.travelAllowed,
            "no_device_or_map_requests": device.requests == 0
        ]
        if let task = expected.storedTask {
            let target = stored.first { task.existing ? $0.id == AgentScenario.sharedTask : $0.id != AgentScenario.sharedTask }
            checks["stored_task_matches"] = target.map { matches($0, task, persisted: true) } ?? false
            checks["no_extra_tasks"] = stored.count == (task.existing ? 1 : 2)
            if !task.existing { checks["unrelated_task_unchanged"] = stored.first { $0.id == seedTask.id } == seedTask }
        } else {
            checks["saved_tasks_unchanged"] = stored == [seedTask]
        }
        switch expected.pending {
        case .none: checks["pending_matches"] = tools.pending.isEmpty
        case .quantity(let id, let count):
            checks["pending_matches"] = tools.pending.count == 1 && {
                if case .setQuantity(let lot, let quantity) = tools.pending[0].kind { return lot.id == id && quantity == count }
                return false
            }()
        case .task(let task):
            checks["pending_matches"] = tools.pending.count == 1 && {
                switch tools.pending[0].kind {
                case .reminder(let value): return !task.existing && matches(value, task, persisted: false)
                case .taskPlan(let value, let revision):
                    return task.existing && revision == task.revision && matches(value, task, persisted: false)
                default: return false
                }
            }()
        case .travelAccess(let allowed):
            checks["pending_matches"] = tools.pending.count == 1 && {
                if case .travel(.access(let value)) = tools.pending[0].kind { return value == allowed }
                return false
            }()
        }
        if expected.keepProposalIdentity { checks["proposal_identity_preserved"] = !previousProposalIDs.isEmpty && tools.pending.map(\.id) == previousProposalIDs }
        return checks
    }

    private func matches(_ actual: TimedReminder, _ expected: AgentScenario.Task, persisted: Bool) -> Bool {
        var family = seedTask.sharing!
        switch expected.family {
        case .original: break
        case .personal: family = TaskSharing(scope: .personal, createdBy: AgentScenario.me)
        case .reassigned: family.assignee = AgentScenario.lin
        }
        guard actual.text == expected.text, actual.fireDate == Self.day(expected.day, from: now),
              actual.timePeriod == expected.period, actual.sharing == family,
              actual.revision == expected.revision, actual.repeats == .none, actual.status == .active,
              actual.endDate == nil, actual.autoCompleteAt == nil, actual.phases == nil,
              actual.timeZoneIdentifier == TimeZone.current.identifier, actual.syncReceived == nil else { return false }
        if expected.existing {
            return actual.id == seedTask.id && actual.createdAt == seedTask.createdAt
                && actual.activity.count == expected.revision
                && actual.activity.first == seedTask.activity.first
        }
        return actual.id != seedTask.id && actual.activity.count == (persisted ? 1 : 0)
    }
}

@MainActor private final class AgentScenarioMeasuredModel: LocalAgentModel {
    let base: any LocalAgentModel
    let deadline: Date
    var rounds = 0
    init(base: any LocalAgentModel, deadline: Date) { self.base = base; self.deadline = deadline }
    nonisolated deinit {}
    func reply(to messages: [LocalAgentMessage]) async throws -> LocalModelReply {
        guard Date.now < deadline else { throw AgentScenarioRunner.Failure.timeout }
        rounds += 1
        let worker = Task { @MainActor in try await base.reply(to: messages) }
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))); worker.cancel() }
            catch { }
        }
        defer { timeout.cancel() }
        let outcome = await withTaskCancellationHandler(operation: { await worker.result }, onCancel: { worker.cancel() })
        guard Date.now < deadline else { throw AgentScenarioRunner.Failure.timeout }
        return try outcome.get()
    }
}

@MainActor private final class AgentScenarioNoJudge: ConditionJudge {
    var isConfigured: Bool { false }
    var isEnabled: Bool { false }
    nonisolated deinit {}
    func judge(request: String, questions: [JevClient.Question]) async throws -> [String: Double] { [:] }
}

/// Any accidental access is observable and fails; no Apple service adapter is constructed.
@MainActor private final class AgentScenarioTravelDevice: TravelDevice {
    private(set) var requests = 0
    nonisolated deinit {}
    private func blocked() -> TravelFailure { requests += 1; return TravelFailure("未提供该评估设备能力") }
    func search(_ query: String, near: TravelPoint?) async throws -> [TravelPoint] { throw blocked() }
    func current() async throws -> TravelPoint { throw blocked() }
    func route(from: TravelPoint, to: TravelPoint, mode: TravelMode, departure: Date) async throws -> TravelRoute { throw blocked() }
    func authorizeReminder() async throws { throw blocked() }
    func schedule(_ reminder: PlaceReminder) async throws { throw blocked() }
    func status(_ reminder: PlaceReminder) async throws -> PlaceRequestState { throw blocked() }
    func cancel(_ reminder: PlaceReminder) async throws { throw blocked() }
    func navigate(_ route: TravelRoute) async throws { throw blocked() }
}
#endif
