import Foundation
import SwiftUI
import Textual

/// File names a reply writes as code (`src/App.swift`, `App.swift:42`) become links that open
/// the file in the side panel, when it's in one of the project's folders.
nonisolated enum FileLinks {
    /// The file a code span names, if it's one: a path with an optional line ("file.swift:12",
    /// "file.swift:12-20" or "file.swift#L12"), relative to one of `folders`, or absolute.
    static func file(named span: String, folders: [String]) -> URL? {
        guard !span.contains(where: \.isWhitespace), !span.contains("://"),
              span.contains("/") || span.contains(".") else { return nil }
        let path = span.replacing(/(:\d+(-\d+)?|#L\d+(-L?\d+)?)$/, with: "")
        // A name has a letter in it: not "1.2.3" or "..".
        guard (path as NSString).lastPathComponent.contains(where: \.isLetter) else { return nil }
        // A reply is read again on every word that streams in; the disk is asked at most every
        // few seconds per name (a file the agent is about to create links once it exists).
        let key = folders.joined(separator: "\n") + "\u{0}" + path as NSString
        if let known = cache.object(forKey: key), Date().timeIntervalSince(known.checked) < 5 { return known.url }
        let url = find(path, folders: folders)
        cache.setObject(Known(url: url), forKey: key)
        return url
    }

    private final class Known {
        let url: URL?
        let checked = Date()
        init(url: URL?) { self.url = url }
    }

    /// NSCache is thread-safe.
    nonisolated(unsafe) private static let cache: NSCache<NSString, Known> = {
        let cache = NSCache<NSString, Known>()
        cache.countLimit = 2000
        return cache
    }()

    private static func find(_ path: String, folders: [String]) -> URL? {
        var candidates: [String] = []
        if path.hasPrefix("/") {
            candidates = [path]
        } else if path.hasPrefix("~/") {
            candidates = [NSHomeDirectory() + path.dropFirst()]
        } else {
            for folder in folders {
                candidates.append(folder + "/" + path)
                // Another folder's files by its name ("api/README.md"), as "@" writes them.
                let name = (folder as NSString).lastPathComponent
                if path.hasPrefix(name + "/") { candidates.append((folder as NSString).deletingLastPathComponent + "/" + path) }
            }
        }
        for candidate in candidates {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isFolder), !isFolder.boolValue {
                return URL(filePath: candidate)
            }
        }
        return nil
    }
}

/// Textual's Markdown, with code spans that name a file made links to it, drawn as a file: an
/// icon and its name ("App.swift:42"), in link color rather than as code.
struct FileLinkingParser: MarkupParser {
    /// Asked when parsing rather than while the view updates, so replies don't redraw each
    /// time the project's settings change.
    let folders: () -> [String]
    /// In a group chat, its bots: "@Name" shows their face and color.
    var mentions: [Bot] = []

    func attributedString(for input: String) throws -> AttributedString {
        #if DEBUG
        let began = ContinuousClock.now
        defer { ParseClock.add(ContinuousClock.now - began) }
        #endif
        var text = try AttributedStringMarkdownParser.markdown().attributedString(for: input)
        if !mentions.isEmpty { GroupMentions.apply(to: &text, bots: mentions, faces: true) }
        guard text.runs.contains(where: { $0.inlinePresentationIntent?.contains(.code) == true }) else { return text }
        let folders = folders()
        var links: [(Range<AttributedString.Index>, URL)] = []
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true && run.link == nil {
            if let url = FileLinks.file(named: String(text[run.range].characters), folders: folders) {
                links.append((run.range, url))
            }
        }
        // From the end, so the earlier ranges still point where they did.
        for (range, url) in links.reversed() {
            var attributes = text[range].runs.first?.attributes ?? AttributeContainer()
            var intent = attributes.inlinePresentationIntent ?? []
            intent.remove(.code)
            attributes.inlinePresentationIntent = intent.isEmpty ? nil : intent
            attributes.link = url
            var name = AttributedString(Self.label(String(text[range].characters)), attributes: attributes)
            // The icon goes before the link, not in it: Textual draws attachments only outside links.
            var icon = AttributedString("\u{FFFC}", attributes: attributes)
            icon.link = nil
            icon.textual.attachment = AnyAttachment(FileIconAttachment())
            var gap = AttributedString(" ", attributes: attributes)
            gap.link = nil
            name.insert(icon + gap, at: name.startIndex)
            text.replaceSubrange(range, with: name)
        }
        return text
    }

    /// What a link shows: the file's name and any line, as "App.swift:42" for "src/App.swift:42".
    static func label(_ written: String) -> String {
        guard let slash = written.lastIndex(of: "/"), written.index(after: slash) < written.endIndex else { return written }
        return String(written[written.index(after: slash)...])
    }
}

/// The document icon before a file's name in a reply, in link color like the name.
struct FileIconAttachment: Attachment {
    var description: String { "" }
    var selectionStyle: AttachmentSelectionStyle { .text }

    // Drawn scaled into its slot in the text, so no frame of its own.
    var body: some View {
        Image(systemName: "doc")
            .resizable()
            .fontWeight(.light)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(.tint)
    }

    func baselineOffset(in environment: TextEnvironmentValues) -> CGFloat {
        FontScaled<CGFloat>.fontScaled(-0.12).resolve(in: environment)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, in environment: TextEnvironmentValues) -> CGSize {
        FontScaled<CGSize>.fontScaled(width: 0.78, height: 0.92).resolve(in: environment)
    }
}

#if DEBUG
/// How long parsing replies takes, for the scrolling test.
nonisolated enum ParseClock {
    nonisolated(unsafe) static var total = Duration.zero
    nonisolated(unsafe) static var count = 0
    static func add(_ time: Duration) {
        total += time
        count += 1
    }
}
#endif
