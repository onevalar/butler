import Foundation

/// Opt in only for the Butler executor whose read paths have been audited. Other loop callers
/// retain their serial semantics. A policy and its epoch must be created before prefetch starts.
@MainActor
struct ToolReadExecutionPolicy {
    static let serial = ToolReadExecutionPolicy(epoch: nil, maximumParallelReads: 1)

    let epoch: ToolReadCacheEpoch?
    let maximumParallelReads: Int
    let preparedAt: Date
    let preparedVersion: ToolReadCacheEpoch.Version?
    let now: () -> Date

    private init(epoch: ToolReadCacheEpoch?, maximumParallelReads: Int, now: @escaping () -> Date = { .now }) {
        self.epoch = epoch
        self.maximumParallelReads = maximumParallelReads
        self.now = now
        preparedAt = now()
        preparedVersion = epoch?.version
    }

    static func butlerReadOnly(epoch: ToolReadCacheEpoch, now: @escaping () -> Date = { .now }) -> Self {
        Self(epoch: epoch, maximumParallelReads: 3, now: now)
    }

    var enabled: Bool { epoch != nil }

    func canRunInParallel(_ call: LocalToolCall) -> Bool {
        guard enabled, let arguments = Self.arguments(call) else { return false }
        switch call.name {
        // A batch may contain at most one search_inventory: it awaits Jev, whose executor
        // retains per-query failure state. Other reads here never call Jev or change proposals.
        case "search_inventory", "search_notes", "get_product_guide", "get_current_context",
             "get_settings", "get_inventory_history", "get_destination_weather": return true
        case "get_weather": return arguments["refresh"] as? Bool == false
        // get_tasks refreshes automatic completion. It is a barrier even though its result
        // can be reused briefly. Permission, candidate-search and unknown tools are barriers.
        default: return false
        }
    }

    func key(_ call: LocalToolCall) -> String? {
        guard enabled, let arguments = Self.arguments(call) else { return nil }
        switch call.name {
        case "search_inventory", "search_notes", "get_product_guide", "get_settings",
             "get_inventory_history", "get_tasks", "get_destination_weather": break
        case "get_weather": guard arguments["refresh"] as? Bool == false else { return nil }
        default: return nil // Current UI/permission context is deliberately never cached.
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) else { return nil }
        return call.name + "\n" + String(decoding: data, as: UTF8.self)
    }

    /// Reject incomplete or failed reads, including nested partial pages. A failed read must
    /// be retryable, not made sticky by the optimization.
    func reusableOutput(_ output: String, call: LocalToolCall, prefetched: Bool = false) -> String? {
        guard key(call) != nil,
              let value = try? JSONSerialization.jsonObject(with: Data(output.utf8)),
              Self.isComplete(value) else { return nil }
        if call.name == "search_inventory" {
            guard let object = value as? [String: Any], object["complete"] as? Bool == true,
                  object["jev"] == nil else { return nil }
        }
        if call.name == "get_weather", (value as? [String: Any])?["fresh"] as? Bool != true { return nil }
        if call.name == "get_destination_weather", (value as? [String: Any])?["available"] as? Bool != true { return nil }
        // Prefetch notes carry provenance and pagination; ordinary search_notes returns an
        // array. Reuse only a complete prefetch and preserve the ordinary tool's wire shape.
        if prefetched, call.name == "search_notes" {
            guard let object = value as? [String: Any], object["complete"] as? Bool == true,
                  let notes = object["notes"] as? [[String: Any]] else { return nil }
            let rows = notes.map { note in note.filter { ["id", "title", "text"].contains($0.key) } }
            guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        return output
    }

    func expiresAt(output: String, call: LocalToolCall, readAt: Date) -> Date {
        var expiry = readAt.addingTimeInterval(call.name == "get_tasks" ? 5 : 30)
        // Relative dates and expiry descriptions must be recomputed on a new calendar day.
        if let midnight = Calendar.current.dateInterval(of: .day, for: readAt)?.end { expiry = min(expiry, midnight) }
        if let value = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] {
            let formatter = ISO8601DateFormatter()
            if let raw = value["valid_until"] as? String, let date = formatter.date(from: raw) { expiry = min(expiry, date) }
            if call.name == "get_weather" {
                for (key, lifetime) in [("fetched_at", 1800.0), ("observed_at", 7200.0)] {
                    if let raw = value[key] as? String, let date = formatter.date(from: raw) {
                        expiry = min(expiry, date.addingTimeInterval(lifetime))
                    }
                }
            }
            if call.name == "get_tasks", let tasks = value["tasks"] as? [[String: Any]] {
                for task in tasks {
                    let dates = (task["next_notifications"] as? [String] ?? []) + [task["autoCompleteAt"] as? String].compactMap { $0 }
                    for raw in dates where formatter.date(from: raw).map({ $0 > readAt }) == true {
                        if let date = formatter.date(from: raw) { expiry = min(expiry, date) }
                    }
                }
            }
        }
        return expiry
    }

    private static func arguments(_ call: LocalToolCall) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
    }

    private static func isComplete(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            for (key, value) in object {
                if ["error", "schedule_warning"].contains(key), !(value is NSNull) { return false }
                if ["complete", "available", "fresh"].contains(key), value as? Bool == false { return false }
                if key == "truncated", value as? Bool == true { return false }
                if !isComplete(value) { return false }
            }
        } else if let array = value as? [Any] { return array.allSatisfy(isComplete) }
        return true
    }
}

/// Notifications cover saved inventory, notes, reminders and settings. Membership/visibility
/// also need a synchronous snapshot: several HouseholdStore mutations intentionally emit no
/// notification. Never instantiate the global household just to enable this optimization.
@MainActor
final class ToolReadCacheEpoch {
    struct HouseholdVersion: Equatable {
        let state: HouseholdState?
        let members: [HouseholdMember]
        let aliases: [UUID: String]
        let sharing: [UUID: ItemSharing]
        let staged: Set<UUID>
        let joining: Bool
    }
    struct Version: Equatable {
        let changes: UInt64
        let household: HouseholdVersion?
        let notes: [LocalMemory]?
        let reminders: [TimedReminder]?
        let scheduleWarning: String?
        let judgeAvailable: Bool?
        let judgeToken: UUID?
    }
    private let counter: ToolReadChangeCounter
    private weak var household: HouseholdStore?
    private weak var notes: LocalMemoryStore?
    private weak var reminders: ReminderStore?
    private let judge: (any ConditionJudge)?

    init(household: HouseholdStore? = nil, judge: (any ConditionJudge)? = nil,
         notes: LocalMemoryStore? = nil, reminders: ReminderStore? = nil, center: NotificationCenter = .default) {
        self.household = household
        self.judge = judge
        self.notes = notes
        self.reminders = reminders
        counter = ToolReadChangeCounter(center: center)
    }

    nonisolated deinit {}

    func invalidate() { counter.invalidate() }

    var version: Version {
        let family = household.map {
            HouseholdVersion(state: $0.state, members: $0.members, aliases: $0.aliases,
                             sharing: $0.sharing, staged: $0.staged, joining: $0.joining)
        }
        // Value snapshots use copy-on-write storage. No file I/O, re-encoding, hashing or
        // rebuilding task histories on every lookup. reload() can replace these values
        // without posting a change notification, so the notification counter alone is insufficient.
        return Version(changes: counter.value, household: family, notes: notes?.records,
                       reminders: reminders?.reminders, scheduleWarning: reminders?.scheduleWarning,
                       judgeAvailable: judge?.isAvailable, judgeToken: judge?.reuseToken)
    }
}

/// Notification delivery can be off the main actor. Increment immediately, rather than
/// queueing an actor hop that could arrive after a cache lookup.
private final class ToolReadChangeCounter: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated private let center: NotificationCenter
    nonisolated(unsafe) private var count: UInt64 = 0
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(center: NotificationCenter) {
        self.center = center
        for name in [Notification.Name("butlerBriefSourcesChanged"), Notification.Name("butlerSettingsChanged"), UserDefaults.didChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.invalidate() })
        }
    }

    nonisolated var value: UInt64 { lock.withLock { count } }
    nonisolated func invalidate() { lock.withLock { count &+= 1 } }
    nonisolated deinit { for observer in observers { center.removeObserver(observer) } }
}

struct ToolLoopMetrics: Equatable {
    var modelRounds = 0
    var executedTools = 0
    var cacheHits = 0
    var prefetchedHits = 0
    var parallelGroups = 0
    var maximumParallel = 0
}
