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
/// prices like "$5 and $10". The text around them keeps its shape: a formula in a list item, a
/// quote or a table stays in it, and one SwiftUIMath can't draw shows as it was written.
///
/// Math is always typeset at its own width: SwiftUIMath's line breaking, which Textual's own math
/// asks for, drops spaces and breaks superscripts off.
enum MathText {
    /// The language a formula of its own goes in, as a code block.
    nonisolated static let blockLanguage = "kuvo-math"

    nonisolated struct Formula: Equatable {
        /// As written, with its dollar signs or brackets.
        let source: String
        let latex: String
        let isBlock: Bool
        /// The LaTeX SwiftUIMath draws (see `drawable`); nil when it can't, and `source` shows.
        let drawn: String?
    }

    /// The formulas set aside from a text, in order, and the two characters around a formula's
    /// number where it was: ones the text has nowhere, so none of its own is read as a mark.
    nonisolated struct Formulas: Equatable {
        var list: [Formula] = []
        fileprivate var open: Character = "\u{E000}"
        fileprivate var close: Character = "\u{E001}"

        var isEmpty: Bool { list.isEmpty }
    }

    // MARK: Setting formulas aside

    /// `input` with each formula outside code swapped for a mark, and the formulas, in order.
    nonisolated static func protect(_ input: String) -> (text: String, formulas: Formulas) {
        // Most replies have none: nothing to do.
        guard input.contains("$") || input.contains("\\(") || input.contains("\\[") else { return (input, Formulas()) }
        // A Windows line end is one Character in Swift ("\r\n"), which a line break alone isn't.
        let text = input.utf8.contains(13) ? input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") : input
        var formulas = Formulas()
        (formulas.open, formulas.close) = marks(for: text)
        let chars = Array(text)
        let lines = lines(of: chars)
        var out = ""
        out.reserveCapacity(chars.count)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.isCode || line.isBlank {
                out += String(chars[line.start..<line.end])
                if line.end < chars.count { out += "\n" }
                index += 1
                continue
            }
            // A run of lines with words, which a formula can't run out of.
            var last = index
            while last + 1 < lines.count, !lines[last + 1].isCode, !lines[last + 1].isBlank { last += 1 }
            out += protect(chars, lines, index...last, into: &formulas)
            if lines[last].end < chars.count { out += "\n" }
            index = last + 1
        }
        return out == text ? (input, formulas) : (out, formulas)
    }

    /// Two private-use characters `text` doesn't have, nor writes as `&#…;` (which Markdown turns
    /// into the character).
    nonisolated private static func marks(for text: String) -> (Character, Character) {
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

    /// A line of the text, as far as its formulas go.
    nonisolated private struct Line {
        var start: Int
        var end: Int
        /// Where its words start, after any quote marks and indentation.
        var body: Int
        /// How many quotes it's in.
        var depth = 0
        /// In a code block, or one's fence: left as it is.
        var isCode = false
        var isBlank = false
        /// In a formula of its own that started on a line of its own above, and ends on this one
        /// or one below: math, however it looks as Markdown ("+ x" isn't a list item).
        var isMath = false
        /// Starts a list item ("- ", "1. ").
        var startsItem = false
        /// Carries on a paragraph without the indentation or quote marks of the list item or
        /// quote it's in.
        var isLazy = false
        /// A table row or a heading: a formula on it ends on it, in the line.
        var isOneLine = false
        /// Indented a code block's worth past its list item, or the left edge (or in a list in a
        /// quote, which isn't followed that far).
        var isDeep = false
        /// In a list item, or in a quote that has one.
        var inList = false

        /// A formula of its own can be a block here, in a fence indented as the line is.
        var takesBlock: Bool { !isOneLine && !startsItem && !isLazy && !isDeep }
        /// Not in a list item or quote: a block goes in at the left edge, between blank lines.
        var isTopLevel: Bool { depth == 0 && !inList }
    }

    /// The lines of `chars`, read as Markdown reads its blocks, enough to tell code, list items,
    /// quotes, tables and formulas of their own apart.
    nonisolated private static func lines(of chars: [Character]) -> [Line] {
        var ranges: [Range<Int>] = []
        var start = 0
        for (index, character) in chars.enumerated() where character == "\n" {
            ranges.append(start..<index)
            start = index + 1
        }
        ranges.append(start..<chars.count)

        var lines: [Line] = []
        lines.reserveCapacity(ranges.count)
        var fence: (marker: Character, count: Int, depth: Int)?
        // The content columns of the open list items, innermost last (out of quotes).
        var items: [Int] = []
        // A list item seen in the quote being read.
        var quoteHasList = false
        // The quote depth of the paragraph being read, when one is.
        var paragraph: Int?
        var inTable = false
        var depthBefore = 0
        // The last line of a formula of its own being read.
        var mathUntil = -1
        for (number, range) in ranges.enumerated() {
            let (depth, quoteColumn, indent, body) = prefix(of: chars, range)
            var line = Line(start: range.lowerBound, end: range.upperBound, body: body, depth: depth)
            let rest = chars[body..<range.upperBound]
            if number <= mathUntil {
                line.isMath = true
                lines.append(line)
                continue
            }
            if let open = fence {
                if line.depth >= open.depth {
                    line.isCode = true
                    let run = rest.prefix { $0 == open.marker }.count
                    if run >= open.count, rest.dropFirst(run).allSatisfy(\.isWhitespace) { fence = nil }
                    lines.append(line)
                    continue
                }
                // Its quote ended, and the code with it.
                fence = nil
            }
            if rest.isEmpty {
                line.isBlank = true
                paragraph = nil
                inTable = false
                lines.append(line)
                continue
            }

            let fenceRun = rest.first == "`" || rest.first == "~" ? rest.prefix { $0 == rest.first }.count : 0
            let opensFence = fenceRun >= 3 && !(rest.first == "`" && rest.dropFirst(fenceRun).contains("`"))
            let isHeading = rest.first == "#" && {
                let hashes = rest.prefix { $0 == "#" }.count
                return hashes <= 6 && (hashes == rest.count || rest.dropFirst(hashes).first.map { $0 == " " || $0 == "\t" } == true)
            }()
            let isBreak = rest.first.map { "-*_".contains($0) } == true
                && rest.allSatisfy { $0 == rest.first || $0 == " " || $0 == "\t" } && rest.filter { $0 == rest.first }.count >= 3
            let marker = isBreak ? nil : listMarker(rest, indent: indent)
            // A list's first item interrupts a paragraph only with words, and numbered from 1.
            let markerStarts = marker.map { marker in
                let inAList = line.depth == 0 ? !items.isEmpty : quoteHasList
                return paragraph == nil || inAList || !marker.isEmpty && (marker.number ?? 1) == 1
            } ?? false
            let startsBlock = opensFence || isHeading || isBreak || markerStarts

            if let depth = paragraph, line.depth < depth, !startsBlock {
                // A quote's paragraph carried on without its marks.
                line.isLazy = true
                line.depth = depth
                line.inList = depth == 0 ? !items.isEmpty : quoteHasList
                lines.append(line)
                continue
            }
            if line.depth != depthBefore { quoteHasList = false }
            depthBefore = line.depth
            // A quote is out of the list items its marks are left of.
            if line.depth > 0 { items.removeAll { $0 > quoteColumn } }

            if paragraph == line.depth, !startsBlock {
                // The paragraph above carries on, however it's indented.
                let column = line.depth == 0 ? (items.last ?? 0) : 0
                line.inList = line.depth == 0 ? !items.isEmpty : quoteHasList
                line.isLazy = line.depth == 0 && indent < column
                line.isDeep = indent - column >= 4 || line.depth > 0 && quoteHasList
            } else {
                // A block of its own starts: list items it's left of are over.
                if line.depth == 0 { items.removeAll { $0 > indent } }
                line.inList = line.depth == 0 ? !items.isEmpty : quoteHasList
                let column = line.depth == 0 ? (items.last ?? 0) : 0
                if indent - column >= 4, !(line.depth > 0 && quoteHasList) {
                    line.isCode = true
                    paragraph = nil
                } else if opensFence {
                    line.isCode = true
                    fence = (rest.first!, fenceRun, line.depth)
                    paragraph = nil
                } else if isHeading {
                    line.isOneLine = true
                    paragraph = nil
                } else if isBreak {
                    paragraph = nil
                } else if markerStarts, let marker {
                    line.startsItem = true
                    line.inList = true
                    if line.depth == 0 { items.append(marker.column) } else { quoteHasList = true }
                    paragraph = marker.isEmpty ? nil : line.depth
                } else {
                    paragraph = line.depth
                    line.isDeep = line.depth > 0 && quoteHasList
                }
            }
            if !line.isCode, !line.startsItem, paragraph != nil {
                // A table: its header (with a line of dashes under it) and the rows after.
                if !inTable, rest.contains("|"), number + 1 < ranges.count, isDelimiterRow(chars[ranges[number + 1]]) { inTable = true }
                line.isOneLine = inTable || rest.first == "|"
                // A formula of its own on lines of its own: the lines up to its end are math.
                if !line.isOneLine, let end = mathEnd(chars, ranges, from: number, depth: line.depth) { mathUntil = end }
            }
            lines.append(line)
        }
        return lines
    }

    /// Where a line's words start: past its quote marks (">", after up to three spaces, and a
    /// space after it; how many, and how far in the first is) and its indentation (in columns, a
    /// tab reaching the next of every four).
    nonisolated private static func prefix(of chars: [Character], _ range: Range<Int>) -> (depth: Int, quoteColumn: Int, indent: Int, body: Int) {
        let end = range.upperBound
        var depth = 0, quoteColumn = 0
        var p = range.lowerBound
        while true {
            var q = p
            while q < end, q - p < 3, chars[q] == " " { q += 1 }
            guard q < end, chars[q] == ">" else { break }
            if depth == 0 { quoteColumn = q - p }
            depth += 1
            p = q + 1
            if p < end, chars[p] == " " { p += 1 }
        }
        var indent = 0
        while p < end, chars[p] == " " || chars[p] == "\t" {
            indent = chars[p] == "\t" ? indent + 4 - indent % 4 : indent + 1
            p += 1
        }
        return (depth, quoteColumn, indent, p)
    }

    /// The last line of a formula of its own that opens at the start of line `number` (`$$` or
    /// `\[`) and doesn't close on it: the one it closes on, in its paragraph and quote.
    nonisolated private static func mathEnd(_ chars: [Character], _ ranges: [Range<Int>], from number: Int, depth: Int) -> Int? {
        let body = prefix(of: chars, ranges[number]).body
        let line = chars[body..<ranges[number].upperBound]
        let dollars = line.starts(with: "$$") && !line.starts(with: "$$$")
        guard dollars || line.starts(with: "\\[") else { return nil }
        guard case .notHere = closing(chars, from: body + 2, to: ranges[number].upperBound, dollars: dollars) else { return nil }
        for next in (number + 1)..<ranges.count {
            let prefix = prefix(of: chars, ranges[next])
            guard prefix.body < ranges[next].upperBound, prefix.depth == depth else { return nil }
            switch closing(chars, from: prefix.body, to: ranges[next].upperBound, dollars: dollars) {
            case .at: return next
            case .never: return nil
            case .notHere: continue
            }
        }
        return nil
    }

    nonisolated private enum Closing {
        case at(Int)
        case notHere
        /// Not past code or three dollar signs.
        case never
    }

    /// Where `$$` (or `\]`) closes a formula of its own in `chars[from..<to]`, one line.
    nonisolated private static func closing(_ chars: [Character], from: Int, to: Int, dollars: Bool) -> Closing {
        var j = from
        while j < to {
            let c = chars[j]
            if c == "`" { return .never }
            if c == "\\" {
                if !dollars, j + 1 < to, chars[j + 1] == "]" { return .at(j) }
                j += 2
                continue
            }
            if dollars, c == "$" {
                var run = 0
                while j + run < to, chars[j + run] == "$" { run += 1 }
                if run == 2 { return .at(j) }
                if run > 2 { return .never }
            }
            j += 1
        }
        return .notHere
    }

    /// A list item's marker at the start of `rest`, indented `indent`: where the item's words
    /// start (in columns), whether it has any, and its number.
    nonisolated private static func listMarker(_ rest: ArraySlice<Character>, indent: Int) -> (column: Int, isEmpty: Bool, number: Int?)? {
        guard let first = rest.first else { return nil }
        var width = 1
        var number: Int?
        if !"-+*".contains(first) {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count), let after = rest.dropFirst(digits.count).first, after == "." || after == ")" else { return nil }
            width = digits.count + 1
            number = Int(String(digits))
        }
        let after = rest.dropFirst(width)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        let spaces = after.prefix { $0 == " " }.count
        let isEmpty = after.allSatisfy { $0 == " " || $0 == "\t" }
        return (indent + width + (isEmpty || spaces > 4 || spaces == 0 ? 1 : spaces), isEmpty, number)
    }

    /// A table's line under its header: "| --- | :-: |".
    nonisolated private static func isDelimiterRow(_ line: ArraySlice<Character>) -> Bool {
        var line = line.drop { $0 == " " || $0 == ">" }
        guard line.contains("|"), line.contains("-") else { return false }
        while let last = line.last, last == " " || last == "\t" { line = line.dropLast() }
        return line.allSatisfy { "|-: \t".contains($0) }
    }

    /// One run of lines with words (`range`), its formulas set aside.
    nonisolated private static func protect(_ chars: [Character], _ lines: [Line], _ range: ClosedRange<Int>, into formulas: inout Formulas) -> String {
        let stretchEnd = lines[range.upperBound].end
        var out = ""
        var i = lines[range.lowerBound].start
        /// The line `index` is on.
        func lineIndex(_ index: Int) -> Int {
            var low = range.lowerBound, high = range.upperBound
            while low < high {
                let middle = (low + high + 1) / 2
                if lines[middle].start <= index { low = middle } else { high = middle - 1 }
            }
            return low
        }
        func mark(_ formula: Formula) -> String {
            formulas.list.append(formula)
            return "\(formulas.open)\(formulas.list.count - 1)\(formulas.close)"
        }
        /// The text from `start` to `end`, each line after the first from where its words start.
        func written(from start: Int, to end: Int) -> [String] {
            var parts: [String] = []
            var index = lineIndex(start), from = start
            while true {
                parts.append(String(chars[from..<min(end, lines[index].end)]))
                if end <= lines[index].end { break }
                index += 1
                from = lines[index].body
            }
            return parts
        }
        /// Where a formula of its own opened at `start` closes: on its line, or on the next ones of
        /// its paragraph, but not into code, onto another list item or out of its quote, out of a
        /// table row or heading, or past three dollar signs.
        func blockEnd(from start: Int, dollars: Bool) -> Int? {
            var index = lineIndex(start)
            let first = lines[index]
            var from = start + 2
            while true {
                switch closing(chars, from: from, to: lines[index].end, dollars: dollars) {
                case .at(let end): return end
                case .never: return nil
                case .notHere:
                    guard index < range.upperBound, !first.isOneLine else { return nil }
                    index += 1
                    let next = lines[index]
                    guard next.depth == first.depth, next.isMath || !next.isOneLine && !next.isLazy && !next.startsItem else { return nil }
                    from = next.body
                }
            }
        }
        /// Sets aside the formula of its own opened at `start`, if it closes; false if it doesn't.
        func placeBlock(from start: Int, dollars: Bool) -> Bool {
            guard let end = blockEnd(from: start, dollars: dollars) else { return false }
            let parts = written(from: start + 2, to: end)
            let latex = parts.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            // Nothing, or no formula: "($$) … ($$)" are prices.
            guard !latex.isEmpty, !dollars || !")]}".contains(latex.first!) else { return false }
            let (open, close) = dollars ? ("$$", "$$") : ("\\[", "\\]")
            let formula = Formula(source: open + parts.joined(separator: "\n") + close, latex: latex, isBlock: true, drawn: drawable(latex))
            let line = lines[lineIndex(start)]
            let closing = lines[lineIndex(end)]
            let after = chars[(end + 2)..<closing.end]
            let next = lineIndex(end) < range.upperBound ? lines[lineIndex(end) + 1] : nil
            // The line under it reads on as it did, not as a code block or out of a list or quote.
            let nextReads = next.map { !$0.isLazy && !$0.isDeep && $0.depth == line.depth } ?? true
            i = end + 2
            if formula.drawn == nil || !line.takesBlock || latex.contains("```") {
                out += mark(formula)
            } else if line.isTopLevel, nextReads || !after.allSatisfy(\.isWhitespace) {
                out += "\n\n```\(blockLanguage)\n\(latex)\n```\n\n"
            } else if !line.isTopLevel, start == line.body, after.allSatisfy(\.isWhitespace), nextReads {
                // In its list item or quote: the fence goes in indented and quoted as its line is.
                let prefix = String(chars[line.start..<line.body])
                out += "```\(blockLanguage)\n" + latex.split(separator: "\n").map { prefix + $0 }.joined(separator: "\n") + "\n\(prefix)```"
                i = closing.end
            } else {
                out += mark(formula)
            }
            return true
        }
        while i < stretchEnd {
            let c = chars[i]
            // Code in a line: as it is.
            if c == "`" {
                var run = 0
                while i + run < stretchEnd, chars[i + run] == "`" { run += 1 }
                if let end = closingBackticks(chars, from: i + run, to: stretchEnd, count: run) {
                    out += String(chars[i..<(end + run)])
                    i = end + run
                } else {
                    out += String(repeating: "`", count: run)
                    i += run
                }
                continue
            }
            if c == "\\", i + 1 < stretchEnd, chars[i + 1] != "\n" {
                let next = chars[i + 1]
                if next == "[", placeBlock(from: i, dollars: false) { continue }
                if next == "(", let end = inlineEnd(chars, from: i, to: stretchEnd, closer: ")") {
                    let latex = String(chars[(i + 2)..<end]).trimmingCharacters(in: .whitespaces)
                    if !latex.isEmpty {
                        out += mark(Formula(source: String(chars[i..<(end + 2)]), latex: latex, isBlock: false, drawn: drawable(latex)))
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
                var run = 0
                while i + run < stretchEnd, chars[i + run] == "$" { run += 1 }
                if run == 2, placeBlock(from: i, dollars: true) { continue }
                if run == 1, let end = inlineEnd(chars, from: i, to: stretchEnd) {
                    let latex = String(chars[(i + 1)..<end])
                    out += mark(Formula(source: String(chars[i...end]), latex: latex, isBlock: false, drawn: drawable(latex)))
                    i = end + 1
                    continue
                }
                // Three or more are never math: prices ("$$$"), or the shell's.
                out += String(repeating: "$", count: run)
                i += run
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// Where a run of `count` backticks closes a code span, from `start` to `end`.
    nonisolated private static func closingBackticks(_ chars: [Character], from start: Int, to end: Int, count: Int) -> Int? {
        var i = start
        while i < end {
            if chars[i] == "`" {
                var run = 0
                while i + run < end, chars[i + run] == "`" { run += 1 }
                if run == count { return i }
                i += run
            } else {
                i += 1
            }
        }
        return nil
    }

    /// Where `\)` closes the `\(` at `start`, on its line and not into code.
    nonisolated private static func inlineEnd(_ chars: [Character], from start: Int, to end: Int, closer: Character) -> Int? {
        var i = start + 2
        while i + 1 < end, chars[i] != "\n", chars[i] != "`" {
            if chars[i] == "\\" {
                if chars[i + 1] == closer { return i }
                i += chars[i + 1] == "\n" ? 1 : 2
                continue
            }
            i += 1
        }
        return nil
    }

    /// The `$` that closes one opened at `start`, as Pandoc reads them: text right after the
    /// opening one and right before the closing one, on one line, and no digit right after (so
    /// "$5 and $10" stays prices).
    nonisolated private static func inlineEnd(_ chars: [Character], from start: Int, to end: Int) -> Int? {
        guard start + 1 < end, !chars[start + 1].isWhitespace, chars[start + 1] != "$" else { return nil }
        var i = start + 1
        // Not across a line, nor into code: "$10 and `$HOME`" is a price and code.
        while i < end, chars[i] != "\n", chars[i] != "`" {
            if chars[i] == "\\" {
                i += i + 1 < end && chars[i + 1] != "\n" ? 2 : 1
                continue
            }
            if chars[i] == "$" {
                let isClosing = !chars[i - 1].isWhitespace && (i + 1 >= end || !chars[i + 1].isNumber)
                return isClosing ? i : nil
            }
            i += 1
        }
        return nil
    }

    // MARK: What SwiftUIMath can draw

    /// `latex` as SwiftUIMath draws it, with a few commands it lacks put as ones it has (`\dots`
    /// as `\ldots`, `\operatorname{f}` as `\mathrm{f}`, `\begin{align}` as `aligned`, sizes and
    /// boxes left out); nil when it still can't, so the formula shows as written rather than as
    /// nothing. Kept, as each reply is read again with every word that streams in.
    nonisolated static func drawable(_ latex: String) -> String? {
        let key = latex as NSString
        if let known = drawables.object(forKey: key) { return known.latex }
        let drawn = substituted(latex)
        let width = Math.typographicBounds(for: drawn, fitting: .unspecified, font: .init(name: .latinModern, size: 20), style: .text).width
        let result = width > 0 ? drawn : nil
        drawables.setObject(Drawable(latex: result), forKey: key)
        return result
    }

    nonisolated private final class Drawable: Sendable {
        let latex: String?
        init(latex: String?) { self.latex = latex }
    }

    /// NSCache is thread-safe.
    nonisolated(unsafe) private static let drawables: NSCache<NSString, Drawable> = {
        let cache = NSCache<NSString, Drawable>()
        cache.countLimit = 2000
        return cache
    }()

    /// Commands SwiftUIMath doesn't know, as ones it does; empty ones are left out.
    nonisolated private static let substitutes: [String: String] = [
        "dots": "ldots", "dotsc": "ldots", "dotso": "ldots", "dotsb": "cdots", "dotsm": "cdots", "dotsi": "cdots",
        "varnothing": "emptyset", "lVert": "Vert", "rVert": "Vert", "lvert": "vert", "rvert": "vert",
        "operatorname": "mathrm", "boldsymbol": "bm", "pmb": "bm", "bmod": "mod",
        "big": "", "Big": "", "bigg": "", "Bigg": "", "bigl": "", "bigr": "", "bigm": "", "Bigl": "", "Bigr": "", "Bigm": "",
        "biggl": "", "biggr": "", "biggm": "", "Biggl": "", "Biggr": "", "Biggm": "",
        "boxed": "", "notag": "", "nonumber": "",
    ]

    /// Environments SwiftUIMath doesn't know, as ones it does; empty ones are left out.
    nonisolated private static let environments: [String: String] = [
        "align": "aligned", "align*": "aligned", "flalign": "aligned", "flalign*": "aligned", "eqnarray*": "eqnarray",
        "gather*": "gather", "multline": "gather", "multline*": "gather", "dcases": "cases",
        "equation": "", "equation*": "", "displaymath": "",
    ]

    nonisolated private static func substituted(_ latex: String) -> String {
        guard latex.contains("\\") else { return latex }
        var out = ""
        var rest = latex[...]
        while let slash = rest.firstIndex(of: "\\") {
            out += rest[..<slash]
            rest = rest[rest.index(after: slash)...]
            let name = String(rest.prefix { $0.isASCII && $0.isLetter })
            guard !name.isEmpty else {
                // "\\", "\{", "\,": as they are.
                out += "\\" + rest.prefix(1)
                rest = rest.dropFirst()
                continue
            }
            rest = rest.dropFirst(name.count)
            if name == "begin" || name == "end", rest.first == "{", let close = rest.firstIndex(of: "}") {
                let environment = String(rest[rest.index(after: rest.startIndex)..<close])
                if let substitute = environments[environment] {
                    rest = rest[rest.index(after: close)...]
                    if !substitute.isEmpty { out += "\\\(name){\(substitute)}" }
                    continue
                }
                out += "\\" + name
            } else if name == "tag", let argument = braced(&rest) {
                // An equation's number, after it.
                out += "\\qquad " + (argument.starred ? argument.text : "(\(argument.text))")
            } else if let substitute = substitutes[name] {
                if name == "operatorname", rest.first == "*" { rest = rest.dropFirst() }
                // A space after it, so it doesn't run into the letters after.
                out += substitute.isEmpty ? "" : "\\\(substitute) "
            } else {
                out += "\\" + name
            }
        }
        return out + rest
    }

    /// The `{…}` (or `*{…}`) at the start of `rest`, taken off it.
    nonisolated private static func braced(_ rest: inout Substring) -> (text: Substring, starred: Bool)? {
        var text = rest
        let starred = text.first == "*"
        if starred { text = text.dropFirst() }
        guard text.first == "{" else { return nil }
        var depth = 0
        for index in text.indices {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" { depth -= 1 }
            if depth == 0 {
                rest = text[text.index(after: index)...]
                return (text[text.index(after: text.startIndex)..<index], starred)
            }
        }
        return nil
    }

    // MARK: Putting them back

    /// Each mark in `text` swapped for its formula, drawn in the line, or for the formula as it
    /// was written when it can't be drawn. The marks are found in a plain copy of the text's
    /// bytes, which is quick, rather than by walking its characters, which works out where each
    /// one ends at every step (a long reply is read again with each streamed word); and replaced
    /// last first, so the ones before keep their place.
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
            let attributes = text[start..<end].runs.first?.attributes ?? AttributeContainer()
            guard let drawn = mark.formula.drawn else {
                text.replaceSubrange(start..<end, with: AttributedString(mark.formula.source, attributes: attributes))
                continue
            }
            var formula = AttributedString("\u{FFFC}", attributes: attributes)
            formula.textual.attachment = AnyAttachment(InlineMath(latex: mark.formula.latex, drawn: drawn, isDisplay: mark.formula.isBlock))
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
    /// As written, and as drawn (see `MathText.drawable`).
    let latex: String
    let drawn: String
    /// Set as a formula of its own is (larger operators, limits above and below).
    let isDisplay: Bool

    var description: String { isDisplay ? "$$\(latex)$$" : "$\(latex)$" }
    var selectionStyle: AttachmentSelectionStyle { .text }

    private static let drawnSize: CGFloat = 40

    var body: some View {
        Math(drawn)
            .mathFont(.init(name: .latinModern, size: MathText.drawingSize(for: drawn, near: Self.drawnSize, display: isDisplay)))
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
            for: drawn,
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
    /// As SwiftUIMath draws it (see `MathText.drawable`).
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
