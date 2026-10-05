import CatonCore
import Foundation
import UserNotifications

/// macOS banners for Needs me. Notification Center requires a bundled app,
/// so under `swift run` this does nothing.
@MainActor
final class Banners: NSObject, UNUserNotificationCenterDelegate {
    /// Called with the thread a clicked banner names, or nil for a summary.
    var onOpen: ((String?) -> Void)?
    private var authorized = false

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func start() {
        guard let center else { return }
        center.delegate = self
        Task {
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    func show(_ decision: AlertDecision) {
        guard let center, authorized else { return }
        for item in decision.banners {
            let content = UNMutableNotificationContent()
            content.title = item.classification.badge.title
            content.subtitle = item.thread.reference
            content.body = item.thread.title
            content.threadIdentifier = "needs-me"
            content.userInfo = ["thread": item.id.key]
            // One banner per row: newer activity replaces the older banner.
            center.add(UNNotificationRequest(identifier: item.id.key, content: content, trigger: nil))
        }
        if decision.overflow > 0 {
            let content = UNMutableNotificationContent()
            content.title = "\(decision.overflow) more need you"
            content.threadIdentifier = "needs-me"
            center.add(UNNotificationRequest(identifier: "needs-me-summary", content: content, trigger: nil))
        }
    }

    /// The morning digest; clicking it opens the panel on Needs me.
    func showDigest(_ message: String) {
        guard let center, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Good morning"
        content.body = message
        content.threadIdentifier = "digest"
        center.add(UNNotificationRequest(identifier: "digest", content: content, trigger: nil))
    }

    /// Takes back banners for threads that no longer need the user.
    func withdraw(_ ids: [ItemID]) {
        center?.removeDeliveredNotifications(withIdentifiers: ids.map(\.key))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let thread = response.notification.request.content.userInfo["thread"] as? String
        await MainActor.run { onOpen?(thread) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
