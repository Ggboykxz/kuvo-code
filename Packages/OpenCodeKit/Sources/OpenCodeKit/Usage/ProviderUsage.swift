// Usage providers adapted from OpenUsage (https://github.com/robinebers/openusage),
// MIT License, Copyright (c) 2026 Robin Ebers. See THIRD_PARTY_NOTICES.md.

import Foundation

/// How much of a subscription is left: one meter per limit the provider reports
/// (Codex's 5-hour and weekly windows, Claude's session and weekly, Copilot's credits…).
public struct ProviderUsage: Sendable, Equatable, Identifiable {
    /// `codex`, `claude`, `github-copilot`, `opencode-go`
    public var id: String
    public var name: String
    /// The provider logo to show (models.dev ID).
    public var logo: String
    public var plan: String?
    public var meters: [UsageMeter]
    /// Figures without a limit to fill a bar against: credits, extra usage.
    public var facts: [UsageFact]
    /// Why the meters are missing or may be stale, in plain words.
    public var note: String?
    public var updated: Date

    public init(id: String, name: String, logo: String, plan: String? = nil, meters: [UsageMeter] = [], facts: [UsageFact] = [], note: String? = nil, updated: Date = Date()) {
        self.id = id
        self.name = name
        self.logo = logo
        self.plan = plan
        self.meters = meters
        self.facts = facts
        self.note = note
        self.updated = updated
    }
}

public struct UsageMeter: Sendable, Equatable, Identifiable {
    public var id: String
    /// "Session", "Weekly", "Credits"
    public var label: String
    /// 0 is nothing used, 1 is the limit.
    public var used: Double
    public var resetsAt: Date?
    /// The window's length, when the provider says ("5 hours", "7 days").
    public var window: TimeInterval?
    /// Amounts behind the percentage, like "$12.40 of $50.00".
    public var detail: String?

    public init(id: String, label: String, used: Double, resetsAt: Date? = nil, window: TimeInterval? = nil, detail: String? = nil) {
        self.id = id
        self.label = label
        self.used = min(max(used.isFinite ? used : 0, 0), 1)
        self.resetsAt = resetsAt
        self.window = window
        self.detail = detail
    }

    /// From a 0–100 percentage.
    init(id: String, label: String, percentUsed: Double, resetsAt: Date? = nil, window: TimeInterval? = nil, detail: String? = nil) {
        self.init(id: id, label: label, used: UsageParse.clampPercent(percentUsed) / 100, resetsAt: resetsAt, window: window, detail: detail)
    }

    public var remaining: Double { 1 - used }
}

public struct UsageFact: Sendable, Equatable, Identifiable {
    public var label: String
    public var value: String

    public var id: String { label }
}

/// What usage reading may do beyond the app's own accounts.
public struct UsageOptions: Sendable, Equatable {
    /// Read logins other tools keep in the Keychain (Claude Code, Codex, gh). macOS asks the
    /// first time; off until the person turns it on.
    public var readsKeychain: Bool
    /// Renew an expired login of another tool, writing the new tokens back where that tool
    /// keeps them (as OpenUsage does). Off until the person turns it on.
    public var renewsLogins: Bool
    /// The login shell's environment, for CODEX_HOME and CLAUDE_CONFIG_DIR.
    public var environment: [String: String]

    public init(readsKeychain: Bool = false, renewsLogins: Bool = false, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.readsKeychain = readsKeychain
        self.renewsLogins = renewsLogins
        self.environment = environment
    }
}

/// A stored sign-in, secret included. The engine hands these to local clients; usage
/// reading keeps them in memory only.
public struct CredentialSecret: Decodable, Sendable {
    public var id: String
    public var integrationID: String
    public var active: Bool
    public var value: Value

    public struct Value: Decodable, Sendable {
        public var type: String
        public var methodID: String?
        public var access: String?
        public var key: String?
        /// Milliseconds since 1970; 0 when it doesn't expire.
        public var expires: Double?
        public var metadata: JSONValue?
    }
}

/// Reads every subscription it can find, in parallel.
public struct UsageService: Sendable {
    let http: UsageHTTP

    public init(session: URLSession = .shared) {
        http = UsageHTTP(session: session)
    }

    /// One report per provider that has a login, in a stable order.
    public func usage(engine credentials: [CredentialSecret], options: UsageOptions) async -> [ProviderUsage] {
        let active = credentials.filter(\.active)
        let http = http
        let readers: [@Sendable () async -> ProviderUsage?] = [
            { await CodexUsage(http: http, options: options).read(engine: active) },
            { await ClaudeUsage(http: http, options: options).read() },
            { await CopilotUsage(http: http, options: options).read(engine: active) },
            { await OpenCodeGoUsage(http: http).read(engine: active) },
        ]
        let results = await withTaskGroup(of: (Int, ProviderUsage?).self) { group in
            for (index, read) in readers.enumerated() {
                group.addTask { (index, await read()) }
            }
            var results: [(Int, ProviderUsage?)] = []
            for await result in group { results.append(result) }
            return results
        }
        return results.sorted { $0.0 < $1.0 }.compactMap(\.1)
    }
}

/// Plain-words messages shared by providers.
enum UsageText {
    static let unreachable = "Couldn't reach the service. Trying again shortly."

    static func failed(_ status: Int) -> String {
        "The service didn't answer (\(status)). Trying again shortly."
    }
}
