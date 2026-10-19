import AppKit
import SwiftUI
import Textual

/// A reply's Markdown as TextKit draws it (`ReplyView`): its prose, lists, quotes and tables as
/// one attributed text for each run of them, and its code blocks apart, each a view of its own
/// that scrolls sideways. Styled as Textual's GitHub style is, with our code blocks.
struct ReplyDocument {
    enum Segment {
        /// Prose: paragraphs, headings, lists, quotes, tables and rules.
        case text(NSAttributedString)
        /// A code block, without its last line break.
        case code(code: String, language: String?)
        /// A formula on its own line (`$$…$$`).
        case math(latex: String)
    }

    var segments: [Segment] = []
    /// The space above each segment (the first's is 0).
    var gaps: [CGFloat] = []

    /// The look it's drawn in: the messages' size and typeface.
    struct Style: Hashable {
        var size: CGFloat = 14
        var design: NSFontDescriptor.SystemDesign = .default

        var body: NSFont { Self.font(size, weight: .regular, design: design) }
        var codeSize: CGFloat { size * 0.85 }
        var code: NSFont { NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular) }
        /// Code's lines: Textual's 0.225 of its size between them.
        var codeLineSpacing: CGFloat { codeSize * 0.225 }

        static func font(_ size: CGFloat, weight: NSFont.Weight, design: NSFontDescriptor.SystemDesign, italic: Bool = false) -> NSFont {
            var descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
            if design != .default, let designed = descriptor.withDesign(design) { descriptor = designed }
            if italic { descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic)) }
            return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
        }
    }

    /// Textual's GitHub colors.
    nonisolated enum Colors {
        /// As Textual leaves it: the system's.
        static let primary = NSColor.labelColor
        static let secondary = dynamic(light: (107, 110, 123), dark: (146, 148, 160))
        static let tertiary = dynamic(light: (107, 110, 123), dark: (109, 112, 125))
        static let secondaryBackground = dynamic(light: (247, 247, 249), dark: (37, 38, 42))
        static let link = dynamic(light: (44, 101, 207), dark: (76, 142, 248))
        static let border = dynamic(light: (228, 228, 232), dark: (66, 68, 78))
        static let divider = dynamic(light: (208, 208, 211), dark: (51, 52, 56))

        static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int)) -> NSColor {
            NSColor(name: nil) { appearance in
                let (r, g, b) = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
            }
        }
    }

    // MARK: Building

    /// What a block asks for above and below it; the space between two is the larger.
    private struct Spacing {
        var top: CGFloat
        var bottom: CGFloat
        /// Room of its own under it (a heading's line), on top of the space between.
        var below: CGFloat = 0
    }

    /// One block of prose, before it's put in with the others.
    private struct Block {
        var text: NSMutableAttributedString
        var paragraph: NSMutableParagraphStyle
        var spacing: Spacing
        /// The table it's a cell of.
        var table: Int?
        /// The outermost list it's in: inside one, every block is a quarter line apart.
        var list: Int?
    }

    /// What's known while a document is put together.
    private final class Context {
        var tables: [Int: NSTextTable] = [:]
        var itemsSeen: Set<Int> = []
        /// Each table's columns, as wide as their widest cell on one line.
        var columnWidths: [Int: [Int: CGFloat]] = [:]
        var cells: [Int: [(column: Int, block: NSTextTableBlock)]] = [:]

        /// Tables as wide as their cells need, up to the room there is (Textual's are).
        func sizeTables() {
            for (identity, table) in tables {
                let columns = columnWidths[identity] ?? [:]
                // Each column as wide as its widest cell, unless the table is wider than the room.
                for cell in cells[identity] ?? [] {
                    cell.block.setValue(ceil(columns[cell.column] ?? 0) + 1, type: .absoluteValueType, for: .width)
                }
                table.setValue(100, type: .percentageValueType, for: .maximumWidth)
            }
        }

        func table(_ identity: Int, columns: Int) -> NSTextTable {
            if let table = tables[identity] { return table }
            let table = NSTextTable()
            table.numberOfColumns = max(columns, 1)
            table.collapsesBorders = true
            table.hidesEmptyCells = false
            table.layoutAlgorithm = .automaticLayoutAlgorithm
            table.setWidth(1, type: .absoluteValueType, for: .border)
            table.setBorderColor(Colors.border)
            tables[identity] = table
            return table
        }
    }

    init(markdown: String, parser: some MarkupParser, style: Style) {
        let parsed = (try? parser.attributedString(for: markdown)) ?? AttributedString(markdown)
        let context = Context()
        var text = NSMutableAttributedString()
        // Each paragraph's style and where it is, set once the space after each is known.
        var styles: [(range: NSRange, paragraph: NSMutableParagraphStyle)] = []
        var textGap: CGFloat = 0
        var last: (spacing: Spacing, paragraph: NSMutableParagraphStyle?, table: Int?, list: Int?)?

        func flushText() {
            guard text.length > 0 else { return }
            for style in styles { text.addAttribute(.paragraphStyle, value: style.paragraph.copy(), range: style.range) }
            styles = []
            segments.append(.text(text))
            gaps.append(segments.count == 1 ? 0 : textGap)
            text = NSMutableAttributedString()
        }

        for (intent, range) in parsed.runs[\.presentationIntent] {
            let content = parsed[range]
            let components = intent?.components ?? []
            // A code block: a view of its own.
            if let language = Self.codeLanguage(components) {
                let gap = last.map { $0.spacing.bottom + $0.spacing.below } ?? 0
                flushText()
                var code = String(content.characters)
                if code.hasSuffix("\n") { code.removeLast() }
                if language == MathText.blockLanguage || language?.lowercased() == "math" {
                    segments.append(.math(latex: code.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else {
                    segments.append(.code(code: code, language: language))
                }
                gaps.append(segments.count == 1 ? 0 : gap)
                last = (Spacing(top: 0, bottom: 16), nil, nil, nil)
                continue
            }
            let block = Self.block(content, components: components, style: style, context: context)
            let gap: CGFloat = {
                guard let last else { return 0 }
                if block.table != nil, block.table == last.table { return 0 }
                if block.list != nil, block.list == last.list { return style.size * 0.25 }
                // Out of a list: the list's own space below it; into one, none above it.
                let bottom = last.list != nil ? 16 : last.spacing.bottom
                let top = block.list != nil ? 0 : block.spacing.top
                return max(bottom, top) + last.spacing.below
            }()
            if text.length > 0 {
                // The space goes after the paragraph before (inside a table cell, it'd be inside
                // the cell: then before this one instead, which isn't in that table).
                if let previous = last?.paragraph, last?.table == nil {
                    // TextKit leaves a paragraph's line spacing under its last line too.
                    previous.paragraphSpacing = max(0, gap - previous.lineSpacing)
                } else if block.table == nil {
                    block.paragraph.paragraphSpacingBefore = gap
                }
                text.append(NSAttributedString(string: "\n", attributes: Self.separatorAttributes(of: text)))
                if let lastStyle = styles.indices.last { styles[lastStyle].range.length += 1 }
            } else {
                textGap = gap
            }
            styles.append((NSRange(location: text.length, length: block.text.length), block.paragraph))
            text.append(block.text)
            last = (block.spacing, block.paragraph, block.table, block.list)
        }
        context.sizeTables()
        flushText()
    }

    private static func codeLanguage(_ components: [PresentationIntent.IntentType]) -> String?? {
        for component in components {
            if case .codeBlock(let language) = component.kind { return .some(language) }
        }
        return nil
    }

    /// The line break that ends a paragraph: as its last character is, without what's drawn.
    private static func separatorAttributes(of text: NSAttributedString) -> [NSAttributedString.Key: Any] {
        var attributes = text.attributes(at: text.length - 1, effectiveRange: nil)
        for key in [NSAttributedString.Key.attachment, .link, .backgroundColor, .replyInlineCode] { attributes[key] = nil }
        return attributes
    }

    // MARK: Blocks

    private static func block(_ content: AttributedSubstring, components: [PresentationIntent.IntentType], style: Style, context: Context) -> Block {
        let size = style.size
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = size * 0.25
        var weight = NSFont.Weight.regular
        var fontSize = size
        var color = Colors.primary
        var spacing = Spacing(top: 0, bottom: 16)
        var marker: NSAttributedString?
        var indent: CGFloat = 0
        var quoteDepth = 0
        var rule: ReplyRule?
        var table: Int?
        let list = components.last { component in
            switch component.kind {
            case .orderedList, .unorderedList: true
            default: false
            }
        }?.identity

        // Outermost first: lists and quotes indent what's inside them.
        let outward = Array(components.reversed())
        var listDepth = 0
        for (index, component) in outward.enumerated() {
            switch component.kind {
            case .blockQuote:
                quoteDepth += 1
                indent += size * 1.2
                color = Colors.secondary
            case .orderedList, .unorderedList:
                listDepth += 1
            case .listItem(let ordinal):
                let markerRight = indent + size * 1.5
                indent += size * 2
                // Its marker on its first paragraph only.
                guard context.itemsSeen.insert(component.identity).inserted else { break }
                let isOrdered: Bool = {
                    if index > 0, case .orderedList = outward[index - 1].kind { return true }
                    return false
                }()
                if isOrdered {
                    marker = NSAttributedString(string: "\t\(ordinal).\t", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular), .foregroundColor: color])
                } else {
                    let bullet = NSMutableAttributedString(string: "\t", attributes: [.font: style.body])
                    bullet.append(ReplyAttachments.bullet(level: listDepth - 1, size: size, font: style.body))
                    bullet.append(NSAttributedString(string: "\t", attributes: [.font: style.body]))
                    marker = bullet
                }
                paragraph.tabStops = [NSTextTab(textAlignment: .right, location: markerRight), NSTextTab(textAlignment: .left, location: indent)]
            case .header(let level):
                let scale = [2, 1.5, 1.25, 1, 0.875, 0.85][min(max(level, 1), 6) - 1]
                fontSize = size * scale
                weight = .semibold
                paragraph.lineSpacing = fontSize * 0.125
                spacing = Spacing(top: 24, bottom: 16)
                if level == 6 { color = Colors.tertiary }
                if level <= 2 {
                    rule = .underline(gap: size * 0.3)
                    // Room for the line.
                    spacing.below = size * 0.3 + 1
                }
            case .thematicBreak:
                rule = .line(height: size * 0.25)
                spacing = Spacing(top: 24, bottom: 24)
            case .tableCell(let column):
                let row = outward.lazy.compactMap { component -> Int? in
                    switch component.kind {
                    case .tableHeaderRow: 0
                    case .tableRow(let index): index
                    default: nil
                    }
                }.first ?? 0
                guard let tableComponent = outward.first(where: { if case .table = $0.kind { true } else { false } }),
                      case .table(let columns) = tableComponent.kind else { break }
                table = tableComponent.identity
                let cell = NSTextTableBlock(table: context.table(tableComponent.identity, columns: columns.count), startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cell.setWidth(1, type: .absoluteValueType, for: .border)
                cell.setBorderColor(Colors.border)
                cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
                // Less the line spacing TextKit leaves under the last line.
                cell.setWidth(max(0, 6 - size * 0.25), type: .absoluteValueType, for: .padding, edge: .maxY)
                cell.setWidth(13, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(13, type: .absoluteValueType, for: .padding, edge: .maxX)
                if row > 0, row % 2 == 0 { cell.backgroundColor = Colors.secondaryBackground }
                paragraph.textBlocks = [cell]
                context.cells[tableComponent.identity, default: []].append((column, cell))
                if row == 0 { weight = .semibold }
                spacing = Spacing(top: 0, bottom: 16)
            default:
                break
            }
        }
        paragraph.firstLineHeadIndent = marker == nil ? indent : 0
        paragraph.headIndent = indent

        let text = NSMutableAttributedString()
        if let marker { text.append(marker) }
        for run in content.runs {
            let inline = run.inlinePresentationIntent ?? []
            let isCode = inline.contains(.code)
            let runWeight: NSFont.Weight = inline.contains(.stronglyEmphasized) ? .semibold : weight
            let font = isCode
                ? NSFont.monospacedSystemFont(ofSize: fontSize * 0.85, weight: runWeight)
                : Style.font(fontSize, weight: runWeight, design: style.design, italic: inline.contains(.emphasized))
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if isCode { attributes[.replyInlineCode] = true }
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let url = run.link {
                attributes[.link] = url
                attributes[.foregroundColor] = Colors.link
            }
            // Find's marks.
            if let background = run.swiftUI.backgroundColor { attributes[.backgroundColor] = NSColor(background) }
            if let foreground = run.swiftUI.foregroundColor { attributes[.foregroundColor] = NSColor(foreground) }
            if let attachment = run.textual.attachment {
                text.append(ReplyAttachments.attachment(for: attachment, attributes: attributes, size: fontSize))
                continue
            }
            // A line break inside a paragraph, not a new paragraph.
            let string = String(content[run.range].characters).replacingOccurrences(of: "\n", with: "\u{2028}")
            text.append(NSAttributedString(string: string, attributes: attributes))
        }
        if let table, case .tableCell(let column)? = components.first(where: { if case .tableCell = $0.kind { true } else { false } })?.kind {
            let width = text.size().width
            context.columnWidths[table, default: [:]][column] = max(context.columnWidths[table]?[column] ?? 0, width)
        }
        if case .line = rule {
            text.setAttributedString(NSAttributedString(string: "\u{200B}", attributes: [.font: NSFont.systemFont(ofSize: 1)]))
        }
        let whole = NSRange(location: 0, length: text.length)
        if quoteDepth > 0 { text.addAttribute(.replyQuote, value: quoteDepth, range: whole) }
        if let rule { text.addAttribute(.replyRule, value: rule, range: whole) }
        return Block(text: text, paragraph: paragraph, spacing: spacing, table: table, list: list)
    }
}

/// A heading's line under it, or a line on its own (`---`).
nonisolated enum ReplyRule {
    case underline(gap: CGFloat)
    case line(height: CGFloat)
}

extension NSAttributedString.Key {
    /// Inline code, drawn on a rounded background.
    nonisolated static let replyInlineCode = NSAttributedString.Key("kuvo.reply.inlineCode")
    /// How many quotes it's in, drawn as a bar beside it.
    nonisolated static let replyQuote = NSAttributedString.Key("kuvo.reply.quote")
    /// A rule under a heading, or one on its own.
    nonisolated static let replyRule = NSAttributedString.Key("kuvo.reply.rule")
}

/// Textual's attachments (a file's icon, a formula, a bot's face) as pictures in the text.
enum ReplyAttachments {
    private static var images: [String: NSImage] = [:]

    /// A list's bullet, as Textual's: a dot, a ring, a square, by how deep the list is; a third
    /// of the text's size, on the middle of its first line.
    static func bullet(level: Int, size: CGFloat, font: NSFont) -> NSAttributedString {
        let name = ["circle.fill", "circle", "square.fill"][level % 3]
        let item = NSTextAttachment()
        let side = (size * 0.33).rounded()
        item.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: side, weight: .regular).applying(.init(paletteColors: [.labelColor])))
        item.bounds = CGRect(x: 0, y: (font.xHeight - side) / 2 + font.xHeight * 0.1, width: side, height: side)
        return NSAttributedString(attachment: item)
    }

    static func attachment(for attachment: AnyAttachment, attributes: [NSAttributedString.Key: Any], size: CGFloat) -> NSAttributedString {
        let item = NSTextAttachment()
        if attachment.base is FileIconAttachment {
            item.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size * 0.85, weight: .light).applying(.init(paletteColors: [.controlAccentColor])))
            item.bounds = CGRect(x: 0, y: -size * 0.12, width: size * 0.78, height: size * 0.92)
        } else {
            let key = "\(attachment.description)|\(size)"
            let image = images[key] ?? {
                let renderer = ImageRenderer(content: attachment.body.font(.system(size: size)).fixedSize())
                renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
                let image = renderer.nsImage ?? NSImage()
                images[key] = image
                return image
            }()
            item.image = image
            item.bounds = CGRect(x: 0, y: -size * 0.2, width: image.size.width, height: image.size.height)
        }
        let text = NSMutableAttributedString(attachment: item)
        let kept = attributes.filter { $0.key != .backgroundColor && $0.key != .replyInlineCode }
        text.addAttributes(kept, range: NSRange(location: 0, length: text.length))
        return text
    }
}
