import Foundation
import OpenCodeKit

/// Every group chat, wherever it lives, as the window and the phone show them: this Mac's
/// (`BotGroups`, which runs them) and your machines' (`MachineGroups`, which their machines run).
/// What you do in one goes to where it lives.
@MainActor @Observable
final class GroupChats {
    let mac: BotGroups
    let machines: MachineGroups

    init(mac: BotGroups, machines: MachineGroups) {
        self.mac = mac
        self.machines = machines
    }

    var list: [BotGroup] { mac.list + machines.chats.map(\.group) }
    var speaking: [String: String] { mac.speaking.merging(machines.speaking) { first, _ in first } }
    var discussing: Set<String> { mac.discussing.union(machines.discussing) }
    var paused: Set<String> { mac.paused.union(machines.paused) }
    var seatIDs: Set<String> { mac.seatIDs.union(machines.seatIDs) }

    func group(_ id: String?) -> BotGroup? { mac.group(id) ?? machines.group(id) }
    func group(seat: String) -> BotGroup? { mac.group(seat: seat) ?? machines.group(seat: seat) }
    func messages(in id: String) -> [GroupMessage] { machines.has(id) ? machines.messages(in: id) : mac.messages(in: id) }
    /// The machine a chat lives on; nil for this Mac.
    func machine(of id: String?) -> String? { machines.machine(of: id) }
    func isUnread(_ group: BotGroup) -> Bool { machines.has(group.id) ? machines.isUnread(group) : mac.isUnread(group) }
    func name(of author: String?) -> String { mac.name(of: author) }

    /// The machine a chat lives on while you can't reach it there: what you write waits.
    func unreachable(_ id: String) -> String? { machines.unreachable(id) }

    func markViewed(_ id: String) {
        if machines.has(id) { machines.markViewed(id) } else { mac.markViewed(id) }
    }

    /// Your message; to a chat on a machine, sent there, and back in the composer (with why) if it
    /// can't be.
    func send(_ text: String, to id: String) {
        guard machines.has(id) else { return mac.send(text, to: id) }
        Task {
            do {
                try await machines.send(text, to: id)
            } catch {
                let key = BotGroups.tabKey(id)
                let draft = Drafts.shared[key].text
                Drafts.shared[key].text = [text, draft].filter { !$0.isEmpty }.joined(separator: "\n\n")
                Modal.show(error)
            }
        }
    }

    func stop(_ id: String) {
        if machines.has(id) { machines.stop(id) } else { mac.stop(id) }
    }

    func keepGoing(_ id: String) {
        if machines.has(id) { machines.keepGoing(id) } else { mac.keepGoing(id) }
    }

    func startWork(_ wrapUpID: String, in id: String) {
        if machines.has(id) { machines.startWork(wrapUpID, in: id) } else { mac.startWork(wrapUpID, in: id) }
    }

    /// Takes the chat back to before one of your messages; its words, for the composer.
    func undo(from messageID: String, in id: String) async -> String? {
        machines.has(id) ? await machines.undo(from: messageID, in: id) : mac.undo(from: messageID, in: id)
    }

    /// A new chat, on this Mac.
    func create(name: String, purpose: String? = nil, members: [String], meeting: BotGroup.Meeting? = nil) -> BotGroup {
        mac.create(name: name, purpose: purpose, members: members, meeting: meeting)
    }

    func update(_ edited: BotGroup) async {
        guard machines.has(edited.id) else { return await mac.update(edited) }
        do { try await machines.update(edited) } catch { Modal.show(error) }
    }

    func delete(_ group: BotGroup) async {
        guard machines.has(group.id) else { return await mac.delete(group) }
        do { try await machines.delete(group) } catch { Modal.show(error) }
    }
}
