import AppKit
import SwiftUI
import Textual

/// Code blocks in replies and Markdown: one recessed well with the code and its line numbers,
/// and the language and a Copy button in its top corner.
struct CopyableCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        CopyableCodeBlock(configuration: configuration)
    }
}

private struct CopyableCodeBlock: View {
    let configuration: StructuredText.CodeBlockStyleConfiguration
    @State private var copied = false
    @State private var isHoveringCopy = false
    /// The code's height, which the line numbers are spaced out over.
    @State private var codeHeight: CGFloat = 0
    @Environment(\.colorScheme) private var scheme
    @Environment(\.cardIsFocused) private var cardIsFocused
    @Environment(\.findHighlight) private var highlight

    private static let shape = RoundedRectangle(cornerRadius: 10)
    /// The same room above and below the code.
    private static let inset: CGFloat = 12

    /// How many lines the code has, for its numbers. Textual keeps the code itself private, so
    /// this reads it from the copy action's proxy; nil (no numbers) if a Textual update moves it.
    private var lineCount: Int? {
        guard let content else { return nil }
        return content.characters.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private var content: AttributedSubstring? {
        Mirror(reflecting: configuration.codeBlock).descendant("content") as? AttributedSubstring
    }

    /// The code with Find's marks in it, while Find has places there: drawn without its colors,
    /// as the highlighter colors it over the marks.
    private var marked: AttributedString? {
        guard highlight != nil, let content, content.runs.contains(where: { $0.attributes.swiftUI.backgroundColor != nil }) else { return nil }
        var code = AttributedString(content)
        if code.characters.last == "\n" { code.characters.removeLast() }
        return code
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Beside the code, not in it: selecting and copying code never takes the numbers.
            if let lineCount, lineCount > 1 {
                LineNumbers(count: lineCount, height: codeHeight)
                    .padding(.leading, 12)
                    .padding(.vertical, Self.inset)
            }
            Overflow {
                Group {
                    if let marked {
                        Text(marked)
                            .transcriptCodeFont()
                            .lineSpacing(3)
                    } else {
                        configuration.label
                    }
                }
                    .textual.lineSpacing(.fontScaled(0.225))
                    .textual.fontScale(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                    .monospaced()
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { codeHeight = $0 }
                    .padding(.horizontal, 14)
                    .padding(.vertical, Self.inset)
            }
        }
        // Outside the scrolling code, so they stay in the corner when long lines scroll sideways.
        // They float over the first line; a long one runs in under them.
        .overlay(alignment: .topTrailing) {
            corner
                .padding(.leading, 28)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .background { cornerBackdrop }
        }
        .clipShape(Self.shape)
        .recessedWell(Self.shape)
        .textual.blockSpacing(.init(top: 0, bottom: 16))
        #if DEBUG
        .onAppear { ScrollFrameMonitor.codeBlocksMade += 1 }
        #endif
    }

    /// The well's own color, solid, fading in from the left: code under the corner disappears
    /// into it instead of running into the words.
    private var cornerBackdrop: some View {
        ZStack {
            Surface.cardFill(scheme, focused: cardIsFocused)
            Surface.well(scheme)
        }
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 28)
                Color.black
            }
        }
        .allowsHitTesting(false)
    }

    private var corner: some View {
        HStack(spacing: 2) {
            Text(CodeLanguage.name(of: configuration.languageHint))
                .foregroundStyle(.tertiary)
            Button {
                configuration.codeBlock.copyToPasteboard()
                withAnimation(.ui) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation(.ui) { copied = false }
                }
            } label: {
                // As wide as "Copied", so the language beside it stays put when it changes.
                ZStack {
                    Label("Copied", systemImage: "checkmark")
                        .hidden()
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .buttonStyle(CornerButtonStyle(isHovering: isHoveringCopy))
            .background(HoverTracker { isHoveringCopy = $0 })
            .help("Copy Code")
        }
        .font(.system(size: 11, weight: .medium))
    }
}

/// Copy's look: TextButtonStyle's, with the hover handed in from a tracking area.
private struct CornerButtonStyle: ButtonStyle {
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .background(configuration.isPressed ? Pressable.pressedFill : isHovering ? Pressable.hoverFill : .clear, in: .rect(cornerRadius: 5))
            .contentShape(.rect(cornerRadius: 5))
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// A code block's line numbers, one per line of the code beside it. Its lines never wrap (long
/// ones scroll sideways), so each line's share of the code's height is where its number goes.
private struct LineNumbers: View {
    let count: Int
    let height: CGFloat

    /// The code's size in the transcript: 14 points, scaled to 0.85.
    private static let fontSize: CGFloat = 14 * 0.85
    /// The space Textual puts between lines (0.225 of the font size), which the last line doesn't have.
    private static let spacing: CGFloat = fontSize * 0.225

    var body: some View {
        let pitch = count > 0 ? (height + Self.spacing) / CGFloat(count) : 0
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(1...count, id: \.self) { number in
                Text(verbatim: "\(number)")
                    .frame(height: pitch, alignment: .top)
            }
        }
        .font(.system(size: Self.fontSize, design: .monospaced))
        .foregroundStyle(.tertiary)
        .frame(height: height, alignment: .top)
        .opacity(height > 0 ? 1 : 0)
        .textSelection(.disabled)
        .accessibilityHidden(true)
    }
}

/// A code block's language as people write it: "swift" is Swift, "ts" is TypeScript. One
/// without a language is just code.
enum CodeLanguage {
    static func name(of hint: String?) -> String {
        guard let hint = hint?.trimmingCharacters(in: .whitespaces).lowercased(), !hint.isEmpty else { return "Code" }
        if let name = names[hint] { return name }
        // Unknown ones as written, capitalized: "elixir" is Elixir.
        return hint.prefix(1).uppercased() + hint.dropFirst()
    }

    private static let names: [String: String] = [
        "swift": "Swift", "objc": "Objective-C", "objective-c": "Objective-C",
        "js": "JavaScript", "javascript": "JavaScript", "jsx": "JSX", "mjs": "JavaScript", "cjs": "JavaScript",
        "ts": "TypeScript", "typescript": "TypeScript", "tsx": "TSX",
        "py": "Python", "python": "Python", "rb": "Ruby", "ruby": "Ruby",
        "go": "Go", "golang": "Go", "rs": "Rust", "rust": "Rust",
        "java": "Java", "kt": "Kotlin", "kotlin": "Kotlin", "scala": "Scala",
        "c": "C", "h": "C", "cpp": "C++", "c++": "C++", "cc": "C++", "hpp": "C++", "cs": "C#", "csharp": "C#",
        "php": "PHP", "dart": "Dart", "lua": "Lua", "r": "R", "zig": "Zig", "ex": "Elixir", "exs": "Elixir",
        "sh": "Shell", "shell": "Shell", "bash": "Bash", "zsh": "Zsh", "fish": "Fish", "console": "Terminal",
        "powershell": "PowerShell", "ps1": "PowerShell",
        "html": "HTML", "xml": "XML", "svg": "SVG", "css": "CSS", "scss": "SCSS", "sass": "Sass", "less": "Less",
        "json": "JSON", "jsonc": "JSON", "yaml": "YAML", "yml": "YAML", "toml": "TOML", "ini": "INI",
        "md": "Markdown", "markdown": "Markdown", "sql": "SQL", "graphql": "GraphQL", "gql": "GraphQL",
        "dockerfile": "Dockerfile", "docker": "Dockerfile", "makefile": "Makefile", "make": "Makefile",
        "diff": "Diff", "patch": "Diff", "text": "Text", "txt": "Text", "plaintext": "Text",
        "vue": "Vue", "svelte": "Svelte", "proto": "Protocol Buffers", "tf": "Terraform", "hcl": "HCL",
    ]
}
