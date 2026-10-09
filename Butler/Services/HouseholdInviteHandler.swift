import CloudKit
import SwiftUI
import UIKit

/// Receives household pushes and invitation links. An invitation link: iOS hands the accepted share to the scene, whether the app was
/// already running or is launched by the link.
final class ButlerAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Household changes arrive as silent pushes, so a task given to this person reaches the phone
        // even when the app is closed.
        if HouseholdStore.shared.state != nil { application.registerForRemoteNotifications() }
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
        -> UIBackgroundFetchResult {
        guard HouseholdStore.shared.state != nil else { return .noData }
        await HouseholdService.shared.sync()
        return .newData
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = ButlerSceneDelegate.self
        return configuration
    }
}

final class ButlerSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata { receive(metadata) }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        receive(cloudKitShareMetadata)
    }

    private func receive(_ metadata: CKShare.Metadata) {
        Task { @MainActor in await HouseholdService.shared.accept(metadata) }
    }
}
