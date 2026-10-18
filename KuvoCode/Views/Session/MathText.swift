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

    /// The formulas set aside from a text, in order, and the two characters around a formula's
    /// number where it was: ones the text has nowhere, so none of its own is read as a mark.
    struct Formulas: Equatable {
        var list: [Formula] = []
        fileprivate var open: Character = "\u{E000}"
        fileprivate var close: Character = "\u{E001}"

        var isEmpty: Bool { list.isEmpty }
    }

    // MARK: Setting formulas aside

    /// `input` with each formula outside code swapped for a mark, and the formulas, in order.
    static func protect(_ input: String) -> (text: String, formulas: Formulas) {
        // Most replies have none: nothing to do.
        guard input.contains("$") || input.contains("\\(") || input.contains("\\[") else { return (input, Formulas()) }
        var formulas = Formulas()
        (formulas.open, formulas.close) = marks(for: input)
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

    /// Two private-use characters `text` doesn't have, nor writes as `&#…;` (which Markdown turns
    /// into the character).
    private static func marks(for text: String) -> (Character, Character) {
        var used: Set<UInt32> = []
        for scalar in text.unicodeScalars where (0xE000...0xF8FF).contains(scalar.value) { used.insert(scalar.value) }
        if text.contains("&#") {
            for match in text.matches(of: /&#(?:[xX]([0-9a-fA-F]{1,6})|([0-9]{1,7}));/) {
                if let value = match.1.flatMap({ UInt32($0, radix: 16) }) ?? match.2.flatMap({ UInt32($0) }) { used.insert(value) }
            }
        }
        var value: UInt32 = 0xE000
        while used.contains(value) || used.contains(value + 1) { value += 2 }
        return (Character(Unicode.Scalar(value)!), Character(Unicode.Scalar(value + 1)!))
    }

    /// The ``` or ~~~ that opens or closes a fenced code block, if the line starts with one.
    private static func fenceMarker(_ line: Substring) -> String? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let run = line.prefix { $0 == first }
        return run.count >= 3 ? String(run) : nil
    }

    /// One stretch of text between code blocks, its formulas set aside.
    private static func protectChunk(_ chunk: String, into formulas: inout Formulas) -> String {
        guard !chunk.isEmpty else { return chunk }
        let chars = Array(chunk)
        var out = ""
        var i = 0
        func mark(_ latex: String, block: Bool) -> String {
            formulas.list.append(Formula(latex: latex.trimmingCharacters(in: .whitespacesAndNewlines), isBlock: block))
            return "\(formulas.open)\(formulas.list.count - 1)\(formulas.close)"
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

    /// Each mark in `text` swapped for its formula, drawn in the line. The marks are found in a
    /// plain copy of the text's bytes, which is quick, rather than by walking its characters,
    /// which works out where each one ends at every step (a long reply is read again with each
    /// streamed word); and replaced last first, so the ones before keep their place.
    static func restore(_ text: inout AttributedString, _ formulas: Formulas) {
        guard !formulas.isEmpty else { return }
        let opening = Array(String(formulas.open).utf8), closing = Array(String(formulas.close).utf8)
        var marks: [(start: Int, end: Int, formula: Formula)] = []
        var plain = String(text.characters)
        plain.withUTF8 { bytes in
            func matches(_ mark: [UInt8], at i: Int) -> Bool {
                i + mark.count <= bytes.count && mark.indices.allSatisfy { bytes[i + $0] == mark[$0] }
            }
            var i = 0
            while i < bytes.count {
                guard bytes[i] == opening[0], matches(opening, at: i) else {
                    i += 1
                    continue
                }
                // No more digits than a number of formulas has, so it never overflows.
                let digits = i + opening.count
                var j = digits, index = 0
                while j < bytes.count, j - digits < 10, (0x30...0x39).contains(bytes[j]) {
                    index = index * 10 + Int(bytes[j] - 0x30)
                    j += 1
                }
                if j > digits, matches(closing, at: j), formulas.list.indices.contains(index) {
                    marks.append((i, j + closing.count, formulas.list[index]))
                    i = j + closing.count
                } else {
                    i += opening.count
                }
            }
        }
        for mark in marks.reversed() {
            let start = text.utf8.index(text.startIndex, offsetBy: mark.start)
            let end = text.utf8.index(start, offsetBy: mark.end - mark.start)
            var formula = AttributedString("\u{FFFC}", attributes: text[start..<end].runs.first?.attributes ?? AttributeContainer())
            formula.textual.attachment = AnyAttachment(InlineMath(latex: mark.formula.latex, isDisplay: mark.formula.isBlock))
            text.replaceSubrange(start..<end, with: formula)
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
///
/// It's centered on a whole pixel: centered between two, its edges are rounded to pixels and it's
/// drawn a pixel narrower or wider than it measured, which SwiftUIMath sets again to fit, breaking
/// it onto a second line its height has no room for.
struct MathBlockView: View {
    let latex: String
    @Environment(\.messageFont) private var font
    @Environment(\.displayScale) private var displayScale
    @State private var room: CGFloat = 0

    var body: some View {
        let size = MathText.drawingSize(for: latex, near: font.size * MathText.scale, display: true)
        let width = Math.typographicBounds(for: latex, fitting: .unspecified, font: .init(name: .latinModern, size: size), style: .display).width
        let formula = Math(latex)
            .mathFont(.init(name: .latinModern, size: size))
            .mathTypesettingStyle(.display)
            .mathRenderingMode(.monochrome)
            .fixedSize()
            .accessibilityLabel(latex)
        ViewThatFits(in: .horizontal) {
            formula
                .padding(.leading, (max(0, room - width) / 2 * displayScale).rounded(.down) / displayScale)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal) {
                formula
            }
            .scrollIndicators(.automatic)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0 }
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
