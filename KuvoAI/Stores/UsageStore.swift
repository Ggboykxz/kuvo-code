import Foundation
import OpenCodeKit
import os

private let log = Logger(subsystem: "run.kuvo.ai", category: "usage")

/// How much of each connected plan is left, for the menu bar.
@Observable
final class UsageStore {
    var api: OpenCodeAPI?

    private(set) var reports: [ProviderUsage] = []
    private(set) var isRefreshing = false
    private(set) var updated: Date?

    private let client = UsageClient()
    private var timer: Task<Void, Never>?
    private var pending: Task<Void, Never>?

    /// The tightest limit across accounts: what the menu bar shows.
    var tightest: UsageMeter? {
        reports.flatMap(\.meters).max { $0.used < $1.used }
    }

    func start() {
        timer?.cancel()
        timer = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func refresh() async {
        guard let api, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            // Secrets stay in this function: only the usage figures are kept.
            let credentials = try await api.credentialSecrets().filter { $0.active && UsageClient.supported.contains($0.integrationID) }
            let client = client
            let results = await withTaskGroup(of: ProviderUsage?.self) { group in
                for credential in credentials {
                    group.addTask { await client.usage(for: credential) }
                }
                var results: [ProviderUsage] = []
                for await usage in group {
                    if let usage { results.append(usage) }
                }
                return results
            }
            reports = results.sorted { $0.id < $1.id }
            updated = Date()
        } catch {
            log.error("usage: \(String(describing: error), privacy: .public)")
        }
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
