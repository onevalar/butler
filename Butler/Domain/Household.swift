import CryptoKit
import Foundation

/// One person in the household. The id is derived from their iCloud user, so their iPhone and iPad
/// are the same member.
struct HouseholdMember: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var isOwner: Bool
    var joinedAt: Date

    /// A stable member id for an iCloud user record name.
    static func id(forUser recordName: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(("butler-member|" + recordName).utf8)))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }
}

/// Who can see a thing at home, and who recorded it.
struct ItemSharing: Codable, Equatable {
    enum Scope: String, Codable { case household, personal }
    var scope: Scope
    /// Seen by everyone else, hidden from these members (a surprise present). Only meaningful for household.
    var hiddenFrom: Set<UUID> = []
    var recordedBy: UUID?
    var changedBy: UUID?

    func isVisible(to member: UUID?) -> Bool {
        guard scope == .household, let member else { return true }
        return !hiddenFrom.contains(member)
    }
}

/// This device's membership.
struct HouseholdState: Codable, Equatable {
    enum Role: String, Codable { case owner, member }
    var id: UUID
    var name: String
    var role: Role
    /// The CloudKit zone that holds the household's shared things.
    var zoneName: String
    /// `CKCurrentUserDefaultName` for the owner, the owner's user record name for members.
    var zoneOwner: String
    var me: UUID
    var joinedAt: Date
}

/// When a household is created or joined, the butler decides which of the things already on this phone are
/// the family's and which stay personal, instead of asking about each one.
enum HouseholdClassifier {
    private static let personalWords = [
        "护肤", "面霜", "精华", "眼霜", "乳液", "面膜", "口红", "粉底", "香水", "化妆", "卸妆", "隐形眼镜",
        "处方", "降压", "降糖", "避孕", "验孕", "胰岛素", "安眠", "抗抑郁",
        "礼物", "惊喜", "私人", "日记",
    ]

    /// Personal: someone's own medicine, personal care and presents. Everything else, including the family's
    /// cold medicine and plasters, belongs to the household.
    static func scope(name: String, category: ItemCategory, isMedicine: Bool) -> ItemSharing.Scope {
        personalWords.contains(where: { name.contains($0) }) ? .personal : .household
    }
}

/// Who can see a task, who is responsible for it and who gets its reminders. nil on a task means it was made
/// before households, or outside one: only this person's.
struct TaskSharing: Codable, Equatable {
    enum Scope: String, Codable { case personal, household, people }
    var scope: Scope
    /// `.people`: who besides the creator can see it.
    var people: Set<UUID> = []
    /// `.household`: everyone but these.
    var hiddenFrom: Set<UUID> = []
    var createdBy: UUID?
    var assignee: UUID?
    /// Who gets the reminders. Empty: the person responsible, or the creator when nobody is.
    var notify: Set<UUID> = []

    var isShared: Bool { scope != .personal }

    var reminded: Set<UUID> {
        if !notify.isEmpty { return notify }
        return Set([assignee ?? createdBy].compactMap { $0 })
    }

    func canSee(_ member: UUID) -> Bool {
        switch scope {
        case .personal: createdBy == nil || createdBy == member
        case .household: !hiddenFrom.contains(member)
        case .people: createdBy == member || people.contains(member) || assignee == member || notify.contains(member)
        }
    }

    /// A task assigned to or reminding someone else cannot stay private to its creator: it is shown to them.
    func normalized() -> TaskSharing {
        var value = self
        let others = Set([assignee].compactMap { $0 }).union(notify).subtracting([createdBy].compactMap { $0 })
        if value.scope == .personal, !others.isEmpty { value.scope = .people; value.people = others }
        if value.scope == .people { value.people.formUnion(others) }
        if value.scope != .household { value.hiddenFrom = [] }
        value.hiddenFrom.subtract(others)
        if value.scope != .people { value.people = [] }
        return value
    }
}

/// Names for the people in the household, as this person sees them ("你" for themselves).
struct HouseholdNames: Equatable {
    var me: UUID?
    var names: [UUID: String] = [:]

    static let none = HouseholdNames()

    var isActive: Bool { me != nil }

    /// Names with nobody as "你", for records everyone in the household reads.
    var thirdPerson: HouseholdNames { HouseholdNames(me: UUID(), names: names) }

    func name(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return id == me ? "你" : names[id]
    }

    func list(_ ids: Set<UUID>) -> String {
        ids.compactMap { name($0) }.sorted().joined(separator: "、")
    }

    /// "全家可见 · 交给妈妈 · 提醒妈妈": the decision in one line, for cards and details.
    func summary(_ sharing: TaskSharing?) -> String {
        guard isActive else { return "" }
        guard let sharing else { return "只有你" }
        var parts: [String] = []
        switch sharing.scope {
        case .personal:
            parts.append(sharing.createdBy == nil || sharing.createdBy == me ? "只有你" : "只有\(name(sharing.createdBy) ?? "记下的人")")
        case .household: parts.append(sharing.hiddenFrom.isEmpty ? "全家可见" : "全家可见，不给\(list(sharing.hiddenFrom))看")
        case .people:
            let all = sharing.people.union([sharing.createdBy].compactMap { $0 })
            let others = all.subtracting([me].compactMap { $0 })
            if let me, all.contains(me) { parts.append(others.isEmpty ? "只有你" : "你和\(list(others))可见") }
            else { parts.append("\(list(all))可见") }
        }
        if let assignee = sharing.assignee, let name = name(assignee) { parts.append(assignee == me ? "你负责" : "交给\(name)") }
        // Reminding the person responsible (or the creator) goes without saying; only a choice is shown.
        if !sharing.notify.isEmpty { parts.append("提醒\(list(sharing.notify))") }
        return parts.joined(separator: " · ")
    }

    /// On a list row: only what this person needs to know ("妈妈交给你", "交给妈妈").
    func rowLabel(_ sharing: TaskSharing?) -> String? {
        guard isActive, let sharing, sharing.isShared else { return nil }
        if let assignee = sharing.assignee {
            if assignee == me, let creator = sharing.createdBy, creator != me, let name = name(creator) { return "\(name)交给你" }
            if assignee != me, let name = name(assignee) { return "交给\(name)" }
        }
        return sharing.scope == .household ? "全家" : nil
    }

    /// "妈妈完成" when someone else finished it; nil when it was this person.
    func completedBy(_ task: TimedReminder) -> String? {
        guard isActive, let by = task.activity.last(where: { $0.kind == "completed" })?.by, by != me else { return nil }
        return name(by).map { "\($0)完成" }
    }
}
