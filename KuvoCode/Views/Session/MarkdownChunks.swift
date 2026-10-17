import Foundation

/// A long reply in pieces of a few thousand characters, split between paragraphs, each drawn on its
/// own. While it streams in, only the last piece changes, so only it is read and laid out again
/// (Textual reads and lays out all of a text each time it changes, which takes longer the longer
/// the reply gets). The pieces follow from the text alone, the same while it streams and after.
nonisolated enum MarkdownChunks {
    struct Chunk: Equatable {
        /// Its Markdown, after the link definitions (`[1]: https://…`) from the rest of the text: a
        /// piece is read on its own, and its links may use them.
        var text: String
        /// The space above it, as the Markdown style puts between the blocks either side.
        var gap: CGFloat
        /// Where the language of a code block still being written is (it ends inside one).
        var writing: Range<String.Index>?
    }

    /// About how long a piece gets before the next one starts.
    static let size = 4000

    /// `text` in pieces, split only where a paragraph or heading starts after a paragraph,
    /// heading or code block has ended: blocks a split can't change (not inside a list, quote,
    /// table or code block), with the space between them known.
    static func split(_ text: String, size: Int = size) -> [Chunk] {
        var pieces: [(range: Range<String.Index>, gap: CGFloat)] = []
        var start = text.startIndex
        var gap: CGFloat = 0
        var length = 0
        var fence: (marker: Character, count: Int)?
        var blank = true
        // The block since the last blank line is one a split can come after: paragraphs and
        // headings at the left edge, or a code block (a list's lines needn't be indented).
        var blockIsSafe = false
        // The language of the code block being read.
        var language: Range<String.Index>?
        // Link definitions, which count for all of the text, wherever they are.
        var definitions: [Range<String.Index>] = []
        var afterDefinition = false
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            // Only whole lines: the last one may still be streaming in.
            guard let newline = text[lineStart...].firstIndex(of: "\n") else { break }
            let line = text[lineStart..<newline]
            var counts = true
            defer {
                if counts { length += line.utf8.count + 1 }
                lineStart = text.index(after: newline)
            }
            let trimmed = line.drop { $0 == " " }
            let indent = line.count - trimmed.count
            if let open = fence {
                // Closed by the same marker, at least as long.
                if indent < 4, trimmed.prefix(while: { $0 == open.marker }).count >= open.count,
                   trimmed.drop(while: { $0 == open.marker }).allSatisfy(\.isWhitespace) {
                    fence = nil
                    language = nil
                    blockIsSafe = true
                }
                continue
            }
            if trimmed.allSatisfy(\.isWhitespace) {
                blank = true
                continue
            }
            if blank, blockIsSafe, length >= size, startsSafely(trimmed, indent: indent) {
                pieces.append((start..<lineStart, gap))
                start = lineStart
                gap = trimmed.first == "#" ? 24 : 16
                length = 0
            }
            let startsBlock = blank
            blank = false
            // One starts a block or follows another (under a paragraph's line, it's part of it).
            afterDefinition = (startsBlock || afterDefinition) && indent < 4 && isDefinition(trimmed)
            if afterDefinition {
                definitions.append(line.startIndex..<line.endIndex)
                // Not counted, as they go ahead of other pieces: a piece split again (a row's
                // words, drawn) splits where it did here.
                counts = false
            }
            if indent < 4, let marker = trimmed.first, marker == "`" || marker == "~", trimmed.prefix(while: { $0 == marker }).count >= 3 {
                let count = trimmed.prefix { $0 == marker }.count
                fence = (marker, count)
                let info = trimmed.dropFirst(count).drop { $0 == " " }
                language = info.startIndex..<info.startIndex
                blockIsSafe = false
                continue
            }
            let safe = indent == 0 && isParagraphOrHeading(trimmed)
            blockIsSafe = startsBlock ? safe : blockIsSafe && safe
        }
        // The last line can be one too, though it may still be streaming in.
        if fence == nil, lineStart < text.endIndex, blank || afterDefinition {
            let line = text[lineStart...]
            let trimmed = line.drop { $0 == " " }
            if line.count - trimmed.count < 4, isDefinition(trimmed) { definitions.append(line.startIndex..<line.endIndex) }
        }
        pieces.append((start..<text.endIndex, gap))
        return pieces.indices.map { index in
            let piece = pieces[index]
            // Those elsewhere in the text go ahead of it (Markdown shows nothing for them).
            let elsewhere = definitions.filter { !piece.range.contains($0.lowerBound) }
            let ahead = elsewhere.isEmpty ? "" : elsewhere.map { text[$0] }.joined(separator: "\n") + "\n\n"
            let own = pieces.count == 1 ? text : String(text[piece.range])
            var chunk = Chunk(text: ahead.isEmpty ? own : ahead + own, gap: piece.gap)
            if index == pieces.count - 1, fence != nil, let language {
                let offset = ahead.utf8.count + text.utf8.distance(from: piece.range.lowerBound, to: language.lowerBound)
                let at = chunk.text.utf8.index(chunk.text.utf8.startIndex, offsetBy: offset)
                chunk.writing = at..<at
            }
            return chunk
        }
    }

    /// The text of `chunk`, with `mark` before the language of the code block it's still writing:
    /// Textual colors code with a language again each time it changes (showing it plain
    /// meanwhile), so it waits until the block is done.
    static func text(of chunk: Chunk, marking mark: String) -> String {
        guard let writing = chunk.writing else { return chunk.text }
        return String(chunk.text[..<writing.lowerBound]) + mark + String(chunk.text[writing.lowerBound...])
    }

    /// A line that starts a paragraph, a heading or a code block, whatever comes after it.
    private static func startsSafely(_ line: Substring, indent: Int) -> Bool {
        guard indent == 0, let first = line.first else { return false }
        if first == "`" || first == "~" { return line.prefix { $0 == first }.count >= 3 }
        return isParagraphOrHeading(line)
    }

    /// A link definition on one line: `[label]: destination`, and maybe a title in quotes or
    /// parentheses (not a footnote's, `[^1]: …`).
    private static func isDefinition(_ line: Substring) -> Bool {
        guard line.first == "[", let close = line.firstIndex(of: "]") else { return false }
        let label = line[line.index(after: line.startIndex)..<close]
        guard label.first != "^", !label.contains("["), !label.allSatisfy(\.isWhitespace),
              line[line.index(after: close)...].first == ":" else { return false }
        var rest = line[line.index(close, offsetBy: 2)...].drop { $0 == " " || $0 == "\t" }
        if rest.first == "<" {
            guard let end = rest.firstIndex(of: ">") else { return false }
            rest = rest[rest.index(after: end)...]
        } else {
            let destination = rest.prefix { !$0.isWhitespace }
            guard !destination.isEmpty else { return false }
            rest = rest[destination.endIndex...]
        }
        guard !rest.allSatisfy(\.isWhitespace) else { return true }
        guard rest.first?.isWhitespace == true else { return false }
        let title = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 2, let open = title.first, let end = title.last else { return false }
        return open == "\"" && end == "\"" || open == "'" && end == "'" || open == "(" && end == ")"
    }

    /// Not a list item, quote, table row, HTML, link definition or rule (or a heading's underline).
    private static func isParagraphOrHeading(_ line: Substring) -> Bool {
        guard let first = line.first else { return false }
        if first == "#" { return line.drop { $0 == "#" }.first.map { $0 == " " } ?? true }
        if [">", "|", "<", "[", "`", "~", "$"].contains(first) { return false }
        if "-*+_=".contains(first) {
            // "- item", "* item", "+ item", or a rule or underline ("---", "***", "===").
            if line.dropFirst().first == " " || line.allSatisfy({ $0 == first || $0 == " " }) { return false }
        }
        // "1. item", "2) item".
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count < 10, let after = line.dropFirst(digits.count).first, after == "." || after == ")" {
            return false
        }
        return true
    }
}
