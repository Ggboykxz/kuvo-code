import AppKit
import KuvoLink
import UserNotifications

/// Tells you when a session finishes or needs your answer while you're in another app, and
/// counts the sessions waiting for you on the Dock icon. Clicking a notification opens the
/// session; a permission request's buttons answer it, a question's its choices, and a finished
/// one's Reply writes back, without opening the app. macOS asks for permission the first time there's something to tell.
/// What's about a session or a chat goes to your paired phones too (see PhoneLink).
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
    /// Answers a question from its notification: the question's session, the question, its field
    /// and the answer.
    var answerQuestion: ((String, String, String, String) -> Void)?
    /// Sends a notification to your paired phones, about a session on the machine it names, if
    /// one (set by AppModel).
    var toPhones: ((Notice, String?) -> Void)?

    /// What goes to your phones too, as their notification (KuvoLink's PROTOCOL.md,
    /// "Notifications"): nil for what's only about this Mac.
    struct Push {
        var category: Notice.Category
        /// A group chat's: its id, for the session's place.
        var group: String?
        /// The permission or form it asks you to answer, and the session asking (a subagent's,
        /// maybe).
        var request: (session: String, id: String)?
        /// The browser ask.
        var ask: String?
        /// The machine whose engine it happened on, which tells your phones itself while this Mac
        /// isn't there.
        var machine: String?

        init(_ category: Notice.Category, group: String? = nil, request: (session: String, id: String)? = nil, ask: String? = nil, machine: String? = nil) {
            self.category = category
            self.group = group
            self.request = request
            self.ask = ask
            self.machine = machine
        }
    }

    /// A question asked with one field: its choices become the notification's buttons, and one
    /// you can answer in words gets a field for that.
    struct Question {
        let session: String
        let form: String
        let key: String
        let text: String
        let choices: [(value: String, label: String)]
        let allowsText: Bool
    }

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
    private nonisolated static let answerAction = "answer"
    private nonisolated static let choicePrefix = "choice."
    /// The categories every notification can have, and each waiting question's own.
    private var categories: [UNNotificationCategory] = []
    private var questionCategories: [String: UNNotificationCategory] = [:]
    private var isAuthorized: Bool?

    /// `text` with what looks like a secret's value as dots: after a name like token, key, secret,
    /// password or Authorization (Bearer), and long runs of letters and digits like a key's.
    nonisolated static func masked(_ text: String) -> String {
        var text = text
        let named = #"(?i)((?:token|api[_-]?key|secret|password|passwd|authorization)["']?\s*[:=]\s*["']?(?:bearer\s+|basic\s+)?|bearer\s+)[^\s"'&;]{6,}"#
        text = text.replacingOccurrences(of: named, with: "$1•••", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\b[A-Za-z0-9_\-]{32,}\b"#, with: "•••", options: .regularExpression)
        return text
    }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        categories = [
            // Allowing needs the Mac unlocked: from the lock screen it asks for your password first.
            UNNotificationCategory(identifier: Self.permissionCategory, actions: PermissionAnswer.allCases.map { answer in
                UNNotificationAction(identifier: answer.rawValue, title: answer.title, options: answer == .reject ? [.destructive] : [.authenticationRequired])
            }, intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.replyCategory, actions: [
                UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Message"),
            ], intentIdentifiers: []),
        ]
        center.setNotificationCategories(Set(categories))
    }

    /// A question's own category: its choices, and a field to answer in words if it takes one.
    private func category(for question: Question) -> String {
        let identifier = "question.\(question.form)"
        var actions: [UNNotificationAction] = question.choices.prefix(4).enumerated().map { index, choice in
            UNNotificationAction(identifier: Self.choicePrefix + "\(index)", title: choice.label, options: [])
        }
        if question.allowsText {
            actions.append(UNTextInputNotificationAction(identifier: Self.answerAction, title: question.choices.isEmpty ? "Answer" : "Other…", options: [],
                                                         textInputButtonTitle: "Send", textInputPlaceholder: "Your answer"))
        }
        questionCategories[question.form] = UNNotificationCategory(identifier: identifier, actions: actions, intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories + questionCategories.values))
        return identifier
    }

    /// Posts a notification about `session`, unless you're in the app (its sidebar and tabs
    /// already show it) or notifications are off.
    /// A `permission` (its session, and the request) gets the buttons that answer it; one that
    /// `replies` gets Reply, to write back to the session from the notification; a `question`, its
    /// choices. With `push`, it goes to your phones too, whether the Mac shows it or not.
    func notify(session: String, title: String, subtitle: String? = nil, body: String, permission: (session: String, request: String)? = nil,
                question: Question? = nil, replies: Bool = false, push: Push? = nil) {
        // What looks like a secret in a command or reply (a token, a key) isn't shown: these stay
        // in Notification Center, and a phone's lock screen.
        let body = Self.masked(body)
        if let push { send(push, session: session, title: title, subtitle: subtitle, body: body) }
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
            // A browser's ask: cleared as it's answered, or goes unanswered.
            if let ask = push?.ask { content.userInfo["ask"] = ask }
            if let permission {
                content.categoryIdentifier = Self.permissionCategory
                content.userInfo["requestSession"] = permission.session
                content.userInfo["request"] = permission.request
            } else if let question {
                content.categoryIdentifier = category(for: question)
                content.userInfo["requestSession"] = question.session
                content.userInfo["form"] = question.form
                content.userInfo["key"] = question.key
                content.userInfo["choices"] = question.choices.prefix(4).map(\.value)
            } else if replies, !session.isEmpty {
                content.categoryIdentifier = Self.replyCategory
            }
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func send(_ push: Push, session: String, title: String, subtitle: String?, body: String) {
        guard let toPhones else { return }
        var data = push.group.map { ["group": $0] } ?? (session.isEmpty ? [:] : ["session": session])
        if let request = push.request {
            data["request"] = request.id
            if request.session != session { data["requestSession"] = request.session }
        }
        if let ask = push.ask { data["ask"] = ask }
        toPhones(Notice(title: title, subtitle: subtitle, body: body, category: push.category, thread: push.group ?? (session.isEmpty ? push.ask ?? "" : session), data: data),
                 push.machine)
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

    /// Takes a request's or a question's notification away once it's answered (in the app, say).
    func clear(request: String) {
        if questionCategories.removeValue(forKey: request) != nil {
            UNUserNotificationCenter.current().setNotificationCategories(Set(categories + questionCategories.values))
        }
        Task {
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications()
            let ids = delivered.filter { notification in
                let info = notification.request.content.userInfo
                return info["request"] as? String == request || info["form"] as? String == request || info["ask"] as? String == request
            }
            .map(\.request.identifier)
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
        if let form = info["form"] as? String, let session = info["requestSession"] as? String, let key = info["key"] as? String {
            let action = response.actionIdentifier
            var answer: String?
            if action.hasPrefix(Self.choicePrefix), let index = Int(action.dropFirst(Self.choicePrefix.count)), let values = info["choices"] as? [String], values.indices.contains(index) {
                answer = values[index]
            } else if action == Self.answerAction {
                answer = (response as? UNTextInputNotificationResponse)?.userText
            }
            if let answer {
                await MainActor.run { Notifier.shared.answerQuestion?(session, form, key, answer) }
                return
            }
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
