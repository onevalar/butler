import CloudKit
import LinkPresentation
import UIKit

/// A CloudKit URL is supplied by Apple. Never fall back to a browser address or clipboard.
enum HouseholdShareLink {
    static func validated(_ url: URL?) throws -> URL {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", let host = components.host?.lowercased(),
              components.user == nil, components.password == nil, components.port == nil,
              ["icloud.com", "icloud.com.cn"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              components.path.hasPrefix("/share/"), components.path.count > "/share/".count else {
            throw SyncFailure("iCloud 尚未返回有效的家庭邀请链接，请稍后重新点击“邀请家人”。")
        }
        return url
    }
}

@MainActor enum HouseholdInvite {
    enum Purpose { case invite, manage }

    static func presentInvitation(url: URL, title: String) throws {
        let url = try HouseholdShareLink.validated(url)
        guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive }).flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController else {
            throw SyncFailure("暂时无法打开分享，请返回家庭页面后重试。")
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let controller = UIActivityViewController(activityItems: [HouseholdInvitationItem(url: url, title: title)], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 20, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
        ChatDiagnostics.log("household single-use invitation presented")
    }

    static func presentManagement(share: CKShare, container: CKContainer,
                        onFailure: @escaping (String) -> Void) throws {
        _ = try HouseholdShareLink.validated(share.url)
        guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive })
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else {
            throw SyncFailure("暂时无法打开邀请页面，请返回家庭页面后再试。")
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let controller = makeController(share: share, container: container, onFailure: onFailure)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 20, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        ChatDiagnostics.log("household sharing presented; purpose=manage; validCloudURL=true; public=\(share.publicPermission.rawValue)")
        top.present(controller, animated: true)
    }

    static func makeController(share: CKShare, container: CKContainer,
                               onFailure: @escaping (String) -> Void) -> UICloudSharingController {
        let controller = HouseholdSharingController(share: share, container: container)
        let observer = HouseholdSharingObserver(title: (share[CKShare.SystemFieldKey.title] as? String) ?? "小当家的家庭",
                                                onFailure: onFailure)
        controller.retainedObserver = observer
        controller.delegate = observer
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        return controller
    }
}

@MainActor final class HouseholdInvitationItem: NSObject, UIActivityItemSource {
    let url: URL
    let title: String
    init(url: URL, title: String) { self.url = url; self.title = title }
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { url }
    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { url }
    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = "加入「\(title)」"
        metadata.url = url
        if let image = UIImage(systemName: "house.fill") { metadata.iconProvider = NSItemProvider(object: image) }
        return metadata
    }
}

/// UIKit's delegate is weak; the presented controller owns it until dismissal.
@MainActor private final class HouseholdSharingController: UICloudSharingController {
    var retainedObserver: HouseholdSharingObserver?
}

@MainActor private final class HouseholdSharingObserver: NSObject, UICloudSharingControllerDelegate {
    let title: String
    let onFailure: (String) -> Void
    init(title: String, onFailure: @escaping (String) -> Void) {
        self.title = title; self.onFailure = onFailure
    }

    func itemTitle(for csc: UICloudSharingController) -> String? { title }

    func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
        // Do not log invitation tokens, participant identities or clipboard contents.
        ChatDiagnostics.log("household invite system-save failed: \(ChatDiagnostics.describe(error))")
        let message = "邀请未能保存，链接可能没有复制成功。" + HouseholdSharePreparation.message(for: error)
        if csc.presentingViewController != nil {
            csc.dismiss(animated: true) { [onFailure] in onFailure(message) }
        } else { onFailure(message) }
    }

    func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
        let valid = (try? HouseholdShareLink.validated(csc.share?.url)) != nil
        ChatDiagnostics.log("household invite system-save completed; validCloudURL=\(valid)")
        // Saving a CKShare does not prove the selected activity copied or sent its link.
        if !valid {
            let message = "邀请设置已保存，但 iCloud 尚未返回有效链接。请重新打开“邀请家人”后再试。"
            if csc.presentingViewController != nil {
                csc.dismiss(animated: true) { [onFailure] in onFailure(message) }
            } else { onFailure(message) }
        }
    }

    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        ChatDiagnostics.log("household invite sharing stopped through system UI")
    }
}
