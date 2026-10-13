import Foundation
import Testing
@testable import OpenCodeKit

struct UsageMappingTests {
    @Test func codexReadsBothWindowsAndThePlan() {
        let body: [String: Any] = [
            "plan_type": "prolite",
            "rate_limit": [
                "primary_window": ["used_percent": 42, "limit_window_seconds": 18_000, "reset_at": 1_800_000_000],
                "secondary_window": ["used_percent": 10, "limit_window_seconds": 604_800, "reset_after_seconds": 3600],
            ],
            "credits": ["balance": 821.7],
        ]
        let usage = CodexUsage.map(body: body)
        #expect(usage.plan == "Pro 100")
        #expect(usage.meters.map(\.label) == ["5-hour", "Weekly"])
        #expect(usage.meters[0].used == 0.42)
        #expect(usage.meters[0].resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(usage.facts.first?.value.hasSuffix("821 credits") == true)
    }

    /// Codex can move a lone weekly limit into the primary slot; the stated length wins.
    @Test func codexClassifiesWindowsByLength() {
        let body: [String: Any] = ["rate_limit": ["primary_window": ["used_percent": 7, "limit_window_seconds": 604_800]]]
        #expect(CodexUsage.map(body: body).meters.map(\.label) == ["Weekly"])
    }

    @Test func codexPlanNames() {
        #expect(CodexUsage.plan("pro") == "Pro 200")
        #expect(CodexUsage.plan("promax") == "Pro 500")
        #expect(CodexUsage.plan("team_plus") == "Team Plus")
        #expect(CodexUsage.plan("") == nil)
    }

    @Test func claudeReadsWindowsAndExtraUsage() {
        let body: [String: Any] = [
            "five_hour": ["utilization": 63.5, "resets_at": "2026-10-13T15:00:00.123+00:00"],
            "seven_day": ["utilization": 20, "resets_at": "2026-10-17T00:00:00Z"],
            "limits": [["kind": "weekly_scoped", "percent": 5, "scope": ["model": ["display_name": "Fable"]]]],
            "extra_usage": ["is_enabled": true, "used_credits": 1240, "monthly_limit": 5000],
        ]
        let usage = ClaudeUsage.map(body: body, plan: "Max 20x")
        #expect(usage.meters.map(\.label) == ["5-hour", "Weekly", "Fable weekly", "Extra usage"])
        #expect(usage.meters[0].resetsAt != nil)
        #expect(usage.meters[3].used == 0.248)
        #expect(usage.meters[3].detail?.contains("12") == true && usage.meters[3].detail?.contains("50") == true)
    }

    /// The shape GitHub returned for a token-billed Enterprise seat.
    @Test func copilotSkipsUnlimitedQuotas() {
        let body: [String: Any] = [
            "copilot_plan": "enterprise",
            "token_based_billing": true,
            "quota_reset_date_utc": "2026-11-01T00:00:00.000Z",
            "quota_snapshots": [
                "chat": ["unlimited": true, "entitlement": 0, "remaining": 0, "percent_remaining": 100],
                "premium_interactions": ["unlimited": false, "entitlement": 1_000_000, "remaining": 908_558, "percent_remaining": 90.8, "overage_permitted": true, "overage_count": 3],
            ],
        ]
        let usage = CopilotUsage.map(body: body)
        #expect(usage.plan == "Enterprise")
        #expect(usage.meters.map(\.label) == ["AI credits"])
        #expect(abs(usage.meters[0].remaining - 0.908) < 0.0001)
        #expect(usage.meters[0].resetsAt == UsageParse.date("2026-11-01T00:00:00Z"))
        #expect(usage.facts.map(\.label) == ["Extra usage"])
    }

    /// An untouched rolling window reports a reset exactly one window away: not a real time.
    @Test func openCodeGoDropsPlaceholderResets() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let placeholder = ISO8601DateFormatter().string(from: now.addingTimeInterval(5 * 3600))
        let body: [String: Any] = ["usage": [
            "rolling": ["percent": 0, "resetsAt": placeholder],
            "weekly": ["percent": 30, "resetsAt": "2026-10-19T00:00:00Z"],
        ]]
        let usage = OpenCodeGoUsage.map(body: body, now: now)
        #expect(usage.meters.map(\.label) == ["5-hour", "Weekly"])
        #expect(usage.meters[0].resetsAt == nil)
        #expect(usage.meters[1].resetsAt != nil)
    }
}

struct UsageParseTests {
    @Test func readsJWTPayloads() {
        let payload = Data(#"{"exp":1800000000}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        #expect(UsageParse.number(UsageParse.jwtPayload("e30.\(payload).sig")?["exp"]) == 1_800_000_000)
        #expect(UsageParse.jwtPayload("not-a-jwt") == nil)
    }

    @Test func acceptsHexEncodedJSON() {
        let hex = Data(#"{"a":1}"#.utf8).map { String(format: "%02x", $0) }.joined()
        #expect(UsageParse.decodeWithHexFallback(hex, decode: UsageParse.json)?["a"] as? Int == 1)
    }

    @Test func readsGhLogins() {
        #expect(UsageParse.unwrapGoKeyring("go-keyring-base64:" + Data("gho_abc".utf8).base64EncodedString()) == "gho_abc")
        let hosts = "github.com:\n    user: octo\n    oauth_token: gho_123\nexample.com:\n    oauth_token: other\n"
        #expect(UsageParse.yamlValue(hosts, key: "oauth_token") == "gho_123")
        #expect(UsageParse.yamlValue(hosts, key: "user") == "octo")
        #expect(CopilotUsage.editorToken(#"{"github.com:Iv1":{"oauth_token":"ghu_x"}}"#) == "ghu_x")
    }

    @Test func parsesDates() {
        #expect(UsageParse.date("2026-11-01") != nil)
        #expect(UsageParse.date("2026-10-13 15:00:00Z") != nil)
        #expect(UsageParse.date(1_800_000_000_000) == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func namesCodexKeychainItemsLikeCodex() {
        let account = LoginKeychain.codexAccount(home: "/nonexistent/codex-home")
        #expect(account.hasPrefix("cli|"))
        #expect(account.count == 4 + 16)
    }

    @Test func clampsMeters() {
        #expect(UsageMeter(id: "a", label: "A", used: 1.4).used == 1)
        #expect(UsageMeter(id: "b", label: "B", used: -0.2).remaining == 1)
    }
}
