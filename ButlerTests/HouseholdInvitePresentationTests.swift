import CloudKit
import LinkPresentation
import UIKit
import XCTest
@testable import Butler

@MainActor final class HouseholdInvitePresentationTests: XCTestCase {
    func testRejectsForeignOrMalformedInvitationInsteadOfInventingHouseholdID() throws {
        let id = UUID(), container = "iCloud.com.anvalar.Butler"
        XCTAssertEqual(try HouseholdInvitationIdentity.householdID(container: container,
            zoneName: "ButlerHouseholdV1-\(id.uuidString)"), id)
        XCTAssertThrowsError(try HouseholdInvitationIdentity.householdID(container: "iCloud.other.app",
            zoneName: "ButlerHouseholdV1-\(id.uuidString)"))
        XCTAssertThrowsError(try HouseholdInvitationIdentity.householdID(container: container, zoneName: "Other-\(id.uuidString)"))
        XCTAssertThrowsError(try HouseholdInvitationIdentity.householdID(container: container, zoneName: "ButlerHouseholdV1-invalid"))
    }

    func testAtomicWriteReportsRootCauseInsteadOfUnrelatedBatchFailure() {
        let item = CKRecord(recordType: "ButlerRevisionV1")
        let control = CKRecord(recordType: "ButlerSyncControlV1")
        XCTAssertThrowsError(try CloudKitSyncTransport.checkSaveResults([
            item.recordID: .failure(CKError(.batchRequestFailed)),
            control.recordID: .failure(CKError(.serverRecordChanged))
        ], records: [item, control])) { error in
            XCTAssertEqual((error as? CKError)?.code, .serverRecordChanged)
        }
        XCTAssertThrowsError(try CloudKitSyncTransport.checkSaveResults([item.recordID: .success(item)], records: [item, control]))
        XCTAssertNoThrow(try CloudKitSyncTransport.checkSaveResults([item.recordID: .success(item), control.recordID: .success(control)], records: [item, control]))
    }

    func testControlRecordNameMeetsCloudKitIDRules() {
        let name = CloudKitSyncTransport.controlRecordName
        XCTAssertFalse(name.isEmpty)
        XCTAssertFalse(name.hasPrefix("_"), "CloudKit rejects reserved record names and aborts the whole write batch")
        XCTAssertLessThanOrEqual(name.utf8.count, 255)
        XCTAssertTrue(name.unicodeScalars.allSatisfy { $0.isASCII })
        XCTAssertNotEqual(name, CKRecordNameZoneWideShare)
        XCTAssertNil(UUID(uuidString: name), "the control fence must not collide with revision IDs")
    }

    func testDirectInvitationOffersPrivateCollaborationWithFamilyPreview() throws {
        let share = CKShare(recordZoneID: .init(zoneName: "test-family"))
        share[CKShare.SystemFieldKey.title] = "测试家庭" as CKRecordValue
        let container = CKContainer(identifier: "iCloud.com.anvalar.Butler")
        let options = HouseholdInvite.invitationOptions
        XCTAssertEqual(options.allowedParticipantAccessOptions, .specifiedRecipientsOnly)
        XCTAssertEqual(options.allowedParticipantPermissionOptions, .readWrite)
        XCTAssertFalse(options.allowsParticipantsToInviteOthers)
        let config = HouseholdInvite.invitationConfiguration(share: share, container: container)
        let metadata = try XCTUnwrap(config.perItemMetadataProvider?(0, .linkPresentationMetadata) as? LPLinkMetadata)
        XCTAssertEqual(metadata.title, "测试家庭")
        XCTAssertNotNil(metadata.imageProvider)
        let restrictions = try XCTUnwrap(config.metadataProvider?(.collaborationModeRestrictions)
            as? [UIActivityViewController.CollaborationModeRestriction])
        XCTAssertEqual(restrictions.count, 1)
        XCTAssertEqual(restrictions.first?.disabledMode, .sendCopy)
        XCTAssertEqual(share.publicPermission, .none)
    }

    func testDirectInvitationRetainsObserverAndReportsSaveFailureOnce() async throws {
        let share = CKShare(recordZoneID: .init(zoneName: "test-family"))
        let reported = expectation(description: "Share save error reaches the page")
        var messages: [String] = []
        let controller = HouseholdInvite.makeInviteController(share: share,
            container: CKContainer(identifier: "iCloud.com.anvalar.Butler")) {
                messages.append($0)
                reported.fulfill()
            }
        let callback = try XCTUnwrap(controller.sharingObserver?.systemSharingUIDidSaveShareBlock)
        callback(share.recordID, .failure(CKError(.networkFailure)))
        await fulfillment(of: [reported], timeout: 2)
        // The activity may report the same error after the CloudKit save callback.
        controller.reportFailure(CKError(.networkFailure))
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("网络"))
        XCTAssertFalse(messages[0].contains("CKError"))
    }

    func testRejectsOldClipboardAndNonCloudKitAddresses() {
        for string in ["http://localhost:5198/projects", "https://localhost/share/token", "https://icloud.com.attacker.test/share/token",
                       "https://evilicloud.com/share/token", "https://example.com/share/token", "file:///tmp/share/token",
                       "https://user:pass@www.icloud.com/share/token", "https://www.icloud.com:8080/share/token", "https://www.icloud.com/share/"] {
            XCTAssertThrowsError(try HouseholdShareLink.validated(URL(string: string)), string)
        }
        XCTAssertThrowsError(try HouseholdShareLink.validated(nil))
    }

    func testPreservesCloudKitLinkRatherThanBuildingOne() throws {
        let url = URL(string: "https://www.icloud.com/share/example-token#example-fragment")!
        XCTAssertEqual(try HouseholdShareLink.validated(url), url)
        XCTAssertNoThrow(try HouseholdShareLink.validated(URL(string: "https://www.icloud.com.cn/share/example-token")))
    }

    func testOnlyTheSameZonesSystemShareIsSkippedDuringDataSync() {
        let zone = CKRecordZone.ID(zoneName: "household")
        XCTAssertTrue(CloudKitSyncTransport.isZoneShareMetadata(CKShare(recordZoneID: zone), in: zone))
        XCTAssertFalse(CloudKitSyncTransport.isZoneShareMetadata(CKShare(recordZoneID: .init(zoneName: "another")), in: zone))
        XCTAssertFalse(CloudKitSyncTransport.isZoneShareMetadata(CKRecord(recordType: "Unexpected", recordID: .init(recordName: "unknown", zoneID: zone)), in: zone))
        XCTAssertFalse(CloudKitSyncTransport.isZoneShareMetadata(CKRecord(recordType: "ButlerRevisionV1", recordID: .init(recordName: UUID().uuidString, zoneID: zone)), in: zone))
    }

    func testSystemDelegateSurvivesFactoryAndReportsSaveFailure() throws {
        let share = CKShare(recordZoneID: .init(zoneName: "test-family"))
        share[CKShare.SystemFieldKey.title] = "测试家庭" as CKRecordValue
        var failure: String?
        let controller = HouseholdInvite.makeController(share: share, container: CKContainer(identifier: "iCloud.com.anvalar.Butler"),
            onFailure: { failure = $0 })
        let delegate = try XCTUnwrap(controller.delegate)
        XCTAssertEqual(delegate.itemTitle(for: controller), "测试家庭")
        XCTAssertEqual(controller.availablePermissions, [.allowPrivate, .allowReadWrite])
        delegate.cloudSharingController(controller, failedToSaveShareWithError: CKError(.networkFailure))
        XCTAssertTrue(failure?.contains("没有复制成功") == true)
        XCTAssertTrue(failure?.contains("网络") == true)
        XCTAssertFalse(failure?.contains("CKError") == true)
    }
}
