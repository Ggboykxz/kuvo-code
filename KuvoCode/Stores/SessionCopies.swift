import Foundation
import OpenCodeKit

/// Machines' sessions and conversations as last seen, kept in this Mac's caches: while a
/// machine is connecting (after a dropped connection, or at launch), its sessions stay in the
/// sidebar and show their conversations, to read, until the machine's own take their place. A
/// copy goes with its session; a machine's list, with the machine.
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
        folder.appending(path: safe(id) + ".json")
    }

    private static func safe(_ name: String) -> String {
        name.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }

    /// A machine's sessions as last listed.
    private static func list(_ machine: String) -> URL {
        folder.appending(path: "machines").appending(path: safe(machine) + ".json")
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
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".json") && !names.contains(name) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    static func saveSessions(_ sessions: [Session], of machine: String) {
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(sessions) else { return }
            try? FileManager.default.createDirectory(at: list(machine).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: list(machine), options: .atomic)
        }
    }

    static func sessions(of machine: String) -> [Session] {
        guard let data = try? Data(contentsOf: list(machine)) else { return [] }
        return (try? JSONDecoder().decode([Session].self, from: data)) ?? []
    }

    static func removeSessions(of machine: String) {
        try? FileManager.default.removeItem(at: list(machine))
    }
}
