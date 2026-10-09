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
