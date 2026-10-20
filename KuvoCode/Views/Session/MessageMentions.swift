import SwiftUI

/// What a message names, standing out wherever it shows. In your bubbles (a session's, a bot's, a
/// chat's or a group chat's; sent, on its way or waiting): the bots and sessions named with "&",
/// in bold, a bot's in its color, each opening its conversation, and the files named with "@", in
/// bold, each opening in the side panel. In a bot's message in a group chat: the agents it names
/// with "&", the same way. (A group chat's "@Mira" is `GroupMentions`.)
nonisolated enum MessageMentions {
    /// An agent named with "&": as written, its conversation, and a bot's look.
    struct Agent: Hashable, Sendable {
        var reference: AgentReferences.Reference
        var look: BotLook?
    }

    /// `references` with the looks of those that are bots.
    @MainActor static func agents(_ references: [AgentReferences.Reference]) -> [Agent] {
        let bots = AgentMail.shared.app?.bots
        return references.map { Agent(reference: $0, look: bots?.bot(forSession: $0.session)?.look) }
    }

    /// The agents `text` names with "&", as its message would name them now: for a group chat's,
    /// which carry no block saying who they are.
    @MainActor static func agents(namedIn text: String) -> [Agent] {
        agents(AgentReferences.named(in: [text]).map { AgentReferences.Reference(name: $0.name, session: $0.session) })
    }

    /// Styles in `text` each of `agents` it names with "&", and with `folders` (a project's, in a
    /// session), each file it names with "@" as the composer writes them; with `links`, each
    /// opening what it names.
    static func apply(to text: inout AttributedString, agents: [Agent], folders: [String] = [], links: Bool = true) {
        let plain = String(text.characters)
        guard plain.contains(AgentReferences.trigger) || (!folders.isEmpty && plain.contains("@")) else { return }
        var looks: [String: BotLook] = [:]
        for agent in agents { looks[agent.reference.session] = agent.look }
        var marks: [(range: Range<String.Index>, link: URL?, look: BotLook?)] = AgentReferences.find(in: plain, references: agents.map(\.reference)).map {
            ($0.range, link(to: $0.reference.session), looks[$0.reference.session])
        }
        if !folders.isEmpty {
            for (range, path) in files(in: plain) where !marks.contains(where: { $0.range.overlaps(range) }) {
                marks.append((range, FileLinks.file(named: path, folders: folders), nil))
            }
        }
        // Last first, so each leaves the places of those before it as they were.
        for mark in marks.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            let start = plain.distance(from: plain.startIndex, to: mark.range.lowerBound)
            let length = plain.distance(from: mark.range.lowerBound, to: mark.range.upperBound)
            let lower = text.characters.index(text.startIndex, offsetBy: start)
            let upper = text.characters.index(lower, offsetBy: length)
            if let look = mark.look { text[lower..<upper].swiftUI.foregroundColor = GroupMentions.ink(look) }
            text[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            if links, let link = mark.link { text[lower..<upper].link = link }
        }
    }

    /// Each "@path" in `text`, as the composer writes a file or folder: the "@" starting a word,
    /// then a path (with a "/" or a "."), without the punctuation that may end a sentence after it.
    static func files(in text: String) -> [(range: Range<String.Index>, path: String)] {
        var found: [(range: Range<String.Index>, path: String)] = []
        var index = text.startIndex
        while let at = text[index...].firstIndex(of: "@") {
            index = text.index(after: at)
            if at > text.startIndex, !text[text.index(before: at)].isWhitespace, text[text.index(before: at)] != "(" { continue }
            var end = text[index...].firstIndex(where: \.isWhitespace) ?? text.endIndex
            while end > index, ".,;:!?)\"'”’".contains(text[text.index(before: end)]) { end = text.index(before: end) }
            let path = String(text[index..<end])
            guard path.contains("/") || path.contains("."), path.contains(where: \.isLetter), !path.contains("@") else { continue }
            found.append((at..<end, path))
            index = end
        }
        return found
    }

    /// The address a named agent's link opens: its conversation.
    static func link(to session: String) -> URL? {
        URL(string: "kuvo-agent://" + session)
    }

    /// The conversation a link made by `link(to:)` opens.
    static func session(in url: URL) -> String? {
        url.scheme == "kuvo-agent" ? url.host() : nil
    }
}
