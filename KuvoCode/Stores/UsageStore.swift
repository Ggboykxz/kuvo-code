import Foundation
import OpenCodeKit
import os

private let log = Logger(subsystem: "run.kuvo.code", category: "usage")

/// How much of each subscription is left, for the menu bar: Codex, Claude, GitHub
/// Copilot and OpenCode Go (providers ported from OpenUsage).
@Observable
final class UsageStore {
    var api: OpenCodeAPI?
    /// The login shell's environment (CODEX_HOME, CLAUDE_CONFIG_DIR live there).
    var environment: [String: String] = ProcessInfo.processInfo.environment

    static let readsKeychainKey = "usage.readsKeychain"
    static let renewsLoginsKey = "usage.renewsLogins"

    private(set) var reports: [ProviderUsage] = []
    private(set) var isRefreshing = false
    private(set) var updated: Date?

    private let service = UsageService()
    private var timer: Task<Void, Never>?
    private var pending: Task<Void, Never>?

    /// The tightest limit across subscriptions: what the menu bar shows.
    var tightest: UsageMeter? {
        reports.flatMap(\.meters).max { $0.used < $1.used }
    }

    private var options: UsageOptions {
        let defaults = UserDefaults.standard
        return UsageOptions(
            readsKeychain: defaults.bool(forKey: Self.readsKeychainKey),
            renewsLogins: defaults.bool(forKey: Self.renewsLoginsKey),
            environment: environment
        )
    }

    func start() {
        timer?.cancel()
        timer = Task {
            while !Task.isCancelled {
                await refresh()
                // Five minutes, like OpenUsage: providers throttle more frequent checks.
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // The app's own accounts come from the engine; secrets stay inside this call.
        var credentials: [CredentialSecret] = []
        if let api {
            do { credentials = try await api.credentialSecrets() } catch { log.error("credentials: \(String(describing: error), privacy: .public)") }
        }
        let fresh = await service.usage(engine: credentials, options: options)
        reports = fresh.map { report in
            // A check that failed for now (offline, throttled) keeps the last figures, with its note.
            guard report.meters.isEmpty, report.facts.isEmpty,
                  let previous = reports.first(where: { $0.id == report.id }), !previous.meters.isEmpty else { return report }
            var kept = previous
            kept.note = report.note
            return kept
        }
        updated = Date()
    }

    /// Usage changes after a run, and when accounts change; refresh once things settle.
    func handle(_ event: ServerEvent) {
        let delay: Duration
        switch event.type {
        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted": delay = .seconds(5)
        case "credential.updated", "credential.switched": delay = .seconds(1)
        default: return
        }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }
}
