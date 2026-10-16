import OpenCodeKit
import SwiftUI

/// How much of the agent's work shows between its replies: each step, the steps summed up in a
/// line (opening to each), or barely more than how many there were.
enum StepsDetail: String, CaseIterable, Identifiable {
    case each, summary, minimal

    static let key = "transcript.steps"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .each: "Each Step"
        case .summary: "Summarized"
        case .minimal: "Minimal"
        }
    }
}

/// The agent's steps between two of its replies, in a line ("Thought for 40s, ran 6 commands,
/// read 3 files"), opening to each. While it works, the step under way shows under the line.
struct StepsRow: View {
    let blocks: [Message.Content]
    let isLive: Bool
    let directory: String
    @AppStorage(StepsDetail.key) private var detail = StepsDetail.summary
    @State private var isExpanded = false

    var body: some View {
        // The one under way, as it is; those before it in the line.
        let current = isLive ? blocks.last : nil
        let done = isLive ? Array(blocks.dropLast()) : blocks
        VStack(alignment: .leading, spacing: 10) {
            if !done.isEmpty {
                Button {
                    withAnimation(.ui) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet")
                            .frame(width: 16)
                        Text(detail == .minimal ? Self.count(done) : Self.summary(of: done))
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .font(.callout)
                    .foregroundStyle(detail == .minimal ? .tertiary : .secondary)
                }
                .buttonStyle(TextButtonStyle(outset: true))
                .help(isExpanded ? "Hide the steps" : "Show each step")
                if isExpanded {
                    ForEach(Array(done.enumerated()), id: \.offset) { _, block in step(block) }
                        .transition(.opacity)
                }
            }
            if let current { step(current) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func step(_ block: Message.Content) -> some View {
        switch block {
        case .reasoning(let reasoning): ReasoningView(block: reasoning)
        case .tool(let call): ToolCallView(call: call, directory: directory)
        default: EmptyView()
        }
    }

    /// "12 steps".
    static func count(_ blocks: [Message.Content]) -> String {
        blocks.count == 1 ? "1 step" : "\(blocks.count) steps"
    }

    /// "Thought for 40s, ran 6 commands, read 3 files (1 failed)".
    static func summary(of blocks: [Message.Content]) -> String {
        let calls = blocks.compactMap { if case .tool(let call) = $0 { call } else { nil } }
        let thought = blocks.reduce(0.0) { total, block in
            guard case .reasoning(let text) = block, let start = text.time?.created, let end = text.time?.completed else { return total }
            return total + (end - start) / 1000
        }
        var parts: [String] = []
        if blocks.contains(where: { if case .reasoning = $0 { true } else { false } }) {
            let seconds = max(1, Int(thought))
            parts.append(seconds < 60 ? "thought for \(seconds)s" : "thought for \(seconds / 60)m \(seconds % 60)s")
        }
        if !calls.isEmpty { parts.append(StepsSummary.summary(of: calls, capitalized: false)) }
        let failed = calls.count { if case .failed = $0.state { true } else { false } }
        let text = parts.joined(separator: ", ") + (failed > 0 ? " (\(failed) failed)" : "")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// Tool calls in words, each kind once, in the order first done: "Searched the web 4 times,
/// fetched a page".
enum StepsSummary {
    static func summary(of steps: [Message.ToolCall], capitalized: Bool = true) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for step in steps {
            let kind = kind(of: step.name)
            if counts[kind] == nil { order.append(kind) }
            counts[kind, default: 0] += 1
        }
        let text = order.map { phrase(kind: $0, count: counts[$0] ?? 1) }.joined(separator: ", ")
        return capitalized ? text.prefix(1).uppercased() + text.dropFirst() : text
    }

    private static func kind(of name: String) -> String {
        // The browser's tools, as the engine names them ("kuvo-browser_browser_click").
        if name.hasPrefix("kuvo-browser_browser_") || name.hasPrefix("browser_") { return "browser" }
        switch name {
        case "grep", "glob", "list": return "search"
        case "bash", "shell": return "shell"
        case "edit", "write", "patch": return "edit"
        case "kuvo-browser_show_in_panel": return "show"
        default: return name
        }
    }

    private static func phrase(kind: String, count: Int) -> String {
        let many = count > 1
        switch kind {
        case "websearch": return many ? "searched the web \(count) times" : "searched the web"
        case "webfetch": return many ? "fetched \(count) pages" : "fetched a page"
        case "read": return many ? "read \(count) files" : "read a file"
        case "search": return many ? "searched the files \(count) times" : "searched the files"
        case "shell": return many ? "ran \(count) commands" : "ran a command"
        case "edit": return many ? "edited files \(count) times" : "edited a file"
        case "browser": return many ? "used the browser (\(count) steps)" : "used the browser"
        case "subagent": return many ? "handed off \(count) tasks" : "handed off a task"
        case "question": return many ? "asked you \(count) questions" : "asked you a question"
        case "show": return many ? "showed you \(count) things" : "showed you something"
        case "todowrite", "todoread": return "kept its to-do list"
        default: return many ? "used \(kind) \(count) times" : "used \(kind)"
        }
    }
}
