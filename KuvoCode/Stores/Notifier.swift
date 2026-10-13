import AppKit
import UserNotifications

/// Tells you when a session finishes or needs your answer while you're in another app, and
/// counts the sessions waiting for you on the Dock icon. Clicking a notification opens the
/// session. macOS asks for permission the first time there's something to tell.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    /// Settings › General: notifications and the Dock badge, on unless turned off.
    static let enabledKey = "notifications.enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Shows a session in the window, for a clicked notification.
    var open: ((String) -> Void)?

    private var isAuthorized: Bool?

    func start() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Posts a notification about `session`, unless you're in the app (its sidebar and tabs
    /// already show it) or notifications are off.
    func notify(session: String, title: String, subtitle: String? = nil, body: String) {
        guard Self.isEnabled, !NSApp.isActive else { return }
        Task {
            guard await authorize() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            if let subtitle { content.subtitle = subtitle }
            content.body = body
            content.sound = .default
            content.threadIdentifier = session
            content.userInfo = ["session": session]
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Takes a session's notifications away once you've looked at it.
    func clear(session: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered.filter { $0.request.content.threadIdentifier == session }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// The number on the Dock icon: sessions that finished while you were elsewhere, or
    /// wait for your answer.
    func setBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = Self.isEnabled && count > 0 ? "\(count)" : nil
    }

    private func authorize() async -> Bool {
        if let isAuthorized { return isAuthorized }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        isAuthorized = granted
        return granted
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let session = response.notification.request.content.userInfo["session"] as? String else { return }
        await MainActor.run {
            NSApp.activate()
            Notifier.shared.open?(session)
        }
    }
}
