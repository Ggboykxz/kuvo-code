import AppKit
import UserNotifications

/// Tells you when a session finishes or needs your answer while you're in another app, and
/// counts the sessions waiting for you on the Dock icon. Clicking a notification opens the
/// session; a permission request's buttons answer it, and a finished one's Reply writes back,
/// without opening the app. macOS asks for permission the first time there's something to tell.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    /// Settings › Notifications: notifications, their sound and the Dock badge, each on unless
    /// turned off.
    static let enabledKey = "notifications.enabled"
    static let soundKey = "notifications.sound"
    static let badgeKey = "notifications.badge"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var playsSound: Bool {
        UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true
    }

    static var showsBadge: Bool {
        UserDefaults.standard.object(forKey: badgeKey) as? Bool ?? true
    }

    /// Shows a session in the window, for a clicked notification.
    var open: ((String) -> Void)?
    /// Answers a permission request from its notification: the request's session, the request,
    /// and the decision.
    var answer: ((String, String, PermissionAnswer) -> Void)?
    /// Sends what you wrote in a notification's Reply to its session.
    var reply: ((String, String) -> Void)?

    enum PermissionAnswer: String, CaseIterable {
        case once, always, reject

        var title: String {
            switch self {
            case .once: "Allow"
            case .always: "Always Allow"
            case .reject: "Deny"
            }
        }
    }

    private static let permissionCategory = "permission"
    private static let replyCategory = "reply"
    private nonisolated static let replyAction = "reply"
    private var isAuthorized: Bool?

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.permissionCategory, actions: PermissionAnswer.allCases.map { answer in
                UNNotificationAction(identifier: answer.rawValue, title: answer.title, options: answer == .reject ? [.destructive] : [])
            }, intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.replyCategory, actions: [
                UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Message"),
            ], intentIdentifiers: []),
        ])
    }

    /// Posts a notification about `session`, unless you're in the app (its sidebar and tabs
    /// already show it) or notifications are off.
    /// A `permission` (its session, and the request) gets the buttons that answer it; one that
    /// `replies` gets Reply, to write back to the session from the notification.
    func notify(session: String, title: String, subtitle: String? = nil, body: String, permission: (session: String, request: String)? = nil, replies: Bool = false) {
        guard Self.isEnabled, !NSApp.isActive else { return }
        Task {
            guard await authorize() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            if let subtitle { content.subtitle = subtitle }
            content.body = body
            if Self.playsSound { content.sound = .default }
            content.threadIdentifier = session
            content.userInfo = ["session": session]
            if let permission {
                content.categoryIdentifier = Self.permissionCategory
                content.userInfo["requestSession"] = permission.session
                content.userInfo["request"] = permission.request
            } else if replies, !session.isEmpty {
                content.categoryIdentifier = Self.replyCategory
            }
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Takes a session's notifications away once you've looked at it.
    func clear(session: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications()
            let ids = delivered.filter { $0.request.content.threadIdentifier == session }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// Takes a request's notification away once it's answered (in the app, say).
    func clear(request: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications()
            let ids = delivered.filter { $0.request.content.userInfo["request"] as? String == request }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// The number on the Dock icon: sessions that finished while you were elsewhere, or
    /// wait for your answer.
    func setBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = Self.showsBadge && count > 0 ? "\(count)" : nil
    }

    private func authorize() async -> Bool {
        if let isAuthorized { return isAuthorized }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        isAuthorized = granted
        return granted
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let answer = PermissionAnswer(rawValue: response.actionIdentifier), let session = info["requestSession"] as? String, let request = info["request"] as? String {
            await MainActor.run { Notifier.shared.answer?(session, request, answer) }
            return
        }
        guard let session = info["session"] as? String else { return }
        if response.actionIdentifier == Self.replyAction, let text = (response as? UNTextInputNotificationResponse)?.userText {
            await MainActor.run { Notifier.shared.reply?(session, text) }
            return
        }
        await MainActor.run {
            NSApp.activate()
            if !session.isEmpty { Notifier.shared.open?(session) }
        }
    }
}
