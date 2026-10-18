import Supabase
import SwiftUI
import UIKit
import UserNotifications

/// Which tab a tapped notification should open.
@MainActor
final class PushRouter: ObservableObject {
    static let shared = PushRouter()
    @Published var destination: OttoTab?
    /// Bumped when a photo notification arrives so the Photos tab can refresh.
    @Published var photoArrivals = 0

    func route(userInfo: [AnyHashable: Any]) {
        switch userInfo["kind"] as? String {
        case "photo": destination = .photos
        case "friend_accepted": destination = .friends
        default: break
        }
    }
}

/// APNs registration: asks iOS for a device token once notifications are allowed and a user is signed in,
/// and stores it server-side so the `send-push` Edge Function can reach this device.
@MainActor
final class PushManager {
    static let shared = PushManager()
    private static let tokenKey = "push.lastToken"

    private var pendingToken: String?
    private var signedIn = false

    #if DEBUG
    private let environment = "sandbox"
    #else
    private let environment = "production"
    #endif

    /// Call whenever the signed-in user changes (nil = signed out) and when the app returns to the foreground.
    func sync(userId: UUID?) async {
        signedIn = userId != nil
        guard userId != nil else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        UIApplication.shared.registerForRemoteNotifications()
        if let pendingToken { await upload(pendingToken) }
    }

    func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        pendingToken = token
        guard signedIn else { return }
        Task { await upload(token) }
    }

    private func upload(_ token: String) async {
        do {
            try await supabase.rpc("register_device_token", params: ["p_token": token, "p_environment": environment]).execute()
            UserDefaults.standard.set(token, forKey: Self.tokenKey)
            pendingToken = nil
            print("[Push] registered device token (\(environment))")
        } catch {
            print("[Push] token registration failed: \(error)")   // retried on next foreground
        }
    }

    /// Before signing out: this device must stop receiving the signed-out user's notifications.
    func unregister() async {
        signedIn = false
        guard let token = UserDefaults.standard.string(forKey: Self.tokenKey) else { return }
        _ = try? await supabase.rpc("unregister_device_token", params: ["p_token": token]).execute()
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        pendingToken = token   // the next sign-in on this device re-registers it
    }

    /// The app is open, so nothing is "unread": clear the badge and the server-side count.
    func markRead() async {
        try? await UNUserNotificationCenter.current().setBadgeCount(0)
        guard signedIn else { return }
        _ = try? await supabase.rpc("mark_notifications_read").execute()
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushManager.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[Push] APNs registration failed: \(error.localizedDescription)")
    }

    /// Show the banner even while the app is open, and refresh the Photos tab.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let kind = notification.request.content.userInfo["kind"] as? String
        if kind == "photo" { await MainActor.run { PushRouter.shared.photoArrivals += 1 } }
        return [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        await MainActor.run { PushRouter.shared.route(userInfo: info) }
    }
}
