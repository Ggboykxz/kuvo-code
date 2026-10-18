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
/// put back after as a formula in the text. Code, links' addresses and web addresses are left as
/// they are, and so are prices like "$5 and $10" or "Joe's is $$". The text around them keeps its
/// shape: a formula in a list item, a quote or a table stays in it, and one SwiftUIMath can't draw
/// shows as it was written.
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
        let (lines, places) = read(chars)
        guard !places.isEmpty else { return (input, formulas) }
        func mark(_ formula: Formula) -> String {
            formulas.list.append(formula)
            return "\(formulas.open)\(formulas.list.count - 1)\(formulas.close)"
        }
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0
        for place in places {
            out += String(chars[i..<place.start])
            i = place.end
            let formula = place.formula
            let line = lines[place.first], closing = lines[place.last]
            let after = chars[place.end..<closing.end]
            // The line under it reads on as it did, not as a code block, a list or a heading's
            // underline, or out of a list or quote.
            let nextReads = place.last + 1 < lines.count ? !lines[place.last + 1].changesAfterBlock : true
            if !formula.isBlock || formula.drawn == nil || !line.takesBlock || formula.latex.contains("```") {
                out += mark(formula)
            } else if line.isTopLevel, nextReads || !after.allSatisfy(\.isWhitespace) {
                // Under the words before it on its line, if any: at a line's start, a blank line
                // ahead would be read into code above that's still open.
                let atStart = chars[line.start..<place.start].allSatisfy(\.isWhitespace)
                out += (atStart ? "" : "\n\n") + "```\(blockLanguage)\n\(formula.latex)\n```\n\n"
            } else if !line.isTopLevel, place.start == line.body, after.allSatisfy(\.isWhitespace), nextReads {
                // In its list item or quote: the fence goes in indented and quoted as its line is.
                let prefix = String(chars[line.start..<line.body])
                out += "```\(blockLanguage)\n" + formula.latex.split(separator: "\n").map { prefix + $0 }.joined(separator: "\n") + "\n\(prefix)```"
                i = closing.end
            } else {
                out += mark(formula)
            }
        }
        out += String(chars[i...])
        return (out, formulas)
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
        /// Where they start after its list markers, too.
        var content: Int
        /// How many quotes it's in.
        var depth: Int
        /// How many quote marks it has (a quote's paragraph can carry on without them).
        var marks: Int
        /// In a code block, or one's fence: left as it is.
        var isCode = false
        var isBlank = false
        /// In a formula on lines of its own that started above, and ends on this one or one
        /// below: math, however it looks as Markdown ("+ x" isn't a list item).
        var isMath = false
        /// Starts a list item ("- ", "1. ").
        var startsItem = false
        /// Carries on the paragraph above.
        var continues = false
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
        /// Under a paragraph, read otherwise than under a block: a list item or a link's
        /// definition that can't start in a paragraph ("2. x"), or a line of "=" or "-" making it
        /// a heading.
        var underParagraph = false

        init(start: Int, end: Int, body: Int, depth: Int) {
            self.start = start
            self.end = end
            self.body = body
            content = body
            self.depth = depth
            marks = depth
        }

        /// A formula of its own can be a block here, in a fence indented as the line is.
        var takesBlock: Bool { !isOneLine && !startsItem && !isLazy && !isDeep }
        /// Not in a list item or quote: a block goes in at the left edge, between blank lines.
        var isTopLevel: Bool { depth == 0 && !inList }
        /// Read otherwise under a block than under the paragraph it's in or after.
        var changesAfterBlock: Bool { isLazy || isDeep || underParagraph }
    }

    /// A formula in the text: from its opening `$` or `\` to past its closing one, the lines it
    /// opens and closes on, and what it is.
    nonisolated private struct Place {
        var start: Int
        var end: Int
        var first: Int
        var last: Int
        var formula: Formula
    }

    /// The lines of `chars`, read as Markdown reads its blocks, and the formulas in their words:
    /// not in code, a link's address or a web address. One of its own (`$$` or `\[`) closes in its
    /// paragraph; opened at the start of a line's words, it's on lines of its own, which can look
    /// like anything ("+ x" isn't a list item) but a blank line or a line out of its quote or list
    /// item.
    nonisolated private static func read(_ chars: [Character]) -> (lines: [Line], places: [Place]) {
        var ranges: [Range<Int>] = []
        var start = 0
        for (index, character) in chars.enumerated() where character == "\n" {
            ranges.append(start..<index)
            start = index + 1
        }
        ranges.append(start..<chars.count)

        var blocks = Blocks(chars: chars, ranges: ranges)
        var lines: [Line] = []
        lines.reserveCapacity(ranges.count)
        var places: [Place] = []
        // The last line of a formula on lines of its own being read, and where the words after a
        // formula or code that ended on a later line start.
        var mathUntil = -1
        var resume = 0

        /// Each line after `number` that carries on its paragraph, in its quote and not a table
        /// row, while `reads` reads on.
        func carryOn(after number: Int, _ reads: (Int, Line) -> Bool) {
            var probe = blocks
            for next in (number + 1)..<ranges.count {
                let line = probe.read(next)
                guard line.continues, !line.isOneLine, line.depth == lines[number].depth, reads(next, line) else { return }
            }
        }

        /// The formula of its own opened at `start` on line `number`, if it closes, and whether
        /// it's on lines of its own.
        func display(at start: Int, on number: Int, dollars: Bool) -> (place: Place, ownLines: Bool)? {
            if dollars, isPrice(chars, at: start) { return nil }
            let line = lines[number]
            var parts = [chars[(start + 2)..<line.end]]
            var end: Int?, last = number, closeBody = line.body
            /// Reads `chars[from..<to]`, on line `next`: false where the formula closes, or can't.
            func reads(_ next: Int, from: Int, to: Int) -> Bool {
                switch closing(chars, from: from, to: to, dollars: dollars) {
                case .at(let at):
                    (end, last, closeBody) = (at, next, from)
                    if next == number { parts = [chars[from..<at]] } else { parts.append(chars[from..<at]) }
                    return false
                case .never:
                    return false
                case .notHere:
                    if next != number { parts.append(chars[from..<to]) }
                    return true
                }
            }
            // On lines of its own: opened at the start of a line's words, not after a list marker
            // or on a line carrying a paragraph on lazily.
            let ownLines = start == line.body && !line.startsItem && !line.isLazy
            // Lines it runs over that Markdown would read as blocks of their own ("+ x", "1. x").
            var overBlocks = false
            if reads(number, from: start + 2, to: line.end), !line.isOneLine {
                if ownLines {
                    // Up to a blank line, a code fence, a line out of its quote, or out of its list
                    // item: a quote mark, or a block's start, left of the item's words.
                    let column = blocks.items.last ?? 0
                    for next in (number + 1)..<ranges.count {
                        let lead = prefix(of: chars, ranges[next], items: blocks.items)
                        let rest = chars[lead.body..<ranges[next].upperBound]
                        guard !rest.isEmpty, lead.depth == line.marks else { break }
                        let start = lead.indent - (blocks.items.last { $0 <= lead.indent } ?? 0) < 4 ? blockStart(of: rest, indent: lead.indent) : nil
                        if case .fence? = start { break }
                        if line.marks > 0 ? lead.quoteColumn < column : lead.indent < column && start != nil { break }
                        overBlocks = overBlocks || start != nil
                        if !reads(next, from: lead.body, to: ranges[next].upperBound) { break }
                    }
                } else {
                    carryOn(after: number) { next, line in reads(next, from: line.body, to: line.end) }
                }
            }
            guard let end else { return nil }
            // Over those, it closes on a line of its own, as math on lines of its own does.
            if overBlocks, end != closeBody || !chars[(end + 2)..<ranges[last].upperBound].allSatisfy({ $0.isWhitespace || $0.isPunctuation }) {
                return nil
            }
            let latex = parts.map { String($0).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            // Nothing, or no formula: "($$) … ($$)" are prices, and math has no "$" of its own.
            guard !latex.isEmpty, !dollars || !")]}".contains(latex.first!), !hasDollar(latex) else { return nil }
            // Two "$$" set apart as words in a sentence, around no math: prices ("Joe's is $$ and
            // Katz's is $$ too"), or the shell's.
            if dollars, chars[min(line.content, start)..<start].contains(where: { !$0.isWhitespace }),
               chars[(end + 2)..<ranges[last].upperBound].contains(where: { !$0.isWhitespace }),
               chars[start + 2].isWhitespace, chars[end - 1].isWhitespace || last > number && end == closeBody,
               !looksLikeMath(latex) {
                return nil
            }
            let (open, close) = dollars ? ("$$", "$$") : ("\\[", "\\]")
            let formula = Formula(source: open + parts.map { String($0) }.joined(separator: "\n") + close, latex: latex, isBlock: true, drawn: drawable(latex))
            return (Place(start: start, end: end + 2, first: number, last: last, formula: formula), ownLines && last > number)
        }

        /// Sets `place` aside: true when it ends on a later line, where the words read on.
        func take(_ place: Place, ownLines: Bool) -> Bool {
            places.append(place)
            guard place.last > place.first else { return false }
            resume = place.end
            if ownLines { mathUntil = place.last }
            return true
        }

        for number in ranges.indices {
            var line: Line
            if number <= mathUntil {
                let lead = prefix(of: chars, ranges[number], items: blocks.items)
                line = Line(start: ranges[number].lowerBound, end: ranges[number].upperBound, body: lead.body, depth: lead.depth)
                line.isMath = true
                // What's after the formula's end is read in the line.
                line.isOneLine = true
            } else {
                line = blocks.read(number)
            }
            lines.append(line)
            guard !line.isCode, !line.isBlank, resume < line.end else { continue }
            var i = max(resume, line.body)
            words: while i < line.end {
                switch chars[i] {
                case "`":
                    // Code in a line, as it is: to its end on the line, or on a later line of its
                    // paragraph.
                    var run = 0
                    while i + run < line.end, chars[i + run] == "`" { run += 1 }
                    if let end = closingBackticks(chars, from: i + run, to: line.end, count: run) {
                        i = end + run
                        continue
                    }
                    var end: Int?
                    if !line.isOneLine {
                        carryOn(after: number) { _, next in
                            end = closingBackticks(chars, from: next.body, to: next.end, count: run)
                            return end == nil
                        }
                    }
                    if let end {
                        resume = end + run
                        break words
                    }
                    i += run
                case "\\" where i + 1 < line.end:
                    if chars[i + 1] == "[", let found = display(at: i, on: number, dollars: false) {
                        if take(found.place, ownLines: found.ownLines) { break words }
                        i = found.place.end
                        continue
                    }
                    if chars[i + 1] == "(", let end = inlineEnd(chars, from: i, to: line.end, closer: ")") {
                        let latex = String(chars[(i + 2)..<end]).trimmingCharacters(in: .whitespaces)
                        if !latex.isEmpty {
                            let formula = Formula(source: String(chars[i..<(end + 2)]), latex: latex, isBlock: false, drawn: drawable(latex))
                            places.append(Place(start: i, end: end + 2, first: number, last: number, formula: formula))
                            i = end + 2
                            continue
                        }
                    }
                    // An escape (\$, \\ and the like): as it is, for the Markdown to read.
                    i += 2
                case "$":
                    var run = 0
                    while i + run < line.end, chars[i + run] == "$" { run += 1 }
                    if run == 2, let found = display(at: i, on: number, dollars: true) {
                        if take(found.place, ownLines: found.ownLines) { break words }
                        i = found.place.end
                        continue
                    }
                    if run == 1, let end = inlineEnd(chars, from: i, to: line.end) {
                        let latex = String(chars[(i + 1)..<end])
                        let formula = Formula(source: String(chars[i...end]), latex: latex, isBlock: false, drawn: drawable(latex))
                        places.append(Place(start: i, end: end + 1, first: number, last: number, formula: formula))
                        i = end + 1
                        continue
                    }
                    // Three or more are never math: prices ("$$$"), or the shell's.
                    i += run
                case "<":
                    // A link written as its address: "<https://…>".
                    i = autolinkEnd(chars, from: i, to: line.end).map { $0 + 1 } ?? i + 1
                case "]" where i + 1 < line.end && chars[i + 1] == "(":
                    // A link's address and title.
                    if let end = destinationEnd(chars, across: [(i + 2)..<line.end]) {
                        i = end + 1
                        continue
                    }
                    // Or on the lines after, in its paragraph: "[a](" with the address below it,
                    // or its title on the next line.
                    var segments = [(i + 2)..<line.end]
                    var end: Int?
                    if !line.isOneLine {
                        carryOn(after: number) { _, next in
                            segments.append(next.body..<next.end)
                            end = destinationEnd(chars, across: segments)
                            return end == nil && segments.count < 4
                        }
                    }
                    if let end {
                        resume = end + 1
                        break words
                    }
                    i += 1
                case "[" where i == line.content:
                    // A link's definition: "[label]: https://…".
                    i = definitionEnd(chars, from: i, to: line.end) ?? i + 1
                case ":" where i > line.body && chars[i - 1].isASCII && chars[i - 1].isLetter && opensAddress(chars, at: i, to: line.end):
                    // A web address: "https://…", to a space or a "<".
                    while i < line.end, !chars[i].isWhitespace, chars[i] != "<" { i += 1 }
                default:
                    i += 1
                }
            }
        }
        return (lines, places)
    }

    /// Markdown's blocks, as far as the lines read so far go: a code fence, list items and a
    /// paragraph being read, and whether it's a table.
    nonisolated private struct Blocks {
        let chars: [Character]
        let ranges: [Range<Int>]
        /// Its marks, its quote depth, and the column its list item's words start at, left of
        /// which the item ends, and the code with it.
        var fence: (marker: Character, count: Int, depth: Int, column: Int)?
        /// The content columns of the open list items, innermost last (out of quotes).
        var items: [Int] = []
        /// A list item seen in the quote being read.
        var quoteHasList = false
        /// The quote depth of the paragraph being read, when one is.
        var paragraph: Int?
        var inTable = false
        var depthBefore = 0

        /// Line `number`, read on from the ones before it.
        mutating func read(_ number: Int) -> Line {
            let range = ranges[number]
            let (depth, quoteColumn, indent, body) = MathText.prefix(of: chars, range, items: items)
            var line = Line(start: range.lowerBound, end: range.upperBound, body: body, depth: depth)
            let rest = chars[body..<range.upperBound]
            if let open = fence {
                // In its quote, and in its list item: indented as far, or blank.
                let inItem = open.depth == 0
                    ? depth == 0 && rest.isEmpty || (depth == 0 ? indent : quoteColumn) >= open.column
                    : rest.isEmpty || indent >= open.column
                if depth >= open.depth, inItem {
                    line.isCode = true
                    // Closed in its own quote, less than a code block's indentation in.
                    let run = rest.prefix { $0 == open.marker }.count
                    if depth == open.depth, indent - open.column < 4, run >= open.count, rest.dropFirst(run).allSatisfy(\.isWhitespace) { fence = nil }
                    return line
                }
                // Its quote or list item ended, and the code with it.
                fence = nil
            }
            if rest.isEmpty {
                line.isBlank = true
                paragraph = nil
                inTable = false
                // A quote's blank line is out of the list items its marks are left of, too.
                if depth > 0 { items.removeAll { $0 > quoteColumn } }
                return line
            }

            // A block starts less than a code block's indentation into the list item it's in.
            let column = depth == 0 ? items.last { $0 <= indent } ?? 0 : 0
            let start = indent - column < 4 || depth > 0 && quoteHasList ? MathText.blockStart(of: rest, indent: indent) : nil
            let startsBlock: Bool
            if case .item(let marker)? = start {
                // An item interrupts a paragraph only with words, and numbered from 1; out of the
                // paragraph's quote or list item (or in a quote's list), any does.
                let outside = depth < (paragraph ?? 0) || (depth == 0 ? indent < (items.last ?? 0) : quoteHasList)
                startsBlock = paragraph == nil || inTable || outside || !marker.isEmpty && (marker.number ?? 1) == 1
            } else {
                startsBlock = start != nil
            }

            if let open = paragraph, depth < open, !startsBlock {
                // A quote's paragraph carried on without its marks.
                line.isLazy = true
                line.continues = true
                line.underParagraph = start != nil
                line.depth = open
                line.inList = open == 0 ? !items.isEmpty : quoteHasList
                return line
            }
            if depth != depthBefore { quoteHasList = false }
            depthBefore = depth
            // A quote is out of the list items its marks are left of, and their paragraph.
            if depth > 0, items.contains(where: { $0 > quoteColumn }) {
                items.removeAll { $0 > quoteColumn }
                paragraph = nil
            }

            // A table's rows end at a block, code indented under them too.
            if paragraph == depth, !startsBlock, !(inTable && indent - column >= 4) {
                // The paragraph above carries on, however it's indented.
                let column = depth == 0 ? (items.last ?? 0) : 0
                line.inList = depth == 0 ? !items.isEmpty : quoteHasList
                line.isLazy = depth == 0 && indent < column
                line.isDeep = indent - column >= 4 || depth > 0 && quoteHasList
                line.continues = true
                let underlines = !line.isLazy && !line.isDeep && !inTable && MathText.isUnderline(rest)
                let defines = rest.first == "[" && MathText.definitionEnd(chars, from: body, to: range.upperBound) != nil
                line.underParagraph = start != nil || underlines || defines
                // A heading's underline ends it.
                if underlines { paragraph = nil }
            } else {
                // A block of its own starts: list items it's left of are over.
                let underlines = paragraph == depth && !inTable && MathText.isUnderline(rest)
                inTable = false
                if depth == 0 { items.removeAll { $0 > indent } }
                line.inList = depth == 0 ? !items.isEmpty : quoteHasList
                if indent - column >= 4, !(depth > 0 && quoteHasList) {
                    line.isCode = true
                    paragraph = nil
                } else {
                    // A list item's first line has its words, a block of its own (a code fence,
                    // another item), or nothing.
                    var start = start, fenceColumn = column, hasWords = true
                    while case .item(let marker)? = start {
                        line.startsItem = true
                        line.inList = true
                        if depth == 0 { items.append(marker.column) } else { quoteHasList = true }
                        fenceColumn = marker.column
                        start = nil
                        if marker.isEmpty || marker.isCode {
                            line.isCode = marker.isCode
                            hasWords = false
                        } else {
                            line.content = marker.content
                            start = MathText.blockStart(of: chars[marker.content..<range.upperBound], indent: marker.column)
                        }
                    }
                    switch start {
                    case .fence(let marker, let count)?:
                        line.isCode = true
                        fence = (marker, count, depth, fenceColumn)
                        paragraph = nil
                    case .heading?:
                        line.isOneLine = true
                        paragraph = nil
                    case .rule?, .item?:
                        line.underParagraph = underlines
                        paragraph = nil
                    case nil:
                        // A quote opened on an item's line: the paragraph is the quote's.
                        while line.startsItem, line.content < range.upperBound, chars[line.content] == ">" {
                            line.depth += 1
                            line.content += 1
                            if line.content < range.upperBound, chars[line.content] == " " { line.content += 1 }
                            depthBefore = line.depth
                            quoteHasList = false
                        }
                        paragraph = hasWords && line.content < range.upperBound ? line.depth : nil
                        if !line.startsItem { line.isDeep = depth > 0 && quoteHasList }
                    }
                }
            }
            if !line.isCode, paragraph != nil {
                // A table: its header (with a line of dashes under it) and the rows after.
                if !inTable, rest.contains("|"), number + 1 < ranges.count, MathText.isDelimiterRow(chars[ranges[number + 1]]) { inTable = true }
                line.isOneLine = line.isOneLine || inTable || rest.first == "|"
            }
            return line
        }
    }

    /// A line of "=" or "-", which makes a paragraph above it a heading.
    nonisolated private static func isUnderline(_ rest: ArraySlice<Character>) -> Bool {
        let marks = rest.reversed().drop { $0 == " " || $0 == "\t" }
        return marks.first.map { mark in (mark == "=" || mark == "-") && marks.allSatisfy { $0 == mark } } ?? false
    }

    /// Where a line's words start: past its quote marks (">", after up to three spaces, or three
    /// past the words of the list item it's in, and a space after it; how many, and how far in
    /// the first is) and its indentation (in columns, a tab reaching the next of every four).
    nonisolated private static func prefix(of chars: [Character], _ range: Range<Int>, items: [Int]) -> (depth: Int, quoteColumn: Int, indent: Int, body: Int) {
        let end = range.upperBound
        var depth = 0, quoteColumn = 0
        var p = range.lowerBound
        var reach = 3
        if !items.isEmpty {
            let spaces = chars[p..<end].prefix { $0 == " " }.count
            reach += items.last { $0 <= spaces } ?? 0
        }
        while true {
            var q = p
            while q < end, q - p < reach, chars[q] == " " { q += 1 }
            guard q < end, chars[q] == ">" else { break }
            if depth == 0 { quoteColumn = q - p }
            depth += 1
            p = q + 1
            if p < end, chars[p] == " " { p += 1 }
            reach = 3
        }
        var indent = 0
        while p < end, chars[p] == " " || chars[p] == "\t" {
            indent = chars[p] == "\t" ? indent + 4 - indent % 4 : indent + 1
            p += 1
        }
        return (depth, quoteColumn, indent, p)
    }

    /// A block a line's words start.
    nonisolated private enum BlockStart {
        case fence(Character, Int)
        case heading
        case rule
        case item(Marker)
    }

    /// The block `rest` starts, indented `indent`: a code fence, a heading, a thematic break or a
    /// list item.
    nonisolated private static func blockStart(of rest: ArraySlice<Character>, indent: Int) -> BlockStart? {
        guard let first = rest.first else { return nil }
        if first == "`" || first == "~" {
            let run = rest.prefix { $0 == first }.count
            if run >= 3, !(first == "`" && rest.dropFirst(run).contains("`")) { return .fence(first, run) }
        }
        if first == "#" {
            let hashes = rest.prefix { $0 == "#" }.count
            if hashes <= 6, hashes == rest.count || rest.dropFirst(hashes).first.map({ $0 == " " || $0 == "\t" }) == true { return .heading }
        }
        if "-*_".contains(first), rest.allSatisfy({ $0 == first || $0 == " " || $0 == "\t" }), rest.filter({ $0 == first }).count >= 3 {
            return .rule
        }
        return listMarker(rest, indent: indent).map { .item($0) }
    }

    nonisolated private enum Closing {
        case at(Int)
        case notHere
        /// Not past code, a link's address or three dollar signs.
        case never
    }

    /// Where `$$` (or `\]`) closes a formula of its own in `chars[from..<to]`, one line: not as a
    /// price, "($$)", nor right before a word.
    nonisolated private static func closing(_ chars: [Character], from: Int, to: Int, dollars: Bool) -> Closing {
        var j = from
        while j < to {
            let c = chars[j]
            if c == "`" || opensAddress(chars, at: j, to: to) { return .never }
            if c == "\\" {
                if !dollars, j + 1 < to, chars[j + 1] == "]" { return .at(j) }
                j += 2
                continue
            }
            if dollars, c == "$" {
                var run = 0
                while j + run < to, chars[j + run] == "$" { run += 1 }
                if run > 2 { return .never }
                // Right before a letter or a digit, it opens the next formula.
                let opensNext = j + 2 < to && (chars[j + 2].isLetter || chars[j + 2].isNumber)
                if run == 2, !isPrice(chars, at: j), !opensNext { return .at(j) }
                j += run
                continue
            }
            j += 1
        }
        return .notHere
    }

    /// Whether the `$$` at `i` is a price in parentheses: "($$)".
    nonisolated private static func isPrice(_ chars: [Character], at i: Int) -> Bool {
        i > 0 && i + 2 < chars.count && chars[i - 1] == "(" && chars[i + 2] == ")"
    }

    /// Has a `$` that isn't escaped (`\$`).
    nonisolated private static func hasDollar(_ latex: String) -> Bool {
        var escaped = false
        for character in latex {
            if character == "$", !escaped { return true }
            escaped = character == "\\" && !escaped
        }
        return false
    }

    /// Has what only math has: a command, a sub- or superscript, braces, an equals sign or another
    /// relation, a plus, or a function's argument ("f(x)").
    nonisolated private static func looksLikeMath(_ latex: String) -> Bool {
        var previous: Character = " "
        for character in latex {
            if "\\^_{}=<>+".contains(character) || character == "(" && (previous.isLetter || previous.isNumber) { return true }
            previous = character
        }
        return false
    }

    /// A list item's marker: the column its words start at and where they start, whether it has
    /// none, or only code (indented past the marker), and its number.
    nonisolated private struct Marker {
        var column: Int
        var content: Int
        var isEmpty: Bool
        var isCode: Bool
        var number: Int?
    }

    /// A list item's marker at the start of `rest`, indented `indent`.
    nonisolated private static func listMarker(_ rest: ArraySlice<Character>, indent: Int) -> Marker? {
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
        let isCode = !isEmpty && spaces > 4
        let content = isCode ? after.startIndex + 1 : after.firstIndex { $0 != " " && $0 != "\t" } ?? rest.endIndex
        return Marker(column: indent + width + (isEmpty || spaces > 4 || spaces == 0 ? 1 : spaces), content: content, isEmpty: isEmpty, isCode: isCode, number: number)
    }

    /// A table's line under its header: "| --- | :-: |".
    nonisolated private static func isDelimiterRow(_ line: ArraySlice<Character>) -> Bool {
        var line = line.drop { $0 == " " || $0 == ">" }
        guard line.contains("|"), line.contains("-") else { return false }
        while let last = line.last, last == " " || last == "\t" { line = line.dropLast() }
        return line.allSatisfy { "|-: \t".contains($0) }
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

    /// Whether a link's address starts at `i`: "](…", or "://" in a web address.
    nonisolated private static func opensAddress(_ chars: [Character], at i: Int, to end: Int) -> Bool {
        guard i + 1 < end else { return false }
        return chars[i] == "]" && chars[i + 1] == "(" || chars[i] == ":" && i + 2 < end && chars[i + 1] == "/" && chars[i + 2] == "/"
    }

    /// Where the `>` of a link written as its address (`<https://…>`, `<name@example.com>`) at
    /// `start` is, on its line.
    nonisolated private static func autolinkEnd(_ chars: [Character], from start: Int, to end: Int) -> Int? {
        var i = start + 1
        while i < end, chars[i] != ">" {
            if chars[i].isWhitespace || chars[i] == "<" { return nil }
            i += 1
        }
        guard i < end else { return nil }
        let address = chars[(start + 1)..<i]
        let scheme = address.prefix { $0 != ":" }
        let isURL = scheme.count >= 2 && scheme.count < address.count && scheme.first!.isLetter
            && scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }
        return isURL || address.contains("@") ? i : nil
    }

    /// Where the `)` of a link's address and title is, in `segments` (the rest of the line after
    /// its `(`, then the lines after it in its paragraph, without their quote marks or
    /// indentation), which Markdown reads as one, with a line break between each.
    nonisolated private static func destinationEnd(_ chars: [Character], across segments: [Range<Int>]) -> Int? {
        guard segments.count > 1 else { return segments.first.flatMap { destinationEnd(chars, from: $0.lowerBound, to: $0.upperBound) } }
        var joined: [Character] = [], origin: [Int] = []
        for (n, segment) in segments.enumerated() {
            if n > 0 {
                joined.append("\n")
                origin.append(segment.lowerBound)
            }
            for index in segment {
                joined.append(chars[index])
                origin.append(index)
            }
        }
        return destinationEnd(joined, from: 0, to: joined.count).map { origin[$0] }
    }

    /// Where the `)` of a link's address and title is, from `start` (after its `(`) to `end`. A
    /// line break can come before the address, between it and its title, or in the title.
    nonisolated private static func destinationEnd(_ chars: [Character], from start: Int, to end: Int) -> Int? {
        var i = start
        func spaces() { while i < end, chars[i] == " " || chars[i] == "\t" || chars[i] == "\n" { i += 1 } }
        spaces()
        if i < end, chars[i] == "<" {
            i += 1
            while i < end, chars[i] != ">" {
                if chars[i] == "<" || chars[i] == "\n" { return nil }
                i += chars[i] == "\\" ? 2 : 1
            }
            guard i < end else { return nil }
            i += 1
        } else {
            // Parentheses in it come in pairs.
            var depth = 0
            while i < end, !chars[i].isWhitespace {
                if chars[i] == "\\" {
                    i += 2
                    continue
                }
                if chars[i] == "(" { depth += 1 }
                if chars[i] == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                i += 1
            }
        }
        spaces()
        if i < end, chars[i] == "\"" || chars[i] == "'" || chars[i] == "(" {
            let closer: Character = chars[i] == "(" ? ")" : chars[i]
            i += 1
            while i < end, chars[i] != closer { i += chars[i] == "\\" ? 2 : 1 }
            guard i < end else { return nil }
            i += 1
            spaces()
        }
        return i < end && chars[i] == ")" ? i : nil
    }

    /// The end of a link's definition at `start` ("[label]: https://… 'title'"), its line's end.
    nonisolated private static func definitionEnd(_ chars: [Character], from start: Int, to end: Int) -> Int? {
        var i = start + 1
        while i < end, chars[i] != "]" {
            if chars[i] == "[" { return nil }
            i += chars[i] == "\\" ? 2 : 1
        }
        guard i > start + 1, i + 1 < end, chars[i + 1] == ":" else { return nil }
        i += 2
        while i < end, chars[i] == " " || chars[i] == "\t" { i += 1 }
        guard i < end else { return nil }
        while i < end, !chars[i].isWhitespace { i += 1 }
        // Nothing after the address but a title.
        let title = chars[i..<end].drop { $0 == " " || $0 == "\t" }
        return title.isEmpty || "\"'(".contains(title.first!) ? end : nil
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
        // Not across a line, nor into code or a link's address: "$10 and `$HOME`" is a price and
        // code, and so is "$5 [docs](https://…?$top=2)" a price and a link.
        while i < end, chars[i] != "\n", chars[i] != "`" {
            if opensAddress(chars, at: i, to: end) { return nil }
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
    /// was written when it can't be drawn.
    static func restore(_ text: inout AttributedString, _ formulas: Formulas) {
        restore(&text, formulas) { formula, attributes in
            var drawn = AttributedString("\u{FFFC}", attributes: attributes)
            drawn.textual.attachment = AnyAttachment(InlineMath(latex: formula.latex, drawn: formula.drawn ?? formula.latex, isDisplay: formula.isBlock))
            return drawn
        }
    }

    /// Each mark in `text` swapped for what `drawing` makes of its formula, or for the formula as
    /// it was written when it can't be drawn. The marks are found in a plain copy of the text's
    /// bytes, which is quick, rather than by walking its characters, which works out where each
    /// one ends at every step (a long reply is read again with each streamed word); and replaced
    /// last first, so the ones before keep their place.
    nonisolated static func restore(_ text: inout AttributedString, _ formulas: Formulas, drawing: (Formula, AttributeContainer) -> AttributedString) {
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
            let formula = mark.formula.drawn == nil ? AttributedString(mark.formula.source, attributes: attributes) : drawing(mark.formula, attributes)
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
