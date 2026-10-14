import CloudKit
import XCTest
@testable import Butler

@MainActor final class HouseholdSharePreparationTests: XCTestCase {
    private let zone = CKRecordZone.ID(zoneName: "test-family", ownerName: CKCurrentUserDefaultName)

    func testExistingShareIsKeptWithoutWritingOrResettingParticipants() async throws {
        let existing = CKShare(recordZoneID: zone)
        let result = try await HouseholdSharePreparation.prepare(zoneID: zone, title: "家",
            fetch: { existing }, verifyZone: { XCTFail("Existing share needs no repair") },
            save: { _ in XCTFail("Do not replace an existing share"); return existing })
        XCTAssertTrue(result === existing)
    }

    func testMissingShareIsCreatedOnlyAfterZoneIsVerified() async throws {
        var verified = false
        var writes = 0
        let result = try await HouseholdSharePreparation.prepare(zoneID: zone, title: "我们家",
            fetch: { throw CKError(.unknownItem) }, verifyZone: { verified = true },
            save: { share in
                XCTAssertTrue(verified); writes += 1
                XCTAssertEqual(share.publicPermission, .none)
                XCTAssertEqual(share.recordID.zoneID, self.zone)
                return share
            })
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(result[CKShare.SystemFieldKey.title] as? String, "我们家")
    }

    func testNetworkAndPermissionFailuresDoNotCreateAReplacementShare() async {
        for code: CKError.Code in [.networkFailure, .permissionFailure, .notAuthenticated, .zoneNotFound] {
            do {
                _ = try await HouseholdSharePreparation.prepare(zoneID: zone, title: "家",
                    fetch: { throw CKError(code) }, verifyZone: { XCTFail("Not a missing share") },
                    save: { _ in XCTFail("Must not write"); throw CKError(.internalError) })
                XCTFail("Must propagate the original error")
            } catch { XCTAssertEqual((error as? CKError)?.code, code) }
        }
    }

    func testMissingZoneIsNotRecreated() async {
        do {
            _ = try await HouseholdSharePreparation.prepare(zoneID: zone, title: "家",
                fetch: { throw CKError(.unknownItem) }, verifyZone: { throw CKError(.zoneNotFound) },
                save: { _ in XCTFail("Must not create share in missing zone"); throw CKError(.internalError) })
            XCTFail("Must fail")
        } catch { XCTAssertEqual((error as? CKError)?.code, .zoneNotFound) }
    }

    func testFailedSaveCannotBecomeASuccessfulInvitation() async {
        do {
            _ = try await HouseholdSharePreparation.prepare(zoneID: zone, title: "家",
                fetch: { throw CKError(.unknownItem) }, verifyZone: {},
                save: { _ in throw CKError(.quotaExceeded) })
            XCTFail("Save failure must be visible")
        } catch { XCTAssertEqual((error as? CKError)?.code, .quotaExceeded) }
    }

    func testConcurrentCreationFetchesTheWinningShare() async throws {
        var reads = 0
        let existing = CKShare(recordZoneID: zone)
        let result = try await HouseholdSharePreparation.prepare(zoneID: zone, title: "家",
            fetch: { reads += 1; if reads == 1 { throw CKError(.unknownItem) }; return existing },
            verifyZone: {}, save: { _ in throw CKError(.serverRecordChanged) })
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(result === existing)
    }

    func testWrongRecordTypeIsNotSilentlyReplaced() async {
        do {
            _ = try await HouseholdSharePreparation.prepare(zoneID: zone, title: "家",
                fetch: { CKRecord(recordType: "Unexpected") }, verifyZone: { XCTFail() },
                save: { _ in XCTFail(); throw CKError(.internalError) })
            XCTFail("Invalid record must fail")
        } catch { XCTAssertTrue(error is SyncFailure) }
    }

    func testUserMessageHidesCloudRecordIDsAndGivesAnAction() {
        let error = CKError(.unknownItem, userInfo: [NSLocalizedDescriptionKey: "cloudkit.zoneshare <private record id>"])
        XCTAssertFalse(HouseholdSharePreparation.message(for: error).contains("zoneshare"))
        XCTAssertTrue(HouseholdSharePreparation.message(for: CKError(.networkFailure)).contains("网络"))
        XCTAssertTrue(HouseholdSharePreparation.message(for: CKError(.notAuthenticated)).contains("账号"))
    }
}
