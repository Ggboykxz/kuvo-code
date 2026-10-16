import AppKit
import Foundation

/// What's typed in a composer but not sent yet, by session (or by a project's new session),
/// kept across launches. Attachments that have since been deleted are dropped.
@Observable
final class Drafts {
    static let shared = Drafts()

    struct Draft: Codable, Hashable {
        var text = ""
        var files: [URL] = []
        /// What you're replying to, shown over the composer and sent as a quote ahead of the text.
        var quote: String?

        var isEmpty: Bool { text.isEmpty && files.isEmpty && quote == nil }
    }

    private var drafts: [String: Draft]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private static let key = "composerDrafts"

    private init() {
        let stored = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Draft].self, from: $0) } ?? [:]
        drafts = stored.mapValues { draft in
            var draft = draft
            draft.files = draft.files.filter { FileManager.default.fileExists(atPath: $0.path) }
            return draft
        }
        // Typing saves after a pause; quitting right after shouldn't lose the last words.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Drafts.shared.save() }
        }
    }

    subscript(key: String) -> Draft {
        get { drafts[key] ?? Draft() }
        set {
            drafts[key] = newValue.isEmpty ? nil : newValue
            scheduleSave()
        }
    }

    func remove(_ key: String) {
        guard drafts[key] != nil else { return }
        drafts[key] = nil
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(drafts), forKey: Self.key)
    }
}
