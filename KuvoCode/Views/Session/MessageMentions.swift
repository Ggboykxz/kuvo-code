import AppKit
import os
import SwiftUI
import Textual

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

    /// What stands for an agent's "&": a bot's face, or a conversation's mark, before its name.
    enum Marks {
        /// In SwiftUI's Text (your bubbles, the queue): the "&" is marked (`AgentMark`), and
        /// `text(_:size:)` draws it as a picture.
        case inline
        /// In Textual's (a bot's message): an attachment in its place.
        case attachments
    }

    /// Styles in `text` each of `agents` it names with "&", its "&" made its face or mark, and with
    /// `folders` (a project's, in a session), each file it names with "@" as the composer writes
    /// them; with `links`, each opening what it names.
    static func apply(to text: inout AttributedString, agents: [Agent], folders: [String] = [], links: Bool = true, marks drawn: Marks = .inline) {
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
            // An agent's "&" (a file's "@" stays): its face, or a conversation's mark.
            guard let session = mark.link.flatMap(Self.session(in:)), text.characters[lower] == AgentReferences.trigger else { continue }
            let amp = lower..<text.characters.index(after: lower)
            switch drawn {
            case .inline:
                text[amp][AgentMark.self] = Agent(reference: .init(name: "", session: session), look: mark.look)
            case .attachments:
                var face = AttributedString("\u{FFFC}", attributes: text[amp].runs.first?.attributes ?? AttributeContainer())
                face.link = nil
                face.textual.attachment = mark.look.map { AnyAttachment(MentionFace(look: $0)) } ?? AnyAttachment(ConversationMark())
                text.replaceSubrange(amp, with: face)
            }
        }
    }

    /// `attributed` as SwiftUI's Text, each marked "&" drawn as its face or mark, `size` points,
    /// and its links marked for `LinkPointer`.
    @MainActor static func text(_ attributed: AttributedString, size: CGFloat) -> Text {
        guard attributed.runs.contains(where: { $0[AgentMark.self] != nil || $0.link != nil }) else { return Text(attributed) }
        var pieces: [Text] = []
        for run in attributed.runs {
            guard let agent = run[AgentMark.self] else {
                let piece = Text(AttributedString(attributed[run.range]))
                pieces.append(run.link == nil ? piece : piece.customAttribute(LinkRun()))
                continue
            }
            if let look = agent.look, let face = face(look, size: size) {
                pieces.append(Text("\(Image(nsImage: face))").baselineOffset(-size * 0.2))
            } else {
                pieces.append(Text("\(Image(systemName: "bubble.left"))").font(.system(size: size * 0.82)).foregroundStyle(.secondary))
            }
        }
        return pieces.reduce(Text("")) { Text("\($0)\($1)") }
    }

    /// A bot's face as a picture of `size` points, drawn once for each look and size.
    @MainActor private static func face(_ look: BotLook, size: CGFloat) -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let key = "\(look.hashValue) \(size) \(scale)"
        if let known = faces[key] { return known }
        let renderer = ImageRenderer(content: BotAvatar(look: look, size: size, animates: false).frame(width: size, height: size))
        renderer.scale = scale
        guard let image = renderer.nsImage else { return nil }
        faces[key] = image
        return image
    }

    @MainActor private static var faces: [String: NSImage] = [:]

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

/// The pointing hand over a link in a text made by `MessageMentions.text(_:size:)`, as over a
/// link anywhere else (SwiftUI's Text shows none). Only for a text with links in it.
struct LinkPointer: ViewModifier {
    var isOn: Bool
    @State private var places = OSAllocatedUnfairLock<[CGRect]>(initialState: [])
    @State private var isOver = false

    func body(content: Content) -> some View {
        if isOn {
            content
                .textRenderer(LinkPlaces(places: places))
                .onContinuousHover { phase in
                    var over = false
                    if case .active(let point) = phase { over = places.withLock { $0.contains { $0.contains(point) } } }
                    if over != isOver { isOver = over }
                }
                .pointerStyle(isOver ? .link : nil)
        } else {
            content
        }
    }
}

/// A run of a link, for `LinkPointer`.
nonisolated struct LinkRun: TextAttribute {}

/// Draws a text as it is, keeping where its links are.
nonisolated private struct LinkPlaces: TextRenderer {
    let places: OSAllocatedUnfairLock<[CGRect]>

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var found: [CGRect] = []
        for line in layout {
            for run in line {
                if run[LinkRun.self] != nil { found.append(run.typographicBounds.rect) }
                context.draw(run)
            }
        }
        let kept = found
        places.withLock { $0 = kept }
    }
}

/// An agent's "&" in a bubble, which `MessageMentions.text(_:size:)` draws as its face or mark.
nonisolated enum AgentMark: AttributedStringKey {
    typealias Value = MessageMentions.Agent
    static let name = "kuvo.agentMark"
}

/// A conversation's mark in a line of Textual's text, where its "&" was (a bot's is its face).
nonisolated struct ConversationMark: Attachment {
    var description: String { "&" }
    var selectionStyle: AttachmentSelectionStyle { .text }

    var body: some View {
        Image(systemName: "bubble.left")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
    }

    func baselineOffset(in environment: TextEnvironmentValues) -> CGFloat {
        FontScaled<CGFloat>.fontScaled(-0.15).resolve(in: environment)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, in environment: TextEnvironmentValues) -> CGSize {
        FontScaled<CGSize>.fontScaled(width: 0.9, height: 0.9).resolve(in: environment)
    }
}
