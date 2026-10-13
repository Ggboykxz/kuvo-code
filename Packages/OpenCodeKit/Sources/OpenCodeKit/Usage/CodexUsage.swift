// Adapted from OpenUsage's Codex provider (https://github.com/robinebers/openusage),
// MIT License, Copyright (c) 2026 Robin Ebers. See THIRD_PARTY_NOTICES.md.

import Foundation

/// ChatGPT/Codex plan limits (5-hour and weekly windows, Spark, credits), read with the
/// Codex CLI's login, or a Codex sign-in made in kuvo-ai.
struct CodexUsage: Sendable {
    let http: UsageHTTP
    let options: UsageOptions

    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let refreshURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let keychainService = "Codex Auth"
    /// Renew within this long of expiry, like the Codex CLI.
    static let refreshWindow: TimeInterval = 5 * 60

    /// Where a login came from, and whether we may write a renewed one back.
    enum Source: Equatable {
        case file(String)
        case keychain(account: String)
        /// A sign-in stored by kuvo-ai's engine: read only, the engine renews it.
        case engine

        var isWritable: Bool { self != .engine }
    }

    struct Login {
        var source: Source
        /// The stored document, to merge renewed tokens into and to detect changes.
        var document: [String: Any]
        var text: String

        var tokens: [String: Any] { document["tokens"] as? [String: Any] ?? [:] }
        var accessToken: String? { (tokens["access_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        var refreshToken: String? { (tokens["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        var accountID: String? {
            (tokens["account_id"] as? String)
                ?? accessToken.flatMap(UsageParse.jwtPayload).flatMap { claims in
                    (claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
                }
        }

        var expiresAt: Date? {
            accessToken.flatMap(UsageParse.jwtPayload).flatMap { UsageParse.number($0["exp"]) }.map(Date.init(timeIntervalSince1970:))
        }
    }

    private enum Outcome {
        case usage(ProviderUsage)
        /// This login can't be used now; another one might.
        case unusable(String)
    }

    func read(engine credentials: [CredentialSecret]) async -> ProviderUsage? {
        var logins = loadFileLogins()
        if options.readsKeychain, let keychain = await loadKeychainLogin() { logins.append(keychain) }
        logins += credentials.compactMap(Self.engineLogin)

        guard !logins.isEmpty else {
            // Signed in with "Sign in with ChatGPT" in kuvo-ai only: say why there's nothing to show.
            guard credentials.contains(where: { $0.integrationID == "openai" && $0.value.methodID == "chatgpt-token-sharing" }) else { return nil }
            return report(note: "OpenAI doesn't report plan limits for “Sign in with ChatGPT”. Sign in to the Codex CLI (run codex) to see your 5-hour and weekly limits here.")
        }

        var lastNote: String?
        for login in logins {
            switch await probe(login) {
            case .usage(let usage): return usage
            case .unusable(let note): lastNote = note
            }
        }
        return report(note: lastNote)
    }

    private func report(plan: String? = nil, meters: [UsageMeter] = [], facts: [UsageFact] = [], note: String? = nil) -> ProviderUsage {
        ProviderUsage(id: "codex", name: "Codex", logo: "openai", plan: plan, meters: meters, facts: facts, note: note)
    }

    // MARK: Probing

    private func probe(_ initial: Login) async -> Outcome {
        var login = initial
        guard var token = login.accessToken else { return .unusable("Usage isn't available for an API-key login.") }

        if let expires = login.expiresAt, expires.timeIntervalSinceNow <= Self.refreshWindow {
            // The CLI may have renewed it since we read it: prefer the live copy.
            if let live = await reload(login.source), let liveToken = live.accessToken {
                login = live
                token = liveToken
            }
        }
        if let expires = login.expiresAt, expires.timeIntervalSinceNow <= Self.refreshWindow {
            if options.renewsLogins, login.source.isWritable, login.refreshToken != nil {
                switch await renew(&login) {
                case .success(let renewed): token = renewed
                case .failure(let note): return .unusable(note)
                }
            } else if expires < Date() {
                return .unusable(expiredNote(login.source))
            }
        }

        do {
            var response = try await fetch(token: token, accountID: login.accountID)
            if response.isAuthFailure {
                guard options.renewsLogins, login.source.isWritable, login.refreshToken != nil else { return .unusable(expiredNote(login.source)) }
                switch await renew(&login) {
                case .success(let renewed): response = try await fetch(token: renewed, accountID: login.accountID)
                case .failure(let note): return .unusable(note)
                }
            }
            guard response.isSuccess, let body = UsageParse.json(response.body) else {
                return .usage(report(note: response.isAuthFailure ? expiredNote(login.source) : UsageText.failed(response.status)))
            }
            return .usage(Self.map(body: body, response: response))
        } catch {
            return .usage(report(note: UsageText.unreachable))
        }
    }

    private func expiredNote(_ source: Source) -> String {
        source == .engine
            ? "Your ChatGPT sign-in in kuvo-ai needs renewing. Use one of its models, or sign in again in Accounts."
            : "Your Codex login has expired. Run codex to renew it, or let kuvo-ai renew logins in Settings › Usage."
    }

    private func fetch(token: String, accountID: String?) async throws -> UsageHTTP.Response {
        var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json", "User-Agent": "kuvo-ai"]
        if let accountID, !accountID.isEmpty { headers["ChatGPT-Account-Id"] = accountID }
        return try await http.send(Self.usageURL, headers: headers, timeout: 10)
    }

    // MARK: Renewing (opt-in)

    private enum Renewal {
        case success(String)
        case failure(String)
    }

    /// Exchanges the refresh token and writes the new tokens back, but only while the source
    /// still holds the login we started from: if the CLI renewed it meanwhile, theirs wins.
    private func renew(_ login: inout Login) async -> Renewal {
        guard let refreshToken = login.refreshToken else { return .failure(expiredNote(login.source)) }
        let body = "grant_type=refresh_token&client_id=\(Self.clientID.formEncoded)&refresh_token=\(refreshToken.formEncoded)"
        let response: UsageHTTP.Response
        do {
            response = try await http.send(Self.refreshURL, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(body.utf8))
        } catch {
            return .failure(UsageText.unreachable)
        }
        guard response.isSuccess, let json = UsageParse.json(response.body), let access = json["access_token"] as? String, !access.isEmpty else {
            if response.status == 400 || response.status == 401 {
                return .failure("Your Codex login has expired. Run codex to log in again.")
            }
            return .failure(UsageText.failed(response.status))
        }

        guard let live = await reload(login.source), live.text == login.text else {
            return .failure("Codex renewed its login at the same time. Trying again shortly.")
        }
        var tokens = login.tokens
        tokens["access_token"] = access
        if let refresh = json["refresh_token"] as? String { tokens["refresh_token"] = refresh }
        if let id = json["id_token"] as? String { tokens["id_token"] = id }
        var document = login.document
        document["tokens"] = tokens
        document["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: document, options: login.source == .engine ? [] : [.prettyPrinted, .sortedKeys]) else {
            return .failure(UsageText.failed(0))
        }
        let text = String(decoding: data, as: UTF8.self)
        do {
            switch login.source {
            case .file(let path): try LoginFiles.write(path, text)
            case .keychain(let account): try await offMain { try LoginKeychain().write(service: Self.keychainService, account: account, value: text, owner: .app) }
            case .engine: break
            }
        } catch {
            // The renewed token still works for this read; it just wasn't saved.
        }
        login = Login(source: login.source, document: document, text: text)
        return .success(access)
    }

    // MARK: Logins

    private var homes: [String] {
        if let home = options.environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespaces), !home.isEmpty { return [home] }
        return ["~/.config/codex", "~/.codex"]
    }

    private func loadFileLogins() -> [Login] {
        var seen = Set<String>()
        return homes.compactMap { home in
            let path = home.trimmingSuffix("/") + "/auth.json"
            guard seen.insert(LoginFiles.expand(path)).inserted, let text = LoginFiles.read(path) else { return nil }
            return Self.login(text: text, source: .file(path))
        }
    }

    private func loadKeychainLogin() async -> Login? {
        let account = LoginKeychain.codexAccount(home: options.environment["CODEX_HOME"] ?? "~/.codex")
        guard LoginKeychain().exists(service: Self.keychainService, account: account) != false else { return nil }
        let text = await offMain { LoginKeychain().read(service: Self.keychainService, account: account, owner: .app) }
        return text.flatMap { Self.login(text: $0, source: .keychain(account: account)) }
    }

    private func reload(_ source: Source) async -> Login? {
        switch source {
        case .file(let path): return LoginFiles.read(path).flatMap { Self.login(text: $0, source: source) }
        case .keychain(let account):
            let text = await offMain { LoginKeychain().read(service: Self.keychainService, account: account, owner: .app) }
            return text.flatMap { Self.login(text: $0, source: source) }
        case .engine: return nil
        }
    }

    static func login(text: String, source: Source) -> Login? {
        guard let document = UsageParse.decodeWithHexFallback(text, decode: UsageParse.json) else { return nil }
        let login = Login(source: source, document: document, text: text)
        return login.accessToken == nil ? nil : login
    }

    /// kuvo-ai's own Codex sign-ins ("Codex browser" / "device code"), which the usage API accepts.
    static func engineLogin(_ credential: CredentialSecret) -> Login? {
        guard credential.integrationID == "openai", ["chatgpt-browser", "chatgpt-headless"].contains(credential.value.methodID),
              let access = credential.value.access else { return nil }
        var tokens: [String: Any] = ["access_token": access]
        if let account = credential.value.metadata?["accountID"]?.string { tokens["account_id"] = account }
        return Login(source: .engine, document: ["tokens": tokens], text: "")
    }

    // MARK: Mapping

    static let sessionWindow: TimeInterval = 5 * 3600
    static let weeklyWindow: TimeInterval = 7 * 24 * 3600

    static func map(body: [String: Any], response: UsageHTTP.Response? = nil) -> ProviderUsage {
        var meters = windows(
            body["rate_limit"] as? [String: Any],
            labels: ("5-hour", "Weekly"),
            ids: ("session", "weekly"),
            headerPercents: (UsageParse.number(response?.header("x-codex-primary-used-percent")), UsageParse.number(response?.header("x-codex-secondary-used-percent")))
        )
        // Model-specific limits (GPT-5.3-Codex-Spark) arrive as extra named windows.
        if let extra = (body["additional_rate_limits"] as? [Any])?.compactMap({ $0 as? [String: Any] }),
           let spark = extra.first(where: { [$0["limit_name"], $0["metered_feature"]].compactMap { ($0 as? String)?.lowercased() }.contains { $0.contains("spark") } }),
           let rateLimit = spark["rate_limit"] as? [String: Any] {
            meters += windows(rateLimit, labels: ("Spark 5-hour", "Spark weekly"), ids: ("spark", "sparkWeekly"))
        }

        var facts: [UsageFact] = []
        // Flex credits, worth 4¢ each; most plans have none, so a zero balance isn't shown.
        if let credits = creditsRemaining(body: body, response: response), credits >= 1 {
            let count = Int(credits.rounded(.down))
            let dollars = (Double(count) * 0.04).formatted(.currency(code: "USD"))
            facts.append(UsageFact(label: "Credits", value: "\(dollars) · \(count) credits"))
        }
        let note = meters.isEmpty && facts.isEmpty ? "Codex didn't report any limits for this account." : nil
        return ProviderUsage(id: "codex", name: "Codex", logo: "openai", plan: plan(body["plan_type"]), meters: meters, facts: facts, note: note)
    }

    /// Codex usually sends the 5-hour window as `primary_window` and the weekly one as
    /// `secondary_window`, but can move a lone weekly limit into the primary slot, so classify
    /// by the stated length first and fall back to the slot.
    private static func windows(_ rateLimit: [String: Any]?, labels: (String, String), ids: (String, String), headerPercents: (Double?, Double?) = (nil, nil)) -> [UsageMeter] {
        struct Candidate { var window: [String: Any]; var percent: Double?; var slotIsSession: Bool }
        func candidate(_ value: Any?, header: Double?, slotIsSession: Bool) -> Candidate? {
            guard let window = value as? [String: Any] ?? (header == nil ? nil : [:]) else { return nil }
            return Candidate(window: window, percent: UsageParse.number(window["used_percent"]) ?? header, slotIsSession: slotIsSession)
        }
        let candidates = [
            candidate(rateLimit?["primary_window"], header: headerPercents.0, slotIsSession: true),
            candidate(rateLimit?["secondary_window"], header: headerPercents.1, slotIsSession: false),
        ].compactMap { $0 }

        func length(_ window: [String: Any]) -> TimeInterval? { UsageParse.number(window["limit_window_seconds"]) }
        func kind(_ candidate: Candidate) -> Bool? {
            switch length(candidate.window) {
            case sessionWindow?: true
            case weeklyWindow?: false
            default: nil
            }
        }
        func meter(session: Bool) -> UsageMeter? {
            let match = candidates.first { kind($0) == session } ?? candidates.first { kind($0) == nil && $0.slotIsSession == session }
            guard let match, let percent = match.percent else { return nil }
            let resets = UsageParse.number(match.window["reset_at"]).map { Date(timeIntervalSince1970: $0) }
                ?? UsageParse.number(match.window["reset_after_seconds"]).map { Date().addingTimeInterval($0) }
            return UsageMeter(id: session ? ids.0 : ids.1, label: session ? labels.0 : labels.1, percentUsed: percent, resetsAt: resets,
                              window: length(match.window) ?? (session ? sessionWindow : weeklyWindow))
        }
        return [meter(session: true), meter(session: false)].compactMap { $0 }
    }

    private static func creditsRemaining(body: [String: Any], response: UsageHTTP.Response?) -> Double? {
        if let credits = body["credits"] as? [String: Any] {
            if let balance = UsageParse.number(credits["balance"]) { return balance }
            if credits["has_credits"] as? Bool == false { return nil }
        }
        return UsageParse.number(response?.header("x-codex-credits-balance"))
    }

    /// OpenAI's current names for the Pro tiers; anything else, title-cased.
    static func plan(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "prolite": return "Pro 100"
        case "pro": return "Pro 200"
        case "promax": return "Pro 500"
        case "self_serve_business_prolite": return "Business Premium"
        default: return raw.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
        }
    }
}

/// Runs blocking work (a Keychain read can wait on a permission prompt) off the caller's executor.
func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .utility, operation: work).value
}

func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .utility, operation: work).value
}

extension String {
    var formEncoded: String {
        addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? self
    }
}
