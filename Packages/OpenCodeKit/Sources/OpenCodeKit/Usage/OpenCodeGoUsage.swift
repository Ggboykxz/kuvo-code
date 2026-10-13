// Adapted from OpenUsage's OpenCode provider (https://github.com/robinebers/openusage),
// MIT License, Copyright (c) 2026 Robin Ebers. See THIRD_PARTY_NOTICES.md.

import Foundation

/// OpenCode Go subscription windows (rolling 5-hour, weekly, monthly), with the Go key
/// connected in kuvo-ai.
struct OpenCodeGoUsage: Sendable {
    let http: UsageHTTP

    static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    func read(engine credentials: [CredentialSecret]) async -> ProviderUsage? {
        guard let key = credentials.first(where: { $0.integrationID == "opencode-go" })?.value.key, !key.isEmpty else { return nil }
        do {
            let response = try await http.send(Self.usageURL, headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"])
            guard response.isSuccess, let body = UsageParse.json(response.body) else {
                let note = response.isAuthFailure ? "Your OpenCode Go key was refused. Check it in Accounts." : UsageText.failed(response.status)
                return ProviderUsage(id: "opencode-go", name: "OpenCode Go", logo: "opencode", note: note)
            }
            // Compare server instants when possible, so a Mac clock that's off doesn't matter.
            let now = response.header("date").flatMap(Self.httpDate) ?? Date()
            return Self.map(body: body, now: now)
        } catch {
            return ProviderUsage(id: "opencode-go", name: "OpenCode Go", logo: "opencode", note: UsageText.unreachable)
        }
    }

    static func map(body: [String: Any], now: Date) -> ProviderUsage {
        let usage = body["usage"] as? [String: Any] ?? [:]
        var meters: [UsageMeter] = []
        for (key, id, label, length) in [("rolling", "session", "5-hour", 5.0 * 3600), ("weekly", "weekly", "Weekly", 7 * 24 * 3600), ("monthly", "monthly", "Monthly", 30 * 24 * 3600)] {
            guard let window = usage[key] as? [String: Any], let percent = UsageParse.number(window["percent"]) else { continue }
            var resets = UsageParse.date(window["resetsAt"])
            // An untouched rolling window reports a reset exactly one window away: a placeholder, not a real time.
            if key == "rolling", UsageParse.clampPercent(percent) == 0, let date = resets, abs(date.timeIntervalSince(now) - length) <= 2 {
                resets = nil
            }
            meters.append(UsageMeter(id: id, label: label, percentUsed: percent, resetsAt: resets, window: length))
        }
        return ProviderUsage(id: "opencode-go", name: "OpenCode Go", logo: "opencode", plan: meters.isEmpty ? nil : "Go", meters: meters,
                             note: meters.isEmpty ? "OpenCode didn't report Go limits for this key." : nil)
    }

    static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }
}
