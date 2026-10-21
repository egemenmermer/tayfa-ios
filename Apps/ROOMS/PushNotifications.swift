import UIKit
import UserNotifications

/// Mention and direct-message alerts. The device token is attached to the signed-in session;
/// tapping an alert opens its conversation once the channel catalog contains it.
@MainActor final class PushNotifications: NSObject {
    static let shared = PushNotifications()
    weak var model: RoomsModel? { didSet { deliverPendingToken() } }
    private(set) var pendingChannelID: String?
    private var deviceToken: String?

    /// Asks once after sign-in; a denial leaves the app fully usable without alerts.
    func enable() async {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: UIApplication.shared.registerForRemoteNotifications()
        default: break
        }
    }
    func didRegister(_ token: Data) {
        deviceToken = token.map { String(format: "%02x", $0) }.joined()
        deliverPendingToken()
    }
    func deliverPendingToken() {
        guard let deviceToken, let model else { return }
        Task { await model.subscribePush(deviceToken: deviceToken) }
    }
    func consumePendingChannel() -> String? { defer { pendingChannelID = nil }; return pendingChannelID }
    fileprivate func open(channelID: String) {
        pendingChannelID = channelID
        model?.openPendingNotification()
    }
    fileprivate func isShowing(channelID: String) -> Bool {
        UIApplication.shared.applicationState == .active && model?.chat.selected?.id == channelID
    }
}

extension PushNotifications: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let channelID = notification.request.content.userInfo["channelId"] as? String
        let showing = await MainActor.run { channelID.map { PushNotifications.shared.isShowing(channelID: $0) } ?? false }
        return showing ? [] : [.banner, .list, .sound]
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let channelID = response.notification.request.content.userInfo["channelId"] as? String,
              channelID.count <= 64, channelID.allSatisfy({ $0.isLetter || $0.isNumber }) else { return }
        await MainActor.run { PushNotifications.shared.open(channelID: channelID) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Must be set before launch completes so a tap that cold-starts the app is delivered.
        UNUserNotificationCenter.current().delegate = PushNotifications.shared
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotifications.shared.didRegister(deviceToken)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}
}
