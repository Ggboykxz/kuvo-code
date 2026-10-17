import Foundation

/// A long reply in pieces of a few thousand characters, split between paragraphs, each drawn on its
/// own. While it streams in, only the last piece changes, so only it is read and laid out again
/// (Textual reads and lays out all of a text each time it changes, which takes longer the longer
/// the reply gets). The pieces follow from the text alone, the same while it streams and after.
nonisolated enum MarkdownChunks {
    struct Chunk: Equatable {
        var text: Substring
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
        var chunks: [Chunk] = []
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
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            // Only whole lines: the last one may still be streaming in.
            guard let newline = text[lineStart...].firstIndex(of: "\n") else { break }
            let line = text[lineStart..<newline]
            defer {
                length += line.utf8.count + 1
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
                chunks.append(Chunk(text: text[start..<lineStart], gap: gap))
                start = lineStart
                gap = trimmed.first == "#" ? 24 : 16
                length = 0
            }
            let startsBlock = blank
            blank = false
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
        chunks.append(Chunk(text: text[start...], gap: gap, writing: fence == nil ? nil : language))
        return chunks
    }

    /// The text of `chunk`, with `mark` before the language of the code block it's still writing:
    /// Textual colors code with a language again each time it changes (showing it plain
    /// meanwhile), so it waits until the block is done.
    static func text(of chunk: Chunk, marking mark: String) -> String {
        guard let writing = chunk.writing else { return String(chunk.text) }
        return String(chunk.text[..<writing.lowerBound]) + mark + String(chunk.text[writing.lowerBound...])
    }

    /// A line that starts a paragraph, a heading or a code block, whatever comes after it.
    private static func startsSafely(_ line: Substring, indent: Int) -> Bool {
        guard indent == 0, let first = line.first else { return false }
        if first == "`" || first == "~" { return line.prefix { $0 == first }.count >= 3 }
        return isParagraphOrHeading(line)
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
