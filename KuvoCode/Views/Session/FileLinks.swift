import Foundation
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
        guard !path.isEmpty, path != ".", path != ".." else { return nil }
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

/// Textual's Markdown, with code spans that name a file made links to it. (Done on the parsed
/// text: Markdown's own `[`code`](link)` loses the code look.)
struct FileLinkingParser: MarkupParser {
    /// Asked when parsing rather than while the view updates, so replies don't redraw each
    /// time the project's settings change.
    let folders: () -> [String]

    func attributedString(for input: String) throws -> AttributedString {
        var text = try AttributedStringMarkdownParser.markdown().attributedString(for: input)
        guard text.runs.contains(where: { $0.inlinePresentationIntent?.contains(.code) == true }) else { return text }
        let folders = folders()
        var links: [(Range<AttributedString.Index>, URL)] = []
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true && run.link == nil {
            if let url = FileLinks.file(named: String(text[run.range].characters), folders: folders) {
                links.append((run.range, url))
            }
        }
        for (range, url) in links { text[range].link = url }
        return text
    }
}
