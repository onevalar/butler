import CryptoKit
import Foundation

/// One person in the household. The id is derived from their iCloud user, so their iPhone and iPad
/// are the same member.
struct HouseholdMember: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var isOwner: Bool
    var joinedAt: Date
    /// When this person does not want to be disturbed by what others send.
    var quiet: QuietHours? = nil

    /// A stable member id for an iCloud user record name.
    static func id(forUser recordName: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(("butler-member|" + recordName).utf8)))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }
}

/// A daily window, in minutes from midnight; it may cross midnight (22:00–07:00).
struct QuietHours: Codable, Equatable {
    var start: Int
    var end: Int

    var label: String { "\(Self.clock(start))–\(Self.clock(end))" }

    static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return start <= end ? (minute >= start && minute < end) : (minute >= start || minute < end)
    }

    /// The date itself, or the end of the window it falls in.
    func deliveryDate(for date: Date, calendar: Calendar = .current) -> Date {
        guard start != end, contains(date, calendar: calendar) else { return date }
        let day = calendar.startOfDay(for: date)
        var end = calendar.date(byAdding: .minute, value: self.end, to: day) ?? date
        if end <= date { end = calendar.date(byAdding: .day, value: 1, to: end) ?? date }
        return end
    }
}

/// A rule the butler follows when deciding who sees, does and is reminded of things. Household rules are shared;
/// a person's own rules stay on their phone.
struct HouseholdRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var createdBy: UUID?
    var createdAt = Date()
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
    /// If it is still not done this long after its time, this person is reminded too (one-off tasks).
    var escalateTo: UUID? = nil
    var escalateAfter: Int? = nil

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
        let others = Set([assignee, escalateTo].compactMap { $0 }).union(notify).subtracting([createdBy].compactMap { $0 })
        if value.scope == .personal, !others.isEmpty { value.scope = .people; value.people = others }
        if value.scope == .people { value.people.formUnion(others) }
        if value.scope != .household { value.hiddenFrom = [] }
        value.hiddenFrom.subtract(others)
        if value.scope != .people { value.people = [] }
        if value.escalateTo == nil { value.escalateAfter = nil }
        else if value.escalateAfter == nil { value.escalateAfter = 30 }
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
        if let next = sharing.escalateTo, let name = name(next), let after = sharing.escalateAfter {
            parts.append("\(Self.duration(after))没人处理就提醒\(name)")
        }
        // Reminding the person responsible (or the creator) goes without saying; only a choice is shown.
        if !sharing.notify.isEmpty { parts.append("提醒\(list(sharing.notify))") }
        return parts.joined(separator: " · ")
    }

    static func duration(_ minutes: Int) -> String {
        minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes) 分钟"
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

    /// "提醒老婆一下" for a task someone else is responsible for.
    func nudgeLabel(_ sharing: TaskSharing?) -> String? {
        guard isActive, let sharing, sharing.isShared, let assignee = sharing.assignee, assignee != me,
              let name = name(assignee) else { return nil }
        return "提醒\(name)一下"
    }

    /// "妈妈完成" when someone else finished it; nil when it was this person.
    func completedBy(_ task: TimedReminder) -> String? {
        guard isActive, let by = task.activity.last(where: { $0.kind == "completed" })?.by, by != me else { return nil }
        return name(by).map { "\($0)完成" }
    }
}
