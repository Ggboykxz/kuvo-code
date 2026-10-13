// Adapted from OpenUsage's Claude provider (https://github.com/robinebers/openusage),
// MIT License, Copyright (c) 2026 Robin Ebers. See THIRD_PARTY_NOTICES.md.

import Foundation

/// Claude subscription limits (session, weekly, per-model weekly, extra usage), read
/// with Claude Code's login: its Keychain item first, then ~/.claude/.credentials.json.
struct ClaudeUsage: Sendable {
    let http: UsageHTTP
    let options: UsageOptions

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let refreshScopes = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    /// The usage endpoint needs this scope; `claude setup-token` tokens don't carry it.
    static let usageScope = "user:profile"

    enum Source: Equatable {
        case keychain(service: String, account: String?)
        case file(String)
    }

    struct Login {
        var source: Source
        /// Claude Code's whole document (it also holds MCP logins); renewed tokens are merged in.
        var document: [String: Any]
        var text: String

        var oauth: [String: Any] { document["claudeAiOauth"] as? [String: Any] ?? [:] }
        var accessToken: String? { (oauth["accessToken"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
        var refreshToken: String? { (oauth["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        /// Milliseconds since 1970.
        var expiresAt: Double? { UsageParse.number(oauth["expiresAt"]) }
        var scopes: [String]? { oauth["scopes"] as? [String] }

        var plan: String? {
            guard let raw = (oauth["subscriptionType"] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            let base = raw.prefix(1).uppercased() + raw.dropFirst().lowercased()
            if let tier = oauth["rateLimitTier"] as? String, let match = tier.range(of: #"\d+x"#, options: .regularExpression) {
                return "\(base) \(tier[match])"
            }
            return base
        }
    }

    private enum Outcome {
        case usage(ProviderUsage)
        case unusable(String)
    }

    func read() async -> ProviderUsage? {
        var logins: [Login] = []
        if options.readsKeychain, let keychain = await loadKeychainLogin() { logins.append(keychain) }
        if let file = loadFileLogin() { logins.append(file) }

        guard !logins.isEmpty else {
            // Claude Code on macOS keeps its login in the Keychain; say how to show it.
            guard !options.readsKeychain, LoginKeychain().exists(service: keychainService) == true else { return nil }
            return report(note: "Found a Claude Code login in the Keychain. Allow reading Keychain logins in Settings › Usage to see its limits.")
        }

        var lastNote: String?
        for login in logins {
            switch await probe(login) {
            case .usage(let usage): return usage
            case .unusable(let note): lastNote = note
            }
        }
        return report(plan: logins.first?.plan, note: lastNote)
    }

    private func report(plan: String? = nil, meters: [UsageMeter] = [], facts: [UsageFact] = [], note: String? = nil) -> ProviderUsage {
        ProviderUsage(id: "claude", name: "Claude", logo: "anthropic", plan: plan, meters: meters, facts: facts, note: note)
    }

    private var expiredNote: String {
        "Your Claude Code login has expired. Open Claude Code to renew it, or turn on Renew expired logins in Settings › Usage."
    }

    // MARK: Probing

    private func probe(_ initial: Login) async -> Outcome {
        var login = initial
        guard var token = login.accessToken else { return .unusable(expiredNote) }
        if let scopes = login.scopes, !scopes.isEmpty, !scopes.contains(Self.usageScope) {
            return .unusable("This Claude login can't read usage. Run claude and sign in again.")
        }

        if let expires = login.expiresAt, expires - Date().timeIntervalSince1970 * 1000 <= 5 * 60 * 1000 {
            if options.renewsLogins, login.refreshToken != nil {
                switch await renew(&login) {
                case .success(let renewed): token = renewed
                case .failure(let note): return .unusable(note)
                }
            } else if expires <= Date().timeIntervalSince1970 * 1000 {
                return .unusable(expiredNote)
            }
        }

        do {
            var response = try await fetch(token: token)
            if response.isAuthFailure {
                guard options.renewsLogins, login.refreshToken != nil else { return .unusable(expiredNote) }
                switch await renew(&login) {
                case .success(let renewed): response = try await fetch(token: renewed)
                case .failure(let note): return .unusable(note)
                }
            }
            if response.status == 429 {
                // Anthropic throttles this endpoint; asking more often makes it worse.
                return .usage(report(plan: login.plan, note: "Anthropic is limiting usage checks right now. Trying again later."))
            }
            guard response.isSuccess, let body = UsageParse.json(response.body) else {
                return .usage(report(plan: login.plan, note: response.isAuthFailure ? expiredNote : UsageText.failed(response.status)))
            }
            return .usage(Self.map(body: body, plan: login.plan))
        } catch {
            return .usage(report(plan: login.plan, note: UsageText.unreachable))
        }
    }

    private func fetch(token: String) async throws -> UsageHTTP.Response {
        try await http.send(Self.usageURL, headers: [
            "Authorization": "Bearer \(token.trimmingCharacters(in: .whitespaces))",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-cli/2.1.294 (external, cli)",
        ], timeout: 10)
    }

    // MARK: Renewing (opt-in)

    private enum Renewal {
        case success(String)
        case failure(String)
    }

    /// Renews the token and merges it into Claude Code's document, only while that document
    /// is unchanged: if Claude Code renewed meanwhile, its login wins.
    private func renew(_ login: inout Login) async -> Renewal {
        guard let refreshToken = login.refreshToken else { return .failure(expiredNote) }
        let payload: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": Self.clientID, "scope": Self.refreshScopes]
        let response: UsageHTTP.Response
        do {
            response = try await http.send(Self.refreshURL, method: "POST", headers: ["Content-Type": "application/json"], body: try JSONSerialization.data(withJSONObject: payload))
        } catch {
            return .failure(UsageText.unreachable)
        }
        guard response.isSuccess, let json = UsageParse.json(response.body), let access = json["access_token"] as? String, !access.isEmpty else {
            return .failure(response.status == 400 || response.status == 401 ? "Your Claude login has expired. Run claude to sign in again." : UsageText.failed(response.status))
        }

        guard let live = await reload(login.source), live.text == login.text else {
            return .failure("Claude Code renewed its login at the same time. Trying again shortly.")
        }
        var oauth = live.oauth
        oauth["accessToken"] = access
        if let refresh = json["refresh_token"] as? String { oauth["refreshToken"] = refresh }
        if let expiresIn = UsageParse.number(json["expires_in"]) { oauth["expiresAt"] = (Date().timeIntervalSince1970 + expiresIn) * 1000 }
        var document = live.document
        document["claudeAiOauth"] = oauth
        guard let data = try? JSONSerialization.data(withJSONObject: document) else { return .failure(UsageText.failed(0)) }
        let text = String(decoding: data, as: UTF8.self)
        do {
            switch login.source {
            case .file(let path): try LoginFiles.write(path, text)
            case .keychain(let service, let account):
                try await offMain { try LoginKeychain().write(service: service, account: account, value: text, owner: .securityTool) }
            }
        } catch {
            // The renewed token still serves this read.
        }
        login = Login(source: login.source, document: document, text: text)
        return .success(access)
    }

    // MARK: Logins

    private var configDirectory: String {
        options.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "~/.claude"
    }

    private var keychainService: String { "Claude Code-credentials" }

    private func loadFileLogin() -> Login? {
        let path = configDirectory.trimmingSuffix("/") + "/.credentials.json"
        return LoginFiles.read(path).flatMap { Self.login(text: $0, source: .file(path)) }
    }

    private func loadKeychainLogin() async -> Login? {
        let service = keychainService
        guard LoginKeychain().exists(service: service) != false else { return nil }
        // Claude Code files it under the user's name; older versions without an account.
        for account in [LoginKeychain.currentUser, nil] as [String?] {
            let text = await offMain { LoginKeychain().read(service: service, account: account, owner: .securityTool) }
            if let login = text.flatMap({ Self.login(text: $0, source: .keychain(service: service, account: account)) }) { return login }
        }
        return nil
    }

    private func reload(_ source: Source) async -> Login? {
        switch source {
        case .file(let path): return LoginFiles.read(path).flatMap { Self.login(text: $0, source: source) }
        case .keychain(let service, let account):
            let text = await offMain { LoginKeychain().read(service: service, account: account, owner: .securityTool) }
            return text.flatMap { Self.login(text: $0, source: source) }
        }
    }

    static func login(text: String, source: Source) -> Login? {
        guard let document = UsageParse.decodeWithHexFallback(text, decode: UsageParse.json) else { return nil }
        let login = Login(source: source, document: document, text: text)
        return login.accessToken == nil ? nil : login
    }

    // MARK: Mapping

    static func map(body: [String: Any], plan: String?) -> ProviderUsage {
        var meters: [UsageMeter] = []
        func window(_ key: String, id: String, label: String, length: TimeInterval) {
            guard let object = body[key] as? [String: Any], let used = UsageParse.number(object["utilization"]) else { return }
            meters.append(UsageMeter(id: id, label: label, percentUsed: used, resetsAt: UsageParse.date(object["resets_at"]), window: length))
        }
        window("five_hour", id: "session", label: "5-hour", length: 5 * 3600)
        window("seven_day", id: "weekly", label: "Weekly", length: 7 * 24 * 3600)
        window("seven_day_sonnet", id: "sonnet", label: "Sonnet weekly", length: 7 * 24 * 3600)
        // Per-model weekly limits (e.g. Fable) arrive as scoped entries.
        for entry in (body["limits"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) where entry["kind"] as? String == "weekly_scoped" {
            guard let name = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String,
                  let used = UsageParse.number(entry["percent"]), !meters.contains(where: { $0.label.hasPrefix(name) }) else { continue }
            meters.append(UsageMeter(id: "model-\(name)", label: "\(name) weekly", percentUsed: used, resetsAt: UsageParse.date(entry["resets_at"]), window: 7 * 24 * 3600))
        }

        var facts: [UsageFact] = []
        // Extra usage (paid beyond the plan), in cents: a bar against the monthly cap, or just the spend.
        if let extra = body["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let usedCents = UsageParse.number(extra["used_credits"]) {
            let used = usedCents.rounded() / 100
            if let limitCents = UsageParse.number(extra["monthly_limit"]), limitCents > 0 {
                let limit = limitCents.rounded() / 100
                meters.append(UsageMeter(id: "extra", label: "Extra usage", used: used / limit,
                                         detail: "\(used.formatted(.currency(code: "USD"))) of \(limit.formatted(.currency(code: "USD")))"))
            } else if used > 0 {
                facts.append(UsageFact(label: "Extra usage", value: used.formatted(.currency(code: "USD")) + " spent"))
            }
        }
        let note = meters.isEmpty && facts.isEmpty ? "Claude didn't report any limits for this account." : nil
        return ProviderUsage(id: "claude", name: "Claude", logo: "anthropic", plan: plan, meters: meters, facts: facts, note: note)
    }
}
