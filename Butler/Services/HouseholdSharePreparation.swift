import CloudKit
import Foundation

/// Recover only a missing invitation record in an existing owner zone. Never recreate a missing zone.
@MainActor enum HouseholdSharePreparation {
    static func prepare(zoneID: CKRecordZone.ID, title: String,
                        fetch: () async throws -> CKRecord,
                        verifyZone: () async throws -> Void,
                        save: (CKShare) async throws -> CKRecord) async throws -> CKShare {
        do { return try checked(try await fetch()) }
        catch let error as CKError where error.code == .unknownItem { }
        try Task.checkCancellation()
        try await verifyZone()
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue
        share.publicPermission = .none
        do { return try checked(try await save(share)) }
        catch let error as CKError where error.code == .serverRecordChanged {
            // Another device may have created the same zone-wide share. Keep its participants.
            return try checked(try await fetch())
        }
    }

    static func checked(_ record: CKRecord) throws -> CKShare {
        guard let share = record as? CKShare else { throw SyncFailure("家庭邀请记录异常，请稍后重试。") }
        return share
    }

    static func message(for error: Error) -> String {
        guard let cloud = error as? CKError else {
            return error is SyncFailure ? error.localizedDescription : "暂时无法准备家庭邀请，请稍后重试。"
        }
        switch cloud.code {
        case .networkUnavailable, .networkFailure:
            return "暂时连接不上 iCloud，请检查网络后重新点击“邀请家人”。"
        case .notAuthenticated:
            return "请先在 iPhone 设置中登录创建这个家庭时使用的 iCloud 账号，再邀请家人。"
        case .zoneNotFound, .userDeletedZone:
            return "iCloud 中找不到这个家庭的共享空间。请确认使用的是创建家庭时的账号；本机资料仍然保留。"
        case .permissionFailure:
            return "当前 iCloud 账号没有邀请权限，请使用创建这个家庭的账号。"
        case .quotaExceeded:
            return "iCloud 储存空间不足，请腾出空间后重试邀请。"
        case .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return "iCloud 暂时繁忙，请稍后重新点击“邀请家人”。"
        default:
            return "暂时无法准备家庭邀请，请稍后重试。已有家庭和本机资料不会因此删除。"
        }
    }
}
