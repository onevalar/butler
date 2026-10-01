import Foundation

struct ContactFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
enum ContactAccess: String { case notDetermined, denied, restricted, limited, full }
enum ContactField: String, Codable, CaseIterable {
    case givenName, familyName, organization, phones, emails
    var title: String {
        switch self {
        case .givenName: "名"
        case .familyName: "姓"
        case .organization: "单位"
        case .phones: "电话"
        case .emails: "邮箱"
        }
    }
    func validate(_ values: [ContactValue]) throws {
        guard values.count <= 20, values.allSatisfy({ $0.value.count <= 200 && ($0.label?.count ?? 0) <= 80 }) else {
            throw ContactFailure("单个字段最多20项，每项内容不超过200字。")
        }
        if self != .phones && self != .emails {
            guard values.count == 1, values[0].label == nil else { throw ContactFailure("姓名/单位须提供一个无标签的文本值；空文本表示清空。") }
        } else {
            guard values.allSatisfy({ !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw ContactFailure("电话/邮箱不能有空白项；空数组才表示清空整个字段。")
            }
        }
    }
}
struct ContactValue: Codable, Equatable { let label: String?; let value: String }
struct ContactCandidate: Codable, Equatable {
    let id: String
    let name: String
    let organization: String
}
struct ContactSelection: Codable, Equatable {
    let candidate: ContactCandidate
    let field: ContactField
    let values: [ContactValue]
}
struct ContactDraft: Codable, Equatable {
    let givenName: String
    let familyName: String
    let organization: String
    let phones: [ContactValue]
    let emails: [ContactValue]
    var name: String { [familyName, givenName].filter { !$0.isEmpty }.joined(separator: " ") }
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ContactFailure("请提供联系人姓名，不能创建空白联系人。") }
        for field in ContactField.allCases { try field.validate(values(field)) }
    }
    func values(_ field: ContactField) -> [ContactValue] {
        switch field {
        case .givenName: [.init(label: nil, value: givenName)]
        case .familyName: [.init(label: nil, value: familyName)]
        case .organization: [.init(label: nil, value: organization)]
        case .phones: phones
        case .emails: emails
        }
    }
}
enum ContactChange: Codable, Equatable {
    case access(Bool)
    case read(ContactCandidate, ContactField)
    case create(ContactDraft, existingIDs: [String])
    case update(ContactSelection, [ContactValue])
    case closeUnknown(UUID)
}
@MainActor protocol ContactsDevice {
    var access: ContactAccess { get }
    func authorize() async throws
    /// Fetch at most limit matching candidates, without telephone/email data.
    func search(_ name: String, limit: Int) throws -> [ContactCandidate]
    func read(_ id: String, field: ContactField) throws -> ContactSelection
    func create(_ draft: ContactDraft) throws -> String
    /// Must re-fetch and compare before changing only the selected field.
    func update(_ before: ContactSelection, values: [ContactValue]) throws
}
