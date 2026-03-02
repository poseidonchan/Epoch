#if os(iOS)
import EpochCore
import SwiftUI
import UIKit
import UserNotifications

final class AppNotificationRouter: NSObject, ObservableObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @Published var pendingURL: URL?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    @MainActor
    func consumePendingURL(_ url: URL) {
        if pendingURL == url {
            pendingURL = nil
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        _ = center
        _ = notification
        return [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        _ = center
        guard let deepLink = Self.deepLinkURL(from: response.notification.request.content.userInfo) else { return }
        await MainActor.run {
            self.pendingURL = deepLink
        }
    }

    nonisolated private static func deepLinkURL(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let raw = userInfo["deepLink"] as? String else { return nil }
        return URL(string: raw)
    }
}

@main
struct EpochApp: App {
    @StateObject private var store = AppStore()
    @UIApplicationDelegateAdaptor(AppNotificationRouter.self) private var notificationRouter

    var body: some Scene {
        WindowGroup {
            RootContainerView()
                .environmentObject(store)
                .environmentObject(notificationRouter)
                .onOpenURL { url in
                    store.handleDeepLink(url)
                }
        }
    }
}
#endif
