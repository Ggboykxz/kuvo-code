import AppKit
import SwiftUI
import Textual

/// Code blocks in replies and Markdown: a header with the language and a Copy button, over
/// the code on GitHub's code background, with line numbers beside it.
struct CopyableCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        CopyableCodeBlock(configuration: configuration)
    }
}

private struct CopyableCodeBlock: View {
    let configuration: StructuredText.CodeBlockStyleConfiguration
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false
    /// The code's height, which the line numbers are spaced out over.
    @State private var codeHeight: CGFloat = 0

    /// How many lines the code has, for its numbers. Textual keeps the code itself private, so
    /// this reads it from the copy action's proxy; nil (no numbers) if a Textual update moves it.
    private var lineCount: Int? {
        guard let content = Mirror(reflecting: configuration.codeBlock).descendant("content") as? AttributedSubstring else { return nil }
        return content.characters.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// GitHub's secondary background, as its own code blocks use.
    private var background: Color {
        scheme == .dark ? Color(red: 37 / 255, green: 38 / 255, blue: 42 / 255) : Color(red: 247 / 255, green: 247 / 255, blue: 249 / 255)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(CodeLanguage.name(of: configuration.languageHint))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    configuration.codeBlock.copyToPasteboard()
                    withAnimation(.ui) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation(.ui) { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11.5, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(TextButtonStyle())
                .help("Copy Code")
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(height: 32)
            .background(Color.primary.opacity(scheme == .dark ? 0.04 : 0.03))
            Divider().opacity(0.6)
            HStack(alignment: .top, spacing: 0) {
                // Beside the code, not in it: selecting and copying code never takes the numbers.
                if let lineCount, lineCount > 1 {
                    LineNumbers(count: lineCount, height: codeHeight)
                        .padding(.leading, 12)
                        .padding(.vertical, 12)
                }
                Overflow {
                    configuration.label
                        .textual.lineSpacing(.fontScaled(0.225))
                        .textual.fontScale(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                        .monospaced()
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { codeHeight = $0 }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
            }
        }
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.06)))
        .textual.blockSpacing(.init(top: 0, bottom: 16))
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
