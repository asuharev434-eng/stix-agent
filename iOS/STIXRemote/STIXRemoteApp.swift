import SwiftUI
import UserNotifications

@MainActor
private final class RemoteNotificationBridge {
    static let shared = RemoteNotificationBridge()
    weak var store: RemoteChatStore?
}

private final class RemoteAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            await RemoteNotificationBridge.shared.store?.refresh()
            completionHandler(.newData)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@main
struct STIXRemoteApp: App {
    @UIApplicationDelegateAdaptor(RemoteAppDelegate.self) private var delegate
    @StateObject private var store = RemoteChatStore()

    var body: some Scene {
        WindowGroup {
            Group {
                if store.isPaired || store.offlineMode { RemoteChatView() }
                else { PairingView() }
            }
            .environmentObject(store)
            .task {
                RemoteNotificationBridge.shared.store = store
                UNUserNotificationCenter.current().delegate = delegate
            }
            .tint(Color(red: 0.16, green: 0.42, blue: 0.96))
            .task { await store.start() }
        }
    }
}
