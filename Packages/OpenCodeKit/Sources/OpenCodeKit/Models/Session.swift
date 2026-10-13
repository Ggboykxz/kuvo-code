import Foundation

/// A conversation with an agent, in one project folder.
public struct Session: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var parentID: String?
    public var projectID: String
    public var agent: String?
    public var model: ModelRef?
    /// Total cost so far, in US dollars.
    public var cost: Double
    public var tokens: TokenUsage
    public var outcome: Outcome?
    public var time: Time
    public var title: String?
    public var location: Location
    public var subpath: String?
    /// Rules on top of the agent's own, for this session. Later rules win.
    public var permissions: [PermissionRule]?

    public struct Time: Codable, Sendable, Hashable {
        public var created: Milliseconds
        public var updated: Milliseconds
        /// When the last run finished.
        public var idle: Milliseconds?
        /// When someone last looked at it. Unread means `idle > viewed`.
        public var viewed: Milliseconds?
        public var archived: Milliseconds?
    }

    public enum Outcome: String, Codable, Sendable {
        case succeeded, failed, interrupted
    }

    public var isUnread: Bool {
        guard let idle = time.idle else { return false }
        return idle > (time.viewed ?? 0)
    }
}

/// "For this action on these resources: allow, deny, or ask." The engine checks the
/// agent's rules, then the session's, then saved "always allow" answers; the last match wins.
public struct PermissionRule: Codable, Sendable, Hashable {
    public var action: String
    public var resource: String
    public var effect: Effect

    public enum Effect: String, Codable, Sendable {
        case allow, deny, ask
    }

    public init(action: String, resource: String = "*", effect: Effect) {
        self.action = action
        self.resource = resource
        self.effect = effect
    }
}

/// A queued input that hasn't reached the agent yet.
public struct InboxItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var sessionID: String
    public var type: String
    public var payload: JSONValue
    public var delivery: Delivery

    public enum Delivery: String, Codable, Sendable {
        /// Delivered at the next step of the current run.
        case steer
        /// Waits until the run finishes.
        case queue
    }

    public var text: String? { payload["text"]?.string }
}

/// What the agent is waiting for permission to do.
public struct PermissionRequest: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var sessionID: String
    /// The kind of access: `edit`, `shell`, `read`, `external_directory`, …
    public var action: String
    /// What it applies to: paths, commands, directory patterns.
    public var resources: [String]
    /// The patterns "Always allow" would save.
    public var save: [String]?
    public var metadata: JSONValue?
    public var source: Source?
    public var message: String?

    public struct Source: Codable, Sendable, Hashable {
        public var type: String
        public var messageID: String
        public var id: String
    }

    public enum Decision: String, Codable, Sendable {
        case once, always, reject
    }

    /// File changes, for edit/write/patch requests.
    public var diffs: [FileDiff] {
        (try? metadata?["files"]?.decode(as: [FileDiff].self)) ?? []
    }
}
