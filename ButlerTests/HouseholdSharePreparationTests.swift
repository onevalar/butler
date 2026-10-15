import CloudKit
import XCTest
@testable import Butler

@MainActor final class HouseholdSharePreparationTests: XCTestCase {
    private let zone = CKRecordZone.ID(zoneName: "test-family", ownerName: CKCurrentUserDefaultName)

    func testRenameRefetchesOnConflictAndPreservesOtherInvitations() async throws {
        let old = CKShare(recordZoneID: zone), fresh = CKShare(recordZoneID: zone)
        let guest = CKShare.Participant.oneTimeURLParticipant()
        guest.permission = .readWrite; fresh.addParticipant(guest)
        var reads = 0
        let result = try await HouseholdSharePreparation.rename(title: "森林之家", fetch: {
            reads += 1; return reads == 1 ? old : fresh
        }, save: { share in
            if reads == 1 { throw CKError(.serverRecordChanged) }
            XCTAssertEqual(share.publicPermission, .none)
            XCTAssertTrue(share.participants.contains { $0.participantID == guest.participantID })
            return share
        })
        XCTAssertEqual(result[CKShare.SystemFieldKey.title] as? String, "森林之家")
        XCTAssertEqual(reads, 2)
    }

    func testRenameFailureDoesNotInventSuccessfulReceipt() async {
        do {
            _ = try await HouseholdSharePreparation.rename(title: "新的家", fetch: { CKShare(recordZoneID: self.zone) },
                save: { _ in throw CKError(.networkFailure) })
            XCTFail("A failed save must not report success")
        } catch { XCTAssertEqual((error as? CKError)?.code, .networkFailure) }
    }

    func testInvitationSavesPrivateParticipantBeforeReadingItsOwnURL() async throws {
        let share = CKShare(recordZoneID: zone)
        var saved = false
        let expected = URL(string: "https://www.icloud.com/share/test-invitation#recipient-token")!
        let result = try await HouseholdSharePreparation.invitation(fetch: { share }, save: { value in
            XCTAssertEqual(value.publicPermission, .none)
            XCTAssertEqual(value.participants.filter { $0.role != .owner }.count, 1)
            XCTAssertEqual(value.participants.first(where: { $0.role != .owner })?.permission, .readWrite)
            saved = true
            return value
        }, url: { value, id in
            XCTAssertTrue(saved)
            XCTAssertTrue(value === share)
            XCTAssertEqual(value.participants.first(where: { $0.role != .owner })?.participantID, id)
            return expected
        })
        XCTAssertEqual(result, expected)
    }

    func testInvitationRefusesMissingURLAndIncompleteSaveReceipt() async {
        for missingParticipant in [false, true] {
            let share = CKShare(recordZoneID: zone)
            do {
                _ = try await HouseholdSharePreparation.invitation(fetch: { share }, save: { value in
                    missingParticipant ? CKShare(recordZoneID: self.zone) : value
                }, url: { _, _ in
                    if missingParticipant { XCTFail("Incomplete save must not deliver a link") }
                    return nil
                })
                XCTFail("Must not fall back to the ordinary share URL")
            } catch { XCTAssertTrue(error is SyncFailure) }
        }
    }

    func testInvitationConflictPreservesRecipientAndOtherInvitations() async throws {
        let first = CKShare(recordZoneID: zone), fresh = CKShare(recordZoneID: zone)
        let other = CKShare.Participant.oneTimeURLParticipant()
        other.permission = .readWrite
        fresh.addParticipant(other)
        var reads = 0
        var recipient: CKShare.Participant.ID?
        _ = try await HouseholdSharePreparation.invitation(fetch: {
            reads += 1
            return reads == 1 ? first : fresh
        }, save: { value in
            if reads == 1 {
                recipient = value.participants.first(where: { $0.role != .owner })?.participantID
                throw CKError(.serverRecordChanged)
            }
            XCTAssertEqual(value.participants.filter { $0.role != .owner }.count, 2)
            XCTAssertTrue(value.participants.contains { $0.participantID == other.participantID })
            XCTAssertTrue(value.participants.contains { $0.participantID == recipient })
            return value
        }, url: { _, id in
            XCTAssertEqual(id, recipient)
            return URL(string: "https://www.icloud.com/share/test-invitation")
        })
        XCTAssertEqual(reads, 2)
    }

    func testInvitationSaveFailureDoesNotReadOrDeliverURL() async {
        let share = CKShare(recordZoneID: zone)
        do {
            _ = try await HouseholdSharePreparation.invitation(fetch: { share },
                save: { _ in throw CKError(.networkFailure) },
                url: { _, _ in XCTFail("No receipt, no invitation"); return nil })
            XCTFail("Must fail")
        } catch { XCTAssertEqual((error as? CKError)?.code, .networkFailure) }
    }

    func testInvitationNeverOpensPublicAccess() async {
        let share = CKShare(recordZoneID: zone)
        share.publicPermission = .readWrite
        do {
            _ = try await HouseholdSharePreparation.invitation(fetch: { share },
                save: { _ in XCTFail("Must not change public sharing"); return share })
            XCTFail("Must fail")
        } catch { XCTAssertTrue(error is SyncFailure) }
    }

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
