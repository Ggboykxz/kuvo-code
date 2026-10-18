import Foundation

/// Code blocks colored ahead of time.
public enum CodeHighlighting {
  /// Reads the code blocks in `markdown` (as `StructuredText` would read them) into tokens, off
  /// the main thread, so that when they show, they're colored at once rather than plain first.
  public static func prepare(markdown texts: [String]) async {
    let blocks = await Task.detached(priority: .utility) {
      var blocks: [(code: String, language: String)] = []
      var seen = Set<String>()
      for text in texts where text.contains("```") || text.contains("~~~") {
        // Foundation's Markdown, as `AttributedStringMarkdownParser.markdown()` reads it (its own
        // syntax extensions don't touch code blocks), which can be read off the main thread.
        guard let parsed = try? AttributedString(markdown: text) else { continue }
        for (intent, range) in parsed.runs[\.presentationIntent] {
          let language = intent?.components.lazy.compactMap { component -> String? in
            if case .codeBlock(let language) = component.kind { language } else { nil }
          }.first
          guard let language, language.lowercased() != "math" else { continue }
          // As a code block shows it: without its last line break.
          var code = String(parsed[range].characters)
          if code.hasSuffix("\n") { code.removeLast() }
          if seen.insert(language + "\u{0}" + code).inserted { blocks.append((code, language)) }
        }
      }
      return blocks
    }.value
    let unread = await MainActor.run { blocks.filter { TokenCache.shared.tokens(of: $0.code, in: $0.language) == nil } }
    guard !unread.isEmpty, let tokenizer = await CodeTokenizer.loaded() else { return }
    for block in unread {
      guard !Task.isCancelled else { return }
      let tokens = await tokenizer.tokenize(code: block.code, language: block.language)
      await MainActor.run { TokenCache.shared.insert(tokens, of: block.code, in: block.language) }
    }
  }
}
