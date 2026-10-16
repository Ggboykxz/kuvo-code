import Foundation
import OpenCodeKit

/// Machines' conversations as last seen, kept in this Mac's caches: a session on a machine
/// that's connecting (after a dropped connection, or at launch) shows its conversation meanwhile,
/// to read, until the machine's own takes its place. A copy goes with its session.
nonisolated enum SessionCopies {
    struct Copy: Codable, Sendable {
        var session: Session
        var messages: [Message]
    }

    /// `~/Library/Caches/<bundle id>/Conversations`, a file per session.
    static var folder: URL {
        URL.cachesDirectory.appending(path: Bundle.main.bundleIdentifier ?? "run.kuvo.code").appending(path: "Conversations")
    }

    private static func file(_ id: String) -> URL {
        folder.appending(path: id.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } + ".json")
    }

    /// Writes it in the background: a long conversation takes a moment to encode.
    static func save(_ copy: Copy) {
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(copy) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file(copy.session.id), options: .atomic)
        }
    }

    static func load(_ id: String) -> Copy? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? JSONDecoder().decode(Copy.self, from: data)
    }

    static func remove(_ id: String) {
        try? FileManager.default.removeItem(at: file(id))
    }

    /// Removes the copies of sessions no longer known.
    static func keep(_ ids: Set<String>) {
        let names = Set(ids.map { file($0).lastPathComponent })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !names.contains(name) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }
}
