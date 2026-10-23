import Foundation
import OpenCodeKit

/// A message that ran a command shows the command ("/review main") rather than the long
/// prompt the command sent for it. The engine doesn't mark these messages, so the app notes
/// each one as it arrives, and keeps the notes across launches.
@Observable
final class CommandMessages {
    static let shared = CommandMessages()
    private static let key = "commandMessages"
    private static let limit = 500

    /// Message IDs and their commands, oldest first.
    private var entries: [[String]]
    private var commands: [String: String]

    private init() {
        let stored = (UserDefaults.standard.array(forKey: Self.key) as? [[String]] ?? []).filter { $0.count == 2 }
        entries = stored
        commands = Dictionary(stored.map { ($0[0], $0[1]) }, uniquingKeysWith: { $1 })
    }

    subscript(id: String) -> String? { commands[id] }

    /// What `message` says as you wrote it: the command, if it ran one.
    func text(of message: Message.User) -> String {
        commands[message.id] ?? message.text
    }

    func note(_ id: String, command: String) {
        // Noted again (its events read twice): its newest place, once, so the oldest going doesn't
        // take it.
        if commands[id] != nil { entries.removeAll { $0.first == id } }
        commands[id] = command
        entries.append([id, command])
        if entries.count > Self.limit {
            for entry in entries.prefix(entries.count - Self.limit) { commands[entry[0]] = nil }
            entries.removeFirst(entries.count - Self.limit)
        }
        UserDefaults.standard.set(entries, forKey: Self.key)
    }
}
