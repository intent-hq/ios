#if os(iOS)
import UIKit

final class RemoteNotificationsAppDelegate: NSObject, UIApplicationDelegate {
    func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRelayController.shared.deviceTokenChanged(deviceToken)
    }

    func application(_: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        AppLog.notifications.warning("[PushRelay] Remote notification registration failed: \(error)")
    }
}
#endif
