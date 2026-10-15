import Foundation
import Observation
import SwiftData

/// This device's view of the household: membership, the people in it, and which things are shared.
/// Plain files next to the other sync records; nothing here is a credential.
@MainActor @Observable
final class HouseholdStore {
    static let shared = HouseholdStore(directory: URL.applicationSupportDirectory
        .appendingPathComponent("DeviceSync", isDirectory: true).appendingPathComponent("Household", isDirectory: true))

    private(set) var state: HouseholdState?
    private(set) var members: [HouseholdMember] = []
    private(set) var aliases: [UUID: String] = [:]
    private(set) var sharing: [UUID: ItemSharing] = [:]
    /// Things that were on this phone when it joined, waiting to be merged or sorted after the first sync.
    private(set) var staged: Set<UUID> = []
    /// Durable even on an empty phone: acceptance may succeed before the first download does.
    private(set) var joining = false
    @ObservationIgnored let directory: URL

    init(directory: URL) {
        self.directory = directory
        state = load("state.json")
        members = load("members.json") ?? []
        aliases = load("aliases.json") ?? [:]
        sharing = load("sharing.json") ?? [:]
        staged = load("staged.json") ?? []
        joining = state != nil && ((load("joining.json") as Bool?) ?? !staged.isEmpty)
        hiddenTasks = load("hidden-tasks.json") ?? [:]
        rules = load("rules.json") ?? []
        myRules = load("my-rules.json") ?? []
    }

    nonisolated deinit {}

    var me: HouseholdMember? { state.flatMap { state in members.first { $0.id == state.me } } }
    var isOwner: Bool { state?.role == .owner }

    func member(_ id: UUID?) -> HouseholdMember? { id.flatMap { id in members.first { $0.id == id } } }

    /// Names as this person sees them, for task labels.
    var names: HouseholdNames {
        guard let state else { return .none }
        return HouseholdNames(me: state.me, names: Dictionary(members.map { ($0.id, displayName($0)) }, uniquingKeysWith: { a, _ in a }))
    }

    func displayName(_ member: HouseholdMember) -> String {
        aliases[member.id] ?? member.name
    }

    /// Personal relationship names never enter the shared member record.
    func setAlias(_ raw: String, for id: UUID) throws {
        guard let state, id != state.me, member(id) != nil else { throw SyncFailure("请重新选择家人。") }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 20 else { throw SyncFailure("称呼最多 20 个字。") }
        guard !["我", "自己", "我自己"].contains(value) else { throw SyncFailure("请使用对这位家人的称呼。") }
        guard value.isEmpty || !members.contains(where: { $0.id != id && (displayName($0) == value || $0.name == value) }) else {
            throw SyncFailure("这个名字或称呼已经对应另一位家人，请换一个，避免提醒错人。")
        }
        var next = aliases
        next[id] = value.isEmpty ? nil : value
        try persist(next, "aliases.json")
        aliases = next
        NotificationCenter.default.post(name: .init("butlerBriefSourcesChanged"), object: nil)
    }

    @discardableResult
    func setHouseholdName(_ raw: String, householdID: UUID) throws -> String {
        let value = try Self.validName(raw)
        guard var state, state.id == householdID else { throw SyncFailure("家庭已变化，请重新打开页面。") }
        state.name = value
        try persist(state, "state.json")
        self.state = state
        return value
    }

    func renameMe(_ raw: String) throws {
        guard var me else { throw SyncFailure("请先加入家庭。") }
        me.name = try Self.validName(raw)
        var next = members
        guard let index = next.firstIndex(where: { $0.id == me.id }) else { throw SyncFailure("成员资料已变化。") }
        next[index] = me
        try persist(next, "members.json")
        members = next
    }

    static func validName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw SyncFailure("请填写 1 到 40 个字的名字。") }
        return name
    }

    func member(named raw: String) -> HouseholdMember? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if ["我", "自己", "我自己"].contains(name) { return me }
        if let id = UUID(uuidString: name) { return member(id) }
        // Ambiguity must not silently assign a reminder to the first person in the list.
        let exact = members.filter { displayName($0) == name || $0.name == name }
        if !exact.isEmpty { return exact.count == 1 ? exact[0] : nil }
        let partial = members.filter { displayName($0).contains(name) || name.contains(displayName($0)) || $0.name.contains(name) || name.contains($0.name) }
        return partial.count == 1 ? partial[0] : nil
    }

    /// Household tasks this person cannot see: kept aside so they never reach lists, reminders or the model,
    /// and still travel through the household's sync unchanged.
    private(set) var hiddenTasks: [UUID: TimedReminder] = [:]

    func setHiddenTask(_ task: TimedReminder?, id: UUID) {
        hiddenTasks[id] = task
        save(hiddenTasks, "hidden-tasks.json")
    }

    // MARK: Rules and quiet hours

    /// The household's rules, shared with everyone.
    private(set) var rules: [HouseholdRule] = []
    /// This person's own rules; they stay on this phone.
    private(set) var myRules: [HouseholdRule] = []

    func setRule(_ rule: HouseholdRule?, id: UUID) {
        rules.removeAll { $0.id == id }
        if let rule { rules.append(rule) }
        rules.sort { $0.createdAt < $1.createdAt }
        save(rules, "rules.json")
    }

    func setMyRule(_ rule: HouseholdRule?, id: UUID) {
        myRules.removeAll { $0.id == id }
        if let rule { myRules.append(rule) }
        myRules.sort { $0.createdAt < $1.createdAt }
        save(myRules, "my-rules.json")
    }

    func setQuiet(_ quiet: QuietHours?) {
        guard var me else { return }
        me.quiet = quiet
        upsert(me)
    }

    /// When something others send should reach this person: now, or when their quiet hours end.
    func deliveryDate(for date: Date) -> Date {
        me?.quiet?.deliveryDate(for: date) ?? date
    }

    /// The things that go through the household zone. Things not yet sorted are sorted first, so a thing never
    /// passes through this device's own sync and then the household's.
    func householdProducts(container: ModelContainer) -> Set<UUID> {
        guard state != nil else { return [] }
        classifyNew(container: container)
        return Set(sharing.filter { $0.value.scope == .household && !staged.contains($0.key) }.keys)
    }

    /// Whether this member may see a product (hidden-from-me presents are not shown or given to the model).
    func isVisible(_ product: UUID) -> Bool {
        guard let state, let entry = sharing[product] else { return true }
        return entry.isVisible(to: state.me)
    }

    /// New things recorded on this phone: the butler decides from what they are; they were recorded by me.
    func classifyNew(container: ModelContainer) {
        guard let state else { return }
        let context = ModelContext(container)
        guard let products = try? context.fetch(FetchDescriptor<CatalogProduct>()) else { return }
        let lots = (try? context.fetch(FetchDescriptor<InventoryLot>())) ?? []
        var changed = false
        for product in products where sharing[product.id] == nil && !staged.contains(product.id) {
            let lot = lots.first { $0.productID == product.id }
            let facts = lot.map { LotFacts(lot: $0, product: product) }
            let scope = HouseholdClassifier.scope(name: product.canonicalName, category: facts?.category ?? .other,
                                                  isMedicine: facts?.isMedicine ?? false)
            sharing[product.id] = ItemSharing(scope: scope, recordedBy: state.me)
            changed = true
        }
        if changed { save(sharing, "sharing.json") }
    }

    // MARK: Changes

    func begin(_ state: HouseholdState, me: HouseholdMember, staging: Set<UUID> = [], joining: Bool = false) {
        if self.state?.id != state.id { aliases = [:]; save(aliases, "aliases.json") }
        self.state = state
        members = [me]
        staged = staging
        self.joining = joining
        sharing = sharing.filter { !staging.contains($0.key) }
        save(state, "state.json"); save(members, "members.json"); save(staged, "staged.json"); save(sharing, "sharing.json")
        save(joining, "joining.json")
    }

    func completeJoining() {
        joining = false
        save(false, "joining.json")
    }

    func upsert(_ member: HouseholdMember) {
        members.removeAll { $0.id == member.id }
        members.append(member)
        members.sort { ($0.isOwner ? 0 : 1, $0.joinedAt) < ($1.isOwner ? 0 : 1, $1.joinedAt) }
        save(members, "members.json")
    }

    func removeMember(_ id: UUID) {
        aliases[id] = nil
        save(aliases, "aliases.json")
        members.removeAll { $0.id == id }
        save(members, "members.json")
    }

    func setSharing(_ value: ItemSharing?, for product: UUID) {
        sharing[product] = value
        save(sharing, "sharing.json")
    }

    func unstage(_ products: Set<UUID>) {
        staged.subtract(products)
        save(staged, "staged.json")
    }

    /// Leaving or a dissolved household: everything stays on this phone as this person's own.
    func end() {
        state = nil
        members = []
        aliases = [:]
        staged = []
        joining = false
        sharing = [:]
        hiddenTasks = [:]
        rules = []
        // This person's own rules are theirs, not the household's: they stay.
        for name in ["state.json", "aliases.json", "members.json", "sharing.json", "staged.json", "joining.json", "hidden-tasks.json", "rules.json"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: Files

    private func load<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func persist<T: Encodable>(_ value: T, _ name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SyncRecord.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try SyncRecord.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            ChatDiagnostics.log("household save \(name) failed: \(error)")
        }
    }
}
