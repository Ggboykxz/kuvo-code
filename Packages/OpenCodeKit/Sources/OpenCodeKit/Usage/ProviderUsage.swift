import Foundation

/// How much of an account's plan is left: one meter per limit the provider reports
/// (ChatGPT's 5-hour and weekly windows, Copilot's monthly premium requests, …).
public struct ProviderUsage: Sendable, Equatable, Identifiable {
    /// The integration (provider) ID, like `openai` or `github-copilot`.
    public var id: String
    public var plan: String?
    public var meters: [UsageMeter]
    /// Why there are no meters, when there aren't.
    public var note: String?
    public var updated: Date

    public init(id: String, plan: String? = nil, meters: [UsageMeter] = [], note: String? = nil, updated: Date = Date()) {
        self.id = id
        self.plan = plan
        self.meters = meters
        self.note = note
        self.updated = updated
    }
}

public struct UsageMeter: Sendable, Equatable, Identifiable {
    public var id: String
    /// "5-hour", "Weekly", "Premium requests"
    public var label: String
    /// 0 is nothing used, 1 is the limit.
    public var used: Double
    /// Extra detail, like "212 of 300 left".
    public var detail: String?
    public var resetsAt: Date?

    public init(id: String, label: String, used: Double, detail: String? = nil, resetsAt: Date? = nil) {
        self.id = id
        self.label = label
        self.used = min(max(used, 0), 1)
        self.detail = detail
        self.resetsAt = resetsAt
    }

    public var remaining: Double { 1 - used }
}

/// A stored sign-in, secret included. The engine hands these to local clients;
/// the app only reads them to ask providers about usage, and never refreshes or
/// stores them (refresh tokens rotate, so a refresh here would break the engine's).
public struct CredentialSecret: Decodable, Sendable {
    public var id: String
    public var integrationID: String
    public var active: Bool
    public var value: Value

    public struct Value: Decodable, Sendable {
        public var type: String
        public var methodID: String?
        public var access: String?
        /// Milliseconds since 1970; 0 when it doesn't expire.
        public var expires: Double?
        public var metadata: JSONValue?
    }

    var isExpired: Bool {
        guard let expires = value.expires, expires > 0 else { return false }
        return Date(timeIntervalSince1970: expires / 1000) < Date()
    }
}

/// Asks providers how much of each account's plan is left.
public struct UsageClient: Sendable {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// The providers this can report on.
    public static let supported: Set<String> = ["github-copilot", "openai"]

    public func usage(for credential: CredentialSecret) async -> ProviderUsage? {
        switch credential.integrationID {
        case "github-copilot": return await copilot(credential)
        case "openai": return await chatGPT(credential)
        default: return nil
        }
    }

    // MARK: GitHub Copilot

    /// GitHub's quota endpoint (the one Copilot's editors use, and opencode uses to
    /// check entitlement): monthly premium requests, and chat and completions when limited.
    private func copilot(_ credential: CredentialSecret) async -> ProviderUsage? {
        guard let token = credential.value.access else { return nil }
        let enterprise = credential.value.metadata?["enterpriseUrl"]?.string
            .map { $0.replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        let host = enterprise.map { "https://api.\($0)" } ?? "https://api.github.com"
        var request = URLRequest(url: URL(string: host + "/copilot_internal/user")!)
        request.setValue("token " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        struct Response: Decodable {
            var copilot_plan: String?
            var quota_reset_date_utc: String?
            var quota_snapshots: [String: Snapshot]?
        }
        struct Snapshot: Decodable {
            var unlimited: Bool?
            var percent_remaining: Double?
            var remaining: Double?
            var entitlement: Double?
            var token_based_billing: Bool?
        }

        guard let (data, response) = try? await session.data(for: request) else {
            return ProviderUsage(id: credential.integrationID, note: "Couldn't reach GitHub.")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200, let body = try? JSONDecoder().decode(Response.self, from: data) else {
            return ProviderUsage(id: credential.integrationID, note: "GitHub didn't report usage for this account.")
        }

        let resets = body.quota_reset_date_utc.flatMap { try? Date($0, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) }
            ?? body.quota_reset_date_utc.flatMap { try? Date($0, strategy: .iso8601) }
        let labels = ["premium_interactions": "Premium requests", "chat": "Chat", "completions": "Completions"]
        let meters = ["premium_interactions", "chat", "completions"].compactMap { key -> UsageMeter? in
            guard let snapshot = body.quota_snapshots?[key], snapshot.unlimited != true, let percent = snapshot.percent_remaining else { return nil }
            // Token-billed plans count credits, not requests; a percentage reads better than a credit count.
            let detail: String? = if snapshot.token_based_billing != true, let remaining = snapshot.remaining, let entitlement = snapshot.entitlement {
                "\(Int(remaining)) of \(Int(entitlement)) left"
            } else {
                nil
            }
            return UsageMeter(id: key, label: labels[key] ?? key, used: 1 - percent / 100, detail: detail, resetsAt: resets)
        }
        return ProviderUsage(
            id: credential.integrationID,
            plan: body.copilot_plan.map { $0.prefix(1).uppercased() + $0.dropFirst() },
            meters: meters,
            note: meters.isEmpty ? "No limits on this plan." : nil
        )
    }

    // MARK: ChatGPT

    /// The usage endpoint Codex reads: the 5-hour and weekly windows. It accepts
    /// Codex sign-ins; for "Sign in with ChatGPT" (token sharing) OpenAI doesn't
    /// report plan usage, and the endpoint refuses the token.
    private func chatGPT(_ credential: CredentialSecret) async -> ProviderUsage? {
        guard credential.value.type == "oauth", let token = credential.value.access else { return nil }
        if credential.value.methodID == "chatgpt-token-sharing" {
            return ProviderUsage(id: credential.integrationID, note: "OpenAI doesn't report plan usage for “Sign in with ChatGPT” yet.")
        }
        if credential.isExpired {
            return ProviderUsage(id: credential.integrationID, note: "Updates the next time a model from this account runs.")
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let account = credential.value.metadata?["accountID"]?.string ?? Self.chatGPTAccount(in: token) {
            request.setValue(account, forHTTPHeaderField: "chatgpt-account-id")
        }

        struct Response: Decodable {
            var plan_type: String?
            var rate_limit: Limits?
        }
        struct Limits: Decodable {
            var primary_window: Window?
            var secondary_window: Window?
        }
        struct Window: Decodable {
            var used_percent: Double?
            var limit_window_seconds: Double?
            var reset_at: Double?
            var reset_after_seconds: Double?
        }

        guard let (data, response) = try? await session.data(for: request) else {
            return ProviderUsage(id: credential.integrationID, note: "Couldn't reach ChatGPT.")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200, let body = try? JSONDecoder().decode(Response.self, from: data) else {
            return ProviderUsage(id: credential.integrationID, note: "ChatGPT didn't report usage for this account.")
        }
        let windows = [("primary", body.rate_limit?.primary_window), ("secondary", body.rate_limit?.secondary_window)]
        let meters = windows.compactMap { id, window -> UsageMeter? in
            guard let window, let used = window.used_percent else { return nil }
            let resets = window.reset_at.map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) }
                ?? window.reset_after_seconds.map { Date().addingTimeInterval($0) }
            return UsageMeter(id: id, label: Self.windowName(seconds: window.limit_window_seconds), used: used / 100, resetsAt: resets)
        }
        return ProviderUsage(id: credential.integrationID, plan: body.plan_type?.capitalized, meters: meters)
    }

    /// "5-hour", "Weekly", "2-day"…
    static func windowName(seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "Usage" }
        let hours = Int((seconds / 3600).rounded())
        switch hours {
        case 168: return "Weekly"
        case 24: return "Daily"
        case let h where h < 48: return "\(h)-hour"
        default: return "\(hours / 24)-day"
        }
    }

    /// The ChatGPT account ID inside an access token (a JWT), which the endpoint wants as a header.
    static func chatGPTAccount(in token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let claims = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return claims["https://api.openai.com/auth"]?["chatgpt_account_id"]?.string ?? claims["chatgpt_account_id"]?.string
    }
}
