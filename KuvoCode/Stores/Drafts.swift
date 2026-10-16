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
        /// What you're replying to, shown over the composer and sent as a quote ahead of the text
        /// (a group chat's).
        var quote: String?
        /// What you're replying to in a session, each with your answer to it: sent in order, then
        /// the text.
        var quotes: [Quote] = []

        var isEmpty: Bool { text.isEmpty && files.isEmpty && quote == nil && quotes.isEmpty }

        init(text: String = "", files: [URL] = [], quote: String? = nil, quotes: [Quote] = []) {
            self.text = text
            self.files = files
            self.quote = quote
            self.quotes = quotes
        }

        /// Drafts saved before a field was added still read.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            files = try c.decodeIfPresent([URL].self, forKey: .files) ?? []
            quote = try c.decodeIfPresent(String.self, forKey: .quote)
            quotes = try c.decodeIfPresent([Quote].self, forKey: .quotes) ?? []
        }
    }

    /// A part of a message you're replying to, and what you say to it.
    struct Quote: Codable, Hashable, Identifiable {
        var id = UUID()
        var text: String
        var response = ""
    }

    private var drafts: [String: Draft]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private static let key = "composerDrafts"

    private init() {
        let stored = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Draft].self, from: $0) } ?? [:]
        drafts = Dictionary(uniqueKeysWithValues: stored.map { key, draft in
            var draft = draft
            draft.files = draft.files.filter { FileManager.default.fileExists(atPath: $0.path) }
            // A session's draft from before it could reply to several quotes (a group chat's
            // keeps its one).
            if !key.hasPrefix("group:"), let quote = draft.quote, draft.quotes.isEmpty {
                draft.quotes = [Quote(text: quote)]
                draft.quote = nil
            }
            return (key, draft)
        })
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
