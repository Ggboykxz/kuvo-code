import Foundation
import SwiftUI
// Measuring a formula is SwiftUIMath's SPI for Textual, the same maker's: used as Textual uses it.
@_spi(Textual) import SwiftUIMath
import Textual

/// LaTeX in a reply, drawn as math: `$…$` and `\(…\)` in a line, `$$…$$` and `\[…\]` on their own.
///
/// Markdown would garble it first (`\\` read as an escape, `_` and `*` as emphasis, a line of `=`
/// as a heading's underline), so each formula is set aside before the Markdown is read: one of its
/// own becomes a code block the code block style draws as math, centered; one in a line, a mark,
/// put back after as a formula in the text. Formulas in code are left as they are, and so are
/// prices like "$5 and $10".
///
/// Math is always typeset at its own width: SwiftUIMath's line breaking, which Textual's own math
/// asks for, drops spaces and breaks superscripts off.
enum MathText {
    /// The language a formula of its own goes in, as a code block.
    static let blockLanguage = "kuvo-math"

    struct Formula: Equatable {
        let latex: String
        let isBlock: Bool
    }

    private static let open: Character = "\u{E000}"
    private static let close: Character = "\u{E001}"

    // MARK: Setting formulas aside

    /// `input` with each formula outside code swapped for a mark, and the formulas, in order.
    static func protect(_ input: String) -> (text: String, formulas: [Formula]) {
        // Most replies have none: nothing to do.
        guard input.contains("$") || input.contains("\\(") || input.contains("\\[") else { return (input, []) }
        var formulas: [Formula] = []
        var out = ""
        out.reserveCapacity(input.count)
        var chunk = ""
        var fence: String?
        for line in input.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            let marker = fenceMarker(trimmed)
            if let open = fence {
                out += line + "\n"
                if let marker, marker.first == open.first, marker.count >= open.count, trimmed.drop(while: { $0 == open.first }).allSatisfy(\.isWhitespace) { fence = nil }
            } else if let marker, line.prefix(while: { $0 == " " }).count < 4 {
                out += protectChunk(chunk, into: &formulas)
                chunk = ""
                out += line + "\n"
                fence = marker
            } else {
                chunk += line + "\n"
            }
        }
        out += protectChunk(chunk, into: &formulas)
        // The split added a line break after the last line.
        if out.hasSuffix("\n"), !input.hasSuffix("\n") { out.removeLast() }
        return (out, formulas)
    }

    /// The ``` or ~~~ that opens or closes a fenced code block, if the line starts with one.
    private static func fenceMarker(_ line: Substring) -> String? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let run = line.prefix { $0 == first }
        return run.count >= 3 ? String(run) : nil
    }

    /// One stretch of text between code blocks, its formulas set aside.
    private static func protectChunk(_ chunk: String, into formulas: inout [Formula]) -> String {
        guard !chunk.isEmpty else { return chunk }
        let chars = Array(chunk)
        var out = ""
        var i = 0
        func mark(_ latex: String, block: Bool) -> String {
            formulas.append(Formula(latex: latex.trimmingCharacters(in: .whitespacesAndNewlines), isBlock: block))
            return "\(open)\(formulas.count - 1)\(close)"
        }
        /// Where the line `index` is on starts.
        func lineStart(_ index: Int) -> Int {
            var start = index
            while start > 0, chars[start - 1] != "\n" { start -= 1 }
            return start
        }
        /// A formula of its own: on a line of its own, or after a label on one ("Integral:"), it
        /// goes in a block of its own. One in a list item or a quote stays in its line, so the
        /// item or quote holds together.
        func placeBlock(_ latex: String, from start: Int) {
            let prefix = String(chars[lineStart(start)..<start])
            let lead = prefix.trimmingCharacters(in: .whitespaces)
            let isItem = lead.hasPrefix(">") || lead.hasPrefix("- ") || lead.hasPrefix("* ") || lead.hasPrefix("+ ")
                || lead.range(of: #"^\d+[.)] "#, options: .regularExpression) != nil
            let latex = latex.trimmingCharacters(in: .whitespacesAndNewlines)
            if isItem || latex.contains("```") {
                out += mark(latex, block: true)
            } else {
                out += "\n\n```\(blockLanguage)\n\(latex)\n```\n\n"
            }
        }
        while i < chars.count {
            let c = chars[i]
            // Code in a line: as it is.
            if c == "`" {
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                if let end = closingBackticks(chars, from: i + run, count: run) {
                    out += String(chars[i..<(end + run)])
                    i = end + run
                } else {
                    out += String(repeating: "`", count: run)
                    i += run
                }
                continue
            }
            if c == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "(" || next == "[" {
                    let closer: [Character] = next == "(" ? ["\\", ")"] : ["\\", "]"]
                    if let end = find(closer, in: chars, from: i + 2, sameLine: next == "(") {
                        let latex = String(chars[(i + 2)..<end])
                        if next == "[" { placeBlock(latex, from: i) } else { out += mark(latex, block: false) }
                        i = end + 2
                        continue
                    }
                }
                // An escape (\$, \\ and the like): both as they are, for the Markdown to read.
                out.append(c)
                out.append(next)
                i += 2
                continue
            }
            if c == "$" {
                if i + 1 < chars.count, chars[i + 1] == "$" {
                    if let end = find(["$", "$"], in: chars, from: i + 2, sameLine: false), end > i + 2 {
                        placeBlock(String(chars[(i + 2)..<end]), from: i)
                        i = end + 2
                        continue
                    }
                    out += "$$"
                    i += 2
                    continue
                }
                if let end = inlineEnd(chars, from: i) {
                    out += mark(String(chars[(i + 1)..<end]), block: false)
                    i = end + 1
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// Where a run of `count` backticks closes a code span, on from `start`.
    private static func closingBackticks(_ chars: [Character], from start: Int, count: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "`" {
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                if run == count { return i }
                i += run
            } else {
                i += 1
            }
        }
        return nil
    }

    /// Where `closer` next starts, from `start` on (on the same line, if asked).
    private static func find(_ closer: [Character], in chars: [Character], from start: Int, sameLine: Bool) -> Int? {
        var i = start
        while i + closer.count <= chars.count {
            if sameLine, chars[i] == "\n" { return nil }
            if chars[i] == "\\", closer.first != "\\" {
                i += 2
                continue
            }
            if Array(chars[i..<(i + closer.count)]) == closer { return i }
            i += 1
        }
        return nil
    }

    /// The `$` that closes one opened at `start`, as Pandoc reads them: text right after the
    /// opening one and right before the closing one, on one line, and no digit right after (so
    /// "$5 and $10" stays prices).
    private static func inlineEnd(_ chars: [Character], from start: Int) -> Int? {
        guard start + 1 < chars.count, !chars[start + 1].isWhitespace, chars[start + 1] != "$" else { return nil }
        var i = start + 1
        // Not across a line, nor into code: "$10 and `$HOME`" is a price and code.
        while i < chars.count, chars[i] != "\n", chars[i] != "`" {
            if chars[i] == "\\" {
                i += 2
                continue
            }
            if chars[i] == "$" {
                let isClosing = !chars[i - 1].isWhitespace && (i + 1 >= chars.count || !chars[i + 1].isNumber)
                return isClosing ? i : nil
            }
            i += 1
        }
        return nil
    }

    // MARK: Putting them back

    /// Each mark in `text` swapped for its formula, drawn in the line.
    static func restore(_ text: inout AttributedString, _ formulas: [Formula]) {
        guard !formulas.isEmpty else { return }
        var searchFrom = text.startIndex
        while let start = text.characters[searchFrom...].firstIndex(of: open),
              let end = text.characters[start...].firstIndex(of: close) {
            let digits = String(text.characters[text.characters.index(after: start)..<end])
            let after = text.characters.index(after: end)
            guard let index = Int(digits), formulas.indices.contains(index) else {
                searchFrom = after
                continue
            }
            var formula = AttributedString("\u{FFFC}", attributes: text[start..<after].runs.first?.attributes ?? AttributeContainer())
            formula.textual.attachment = AnyAttachment(InlineMath(latex: formulas[index].latex, isDisplay: formulas[index].isBlock))
            text.replaceSubrange(start..<after, with: formula)
            searchFrom = text.index(start, offsetByCharacters: 1)
        }
    }

    /// Math the size of the text it's in: Textual's 1.2 times, as its own math is.
    nonisolated static let scale: CGFloat = 1.2

    /// A font size a hair from `size` at which `latex` is a whole number of half points wide.
    /// SwiftUIMath draws a formula in a canvas as wide as it measured, then typesets it again for
    /// that width, which it finds in its cache by the width rounded to half points; a canvas a
    /// pixel narrower or wider than the formula misses it, and the formula is set again to fit,
    /// which breaks a superscript off and squashes it. At a width of whole half points, the
    /// canvas is exactly that wide and the cache has it.
    nonisolated static func drawingSize(for latex: String, near size: CGFloat, display: Bool) -> CGFloat {
        var size = size
        for _ in 0..<3 {
            let width = Math.typographicBounds(for: latex, fitting: .unspecified, font: .init(name: .latinModern, size: size), style: display ? .display : .text).width
            guard width > 0 else { return size }
            let target = (width * 2).rounded(.up) / 2
            if target - width < 0.001 { return size }
            size *= target / width
        }
        return size
    }
}

/// A formula in a line of text. Measured and drawn at its own width; drawn larger than it shows,
/// as the text's own size isn't known where it's drawn, and scaled down into its place.
struct InlineMath: Attachment {
    let latex: String
    /// Set as a formula of its own is (larger operators, limits above and below).
    let isDisplay: Bool

    var description: String { isDisplay ? "$$\(latex)$$" : "$\(latex)$" }
    var selectionStyle: AttachmentSelectionStyle { .text }

    private static let drawnSize: CGFloat = 40

    var body: some View {
        Math(latex)
            .mathFont(.init(name: .latinModern, size: MathText.drawingSize(for: latex, near: Self.drawnSize, display: isDisplay)))
            .mathTypesettingStyle(isDisplay ? .display : .text)
            .mathRenderingMode(.monochrome)
            .fixedSize()
    }

    func baselineOffset(in environment: TextEnvironmentValues) -> CGFloat {
        -bounds(in: environment).descent
    }

    func sizeThatFits(_ proposal: ProposedViewSize, in environment: TextEnvironmentValues) -> CGSize {
        bounds(in: environment).size
    }

    private func bounds(in environment: TextEnvironmentValues) -> Math.TypographicBounds {
        Math.typographicBounds(
            for: latex,
            fitting: .unspecified,
            font: .init(name: .latinModern, size: FontScaled(MathText.scale).resolve(in: environment)),
            style: isDisplay ? .display : .text
        )
    }
}

/// A formula of its own, in the code block a reply's `$$…$$` became: centered at the size of the
/// text around it, and scrolling sideways when it's wider than the reply.
struct MathBlockView: View {
    let latex: String
    @Environment(\.messageFont) private var font

    var body: some View {
        let formula = Math(latex)
            .mathFont(.init(name: .latinModern, size: MathText.drawingSize(for: latex, near: font.size * MathText.scale, display: true)))
            .mathTypesettingStyle(.display)
            .mathRenderingMode(.monochrome)
            .fixedSize()
            .accessibilityLabel(latex)
        ViewThatFits(in: .horizontal) {
            formula
                .frame(maxWidth: .infinity)
            ScrollView(.horizontal) {
                formula
            }
            .scrollIndicators(.automatic)
        }
        .padding(.vertical, 6)
    }
}

/// Markdown with its math drawn (a file's preview); replies use `FileLinkingParser`, which does
/// the same.
struct MathMarkdownParser: MarkupParser {
    func attributedString(for input: String) throws -> AttributedString {
        let (protected, formulas) = MathText.protect(input)
        var text = try AttributedStringMarkdownParser.markdown().attributedString(for: protected)
        MathText.restore(&text, formulas)
        return text
    }
}
