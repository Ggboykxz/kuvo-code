// Adapted from OpenUsage's Copilot provider (https://github.com/robinebers/openusage),
// MIT License, Copyright (c) 2026 Robin Ebers. See THIRD_PARTY_NOTICES.md.

import Foundation

/// GitHub Copilot quotas (premium requests or AI credits, chat, completions), from the
/// Copilot sign-in in the app, an editor's Copilot login, or the gh CLI.
struct CopilotUsage: Sendable {
    let http: UsageHTTP
    let options: UsageOptions

    static let editorPaths = ["~/.config/github-copilot/apps.json", "~/.config/github-copilot/hosts.json"]
    static let ghHostsPath = "~/.config/gh/hosts.yml"
    static let ghKeychainService = "gh:github.com"

    struct Token {
        var value: String
        /// `https://api.<host>` for GitHub Enterprise; github.com otherwise.
        var apiBase: String
    }

    func read(engine credentials: [CredentialSecret]) async -> ProviderUsage? {
        let tokens = await loadTokens(engine: credentials)
        guard !tokens.isEmpty else { return nil }

        var sawAuthFailure = false
        for token in tokens {
            do {
                let response = try await fetch(token)
                if response.isAuthFailure {
                    sawAuthFailure = true
                    continue
                }
                guard response.isSuccess, let body = UsageParse.json(response.body) else {
                    return report(note: UsageText.failed(response.status))
                }
                return Self.map(body: body)
            } catch {
                return report(note: UsageText.unreachable)
            }
        }
        return report(note: sawAuthFailure ? "Your GitHub sign-in has expired. Sign in to Copilot again in Accounts, or run gh auth login." : nil)
    }

    private func report(plan: String? = nil, meters: [UsageMeter] = [], facts: [UsageFact] = [], note: String? = nil) -> ProviderUsage {
        ProviderUsage(id: "github-copilot", name: "GitHub Copilot", logo: "github-copilot", plan: plan, meters: meters, facts: facts, note: note)
    }

    private func fetch(_ token: Token) async throws -> UsageHTTP.Response {
        try await http.send(URL(string: token.apiBase + "/copilot_internal/user")!, headers: [
            "Authorization": "token \(token.value)",
            "Accept": "application/json",
            "Editor-Version": "vscode/1.96.2",
            "Editor-Plugin-Version": "copilot-chat/0.26.7",
            "User-Agent": "GitHubCopilotChat/0.26.7",
            "X-Github-Api-Version": "2025-04-01",
        ])
    }

    // MARK: Tokens

    /// The app's own Copilot sign-in first (it's the account the agent uses), then the
    /// editor's login, then gh's config file, then (if allowed) gh's Keychain item.
    private func loadTokens(engine credentials: [CredentialSecret]) async -> [Token] {
        var tokens: [Token] = []
        for credential in credentials where credential.integrationID == "github-copilot" {
            guard let access = credential.value.access, !access.isEmpty else { continue }
            let enterprise = credential.value.metadata?["enterpriseUrl"]?.string?
                .replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            tokens.append(Token(value: access, apiBase: enterprise.map { "https://api.\($0)" } ?? "https://api.github.com"))
        }
        for path in Self.editorPaths {
            if let text = LoginFiles.read(path), let token = Self.editorToken(text) {
                tokens.append(Token(value: token, apiBase: "https://api.github.com"))
                break
            }
        }
        let ghConfig = LoginFiles.read(Self.ghHostsPath)
        if let token = ghConfig.flatMap({ UsageParse.yamlValue($0, key: "oauth_token") }) {
            tokens.append(Token(value: token, apiBase: "https://api.github.com"))
        } else if options.readsKeychain, LoginKeychain().exists(service: Self.ghKeychainService) == true {
            let user = ghConfig.flatMap { UsageParse.yamlValue($0, key: "user") }
            let raw = await offMain { LoginKeychain().read(service: Self.ghKeychainService, account: user, owner: .securityTool) }
            if let token = raw.flatMap(UsageParse.unwrapGoKeyring) {
                tokens.append(Token(value: token, apiBase: "https://api.github.com"))
            }
        }
        // The same token can come from several places; ask once.
        var seen = Set<String>()
        return tokens.filter { seen.insert($0.value).inserted }
    }

    /// The token in an editor's apps.json/hosts.json, under `github.com` or `github.com:<app>`.
    static func editorToken(_ text: String) -> String? {
        guard let object = UsageParse.json(Data(text.utf8)) else { return nil }
        for (key, value) in object where key == "github.com" || key.hasPrefix("github.com:") {
            if let token = ((value as? [String: Any])?["oauth_token"] as? String)?.trimmingCharacters(in: .whitespaces), !token.isEmpty {
                return token
            }
        }
        return nil
    }

    // MARK: Mapping

    static func map(body: [String: Any]) -> ProviderUsage {
        let plan = (body["copilot_plan"] as? String).map { raw in
            raw.split(whereSeparator: { "_ -".contains($0) }).map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
        }
        let resets = UsageParse.date(body["quota_reset_date_utc"]) ?? UsageParse.date(body["quota_reset_date"]) ?? UsageParse.date(body["limited_user_reset_date"])
        let snapshots = body["quota_snapshots"] as? [String: Any]
        let tokenBilled = UsageParse.bool(body["token_based_billing"]) == true

        var meters: [UsageMeter] = []
        var facts: [UsageFact] = []
        if let credits = meter(snapshots?["premium_interactions"], id: "premium", label: tokenBilled ? "AI credits" : "Premium requests", resets: resets) {
            meters.append(credits)
            // Overage only means something next to an included pool, and only once there is some.
            if let premium = snapshots?["premium_interactions"] as? [String: Any], UsageParse.bool(premium["overage_permitted"]) == true {
                let overage = Int(UsageParse.number(premium["overage_count"]) ?? 0)
                if overage > 0 { facts.append(UsageFact(label: "Extra usage", value: overage == 1 ? "1 request" : "\(overage) requests")) }
            }
        }
        if let chat = meter(snapshots?["chat"], id: "chat", label: "Chat", resets: resets) { meters.append(chat) }
        if let completions = meter(snapshots?["completions"], id: "completions", label: "Completions", resets: resets) { meters.append(completions) }

        // Older free accounts: remaining counts against monthly totals.
        if meters.isEmpty {
            let limited = body["limited_user_quotas"] as? [String: Any]
            let monthly = body["monthly_quotas"] as? [String: Any]
            for (key, label) in [("chat", "Chat"), ("completions", "Completions")] {
                guard let total = UsageParse.number(monthly?[key]), total > 0, let remaining = UsageParse.number(limited?[key]) else { continue }
                meters.append(UsageMeter(id: key, label: label, used: max(0, total - remaining) / total, resetsAt: resets, window: 30 * 24 * 3600))
            }
        }

        var note: String?
        if meters.isEmpty {
            // Seats billed through an organization have no personal quota; show what we know.
            if tokenBilled, let premium = snapshots?["premium_interactions"] as? [String: Any],
               let used = UsageParse.number(premium["credits_used"]), used > 0 {
                facts.append(UsageFact(label: "AI credits used", value: Int(used).formatted()))
            }
            note = facts.isEmpty ? "No limits on this plan." : nil
        }
        return ProviderUsage(id: "github-copilot", name: "GitHub Copilot", logo: "github-copilot", plan: plan, meters: meters, facts: facts, note: note)
    }

    /// One quota snapshot as a meter; nil when unlimited (or GitHub's -1 sentinel) or empty.
    private static func meter(_ raw: Any?, id: String, label: String, resets: Date?) -> UsageMeter? {
        guard let snapshot = raw as? [String: Any] else { return nil }
        let entitlement = UsageParse.number(snapshot["entitlement"])
        let remaining = UsageParse.number(snapshot["remaining"])
        if UsageParse.bool(snapshot["unlimited"]) == true || entitlement == -1 || remaining == -1 || entitlement == 0 { return nil }
        let percentUsed: Double
        if let percentRemaining = UsageParse.number(snapshot["percent_remaining"]) {
            percentUsed = 100 - percentRemaining
        } else if let entitlement, entitlement > 0, let remaining {
            percentUsed = 100 - remaining / entitlement * 100
        } else {
            return nil
        }
        return UsageMeter(id: id, label: label, percentUsed: percentUsed, resetsAt: resets, window: 30 * 24 * 3600)
    }
}
