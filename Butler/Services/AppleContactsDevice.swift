import Contacts
import Foundation
import UIKit

@MainActor final class AppleContactsDevice: ContactsDevice {
    // Merely listing tools or checking status never constructs a store or requests permission.
    private lazy var store = CNContactStore()
    var access: ContactAccess {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .full
        case .limited: .limited
        @unknown default: .denied
        }
    }
    private func ready() throws {
        guard access == .full || access == .limited else { throw ContactFailure("系统未允许访问联系人，请按需在设置调整。") }
        guard UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable else {
            throw ContactFailure("请在已解锁的App前台使用通讯录；未安排后台读取或写入。")
        }
        try Task.checkCancellation()
    }
    func authorize() async throws {
        guard UIApplication.shared.applicationState == .active else { throw ContactFailure("请保持App在前台再确认通讯录访问。") }
        if access == .notDetermined { _ = try await store.requestAccess(for: .contacts) }
        try ready() // A completed prompt is not a full-access grant.
    }
    private var identityKeys: [String] { [CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey] }
    private func key(_ field: ContactField) -> String {
        switch field {
        case .givenName: CNContactGivenNameKey
        case .familyName: CNContactFamilyNameKey
        case .organization: CNContactOrganizationNameKey
        case .phones: CNContactPhoneNumbersKey
        case .emails: CNContactEmailAddressesKey
        }
    }
    private func candidate(_ c: CNContact) -> ContactCandidate {
        .init(id: c.identifier, name: [c.familyName, c.givenName].filter { !$0.isEmpty }.joined(separator: " "), organization: c.organizationName)
    }
    private func values(_ c: CNContact, _ field: ContactField) -> [ContactValue] {
        switch field {
        case .givenName: [.init(label: nil, value: c.givenName)]
        case .familyName: [.init(label: nil, value: c.familyName)]
        case .organization: [.init(label: nil, value: c.organizationName)]
        case .phones: c.phoneNumbers.map { .init(label: $0.label, value: $0.value.stringValue) }
        case .emails: c.emailAddresses.map { .init(label: $0.label, value: $0.value as String) }
        }
    }
    func search(_ name: String, limit: Int) throws -> [ContactCandidate] {
        try ready()
        let request = CNContactFetchRequest(keysToFetch: identityKeys.map { $0 as CNKeyDescriptor })
        request.predicate = CNContact.predicateForContacts(matchingName: name)
        request.unifyResults = true
        var result: [ContactCandidate] = []
        do {
            try store.enumerateContacts(with: request) { contact, stop in
                result.append(self.candidate(contact))
                if result.count >= limit { stop.pointee = true }
            }
        } catch { throw ContactFailure("联系人查询失败；这不是没有匹配结果，也没有扩大访问范围。") }
        return result
    }
    private func native(_ id: String, field: ContactField) throws -> CNContact {
        try ready()
        do {
            return try store.unifiedContact(withIdentifier: id,
                keysToFetch: Array(Set(identityKeys + [key(field)])).map { $0 as CNKeyDescriptor })
        } catch { throw ContactFailure("此联系人已变化、不可读或不在获准范围；请重新查询，不按同名代替。") }
    }
    func read(_ id: String, field: ContactField) throws -> ContactSelection {
        let c = try native(id, field: field)
        return .init(candidate: candidate(c), field: field, values: values(c, field))
    }
    private func set(_ field: ContactField, values: [ContactValue], on c: CNMutableContact, preserving old: CNContact? = nil) {
        switch field {
        case .givenName: c.givenName = values[0].value
        case .familyName: c.familyName = values[0].value
        case .organization: c.organizationName = values[0].value
        case .phones:
            c.phoneNumbers = values.map { v in
                old?.phoneNumbers.first { $0.label == v.label && $0.value.stringValue == v.value }
                    ?? CNLabeledValue(label: v.label, value: CNPhoneNumber(stringValue: v.value))
            }
        case .emails:
            c.emailAddresses = values.map { v in
                old?.emailAddresses.first { $0.label == v.label && ($0.value as String) == v.value }
                    ?? CNLabeledValue(label: v.label, value: v.value as NSString)
            }
        }
    }
    func create(_ draft: ContactDraft) throws -> String {
        try ready(); try draft.validate()
        let c = CNMutableContact()
        for field in ContactField.allCases { set(field, values: draft.values(field), on: c) }
        let request = CNSaveRequest(); request.add(c, toContainerWithIdentifier: nil)
        try store.execute(request)
        return c.identifier
    }
    func update(_ before: ContactSelection, values: [ContactValue]) throws {
        try before.field.validate(values)
        let current = try native(before.candidate.id, field: before.field)
        guard ContactSelection(candidate: candidate(current), field: before.field, values: self.values(current, before.field)) == before else {
            throw ContactFailure("联系人在确认后发生变化，未覆盖。")
        }
        let changed = current.mutableCopy() as! CNMutableContact
        set(before.field, values: values, on: changed, preserving: current)
        let request = CNSaveRequest(); request.update(changed)
        try store.execute(request)
    }
}

extension ContactsStore {
    static let shared: ContactsStore = {
        let directory = URL.applicationSupportDirectory.appendingPathComponent("DeviceContacts", isDirectory: true)
        var failed = false
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
        } catch { failed = true }
        return ContactsStore(file: directory.appendingPathComponent("operations.json"), device: AppleContactsDevice(), preparationFailed: failed)
    }()
}
