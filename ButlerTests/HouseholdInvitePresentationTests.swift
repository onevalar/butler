import CloudKit
import LinkPresentation
import UIKit
import XCTest
@testable import Butler

@MainActor final class HouseholdInvitePresentationTests: XCTestCase {
    func testAppInvitationPreservesAppleTokenQueryAndFragment() throws {
        for text in ["https://www.icloud.com.cn/share/test-invite",
                     "https://www.icloud.com/share/test-invite?value=a%2Bb#family%20name"] {
            let original = try XCTUnwrap(URL(string: text))
            let link = try HouseholdShareLink.applicationURL(for: original)
            XCTAssertEqual(link.scheme, HouseholdShareLink.appScheme)
            XCTAssertEqual(try HouseholdShareLink.cloudURL(from: link), original)
            XCTAssertEqual(try HouseholdShareLink.cloudURL(from: original), original)
            let item = HouseholdInvitationItem(url: link, title: "测试家庭")
            let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
            for activity: UIActivity.ActivityType? in [.copyToPasteboard, .message, nil] {
                XCTAssertEqual(item.activityViewController(controller, itemForActivityType: activity) as? URL, link)
            }
        }
    }

    func testAppInvitationRejectsAmbiguousAndForeignTargets() throws {
        let good = "https%3A%2F%2Fwww.icloud.com.cn%2Fshare%2Ftest-invite"
        for text in ["com.anvalar.butler://family/join?invitation=https://attacker.test/share/token",
                     "com.anvalar.butler://family/join?invitation=\(good)&invitation=\(good)",
                     "com.anvalar.butler://family/join?invitation=\(good)&other=1",
                     "com.anvalar.butler://other/join?invitation=\(good)",
                     "com.anvalar.butler://family/delete?invitation=\(good)",
                     "com.anvalar.butler://user@family/join?invitation=\(good)",
                     "com.anvalar.butler://family:80/join?invitation=\(good)",
                     "com.anvalar.butler://family/join?invitation=\(good)#extra",
                     "com.anvalar.butler://family/join?invitation=",
                     "com.anvalar.butler://family/join"] {
            XCTAssertThrowsError(try HouseholdShareLink.cloudURL(from: XCTUnwrap(URL(string: text))), text)
        }
    }

    func testAppRegistersItsFamilyInvitationSchemeAlongsideWidgets() throws {
        let entries = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = entries.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains(HouseholdShareLink.appScheme))
        XCTAssertTrue(schemes.contains("butler"))
    }

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

    func testCopyAndSocialSharingUseTheExactSavedInvitationURL() throws {
        let url = URL(string: "https://www.icloud.com/share/test-invite#recipient-token")!
        let item = HouseholdInvitationItem(url: url, title: "测试家庭")
        let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        XCTAssertEqual(item.activityViewControllerPlaceholderItem(controller) as? URL, url)
        for activity: UIActivity.ActivityType? in [.copyToPasteboard, .message, nil] {
            XCTAssertEqual(item.activityViewController(controller, itemForActivityType: activity) as? URL, url)
        }
        let metadata = try XCTUnwrap(item.activityViewControllerLinkMetadata(controller))
        XCTAssertEqual(metadata.title, "加入「测试家庭」")
        XCTAssertEqual(metadata.url, url)
        XCTAssertNotNil(metadata.iconProvider)
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
