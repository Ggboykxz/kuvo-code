import OpenCodeKit
import SwiftUI

/// One tool call: a single line saying what the agent did, which opens to show
/// the details (a diff for edits, output for commands).
struct ToolCallView: View {
    let call: Message.ToolCall
    let directory: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard hasDetails else { return }
                withAnimation(.ui) { isExpanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)

            if isExpanded, hasDetails {
                details
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 16)
            Text(summary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let stat = diffStat {
                DiffStat(additions: stat.additions, deletions: stat.deletions)
            }
            if case .failed(_, let error, _, _) = call.state {
                Text(error.message)
                    .lineLimit(1)
                    .foregroundStyle(.red)
            }
            if hasDetails {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .contentShape(.rect)
    }

    @ViewBuilder private var icon: some View {
        switch call.state {
        case .streaming, .running:
            ProgressView().controlSize(.mini)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .completed:
            Image(systemName: symbol)
        }
    }

    // MARK: Describing the call

    private var input: JSONValue? { call.state.input }

    private func string(_ key: String) -> String? { input?[key]?.string }

    private func relative(_ path: String?) -> String? {
        guard let path else { return nil }
        let base = directory.hasSuffix("/") ? directory : directory + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : (path as NSString).abbreviatingWithTildeInPath
    }

    private var isActive: Bool { !call.state.isFinished }

    private var summary: String {
        let path = relative(string("path"))
        switch call.name {
        case "read": return (isActive ? "Reading " : "Read ") + (path ?? "a file")
        case "write": return (isActive ? "Writing " : "Wrote ") + (path ?? "a file")
        case "edit": return (isActive ? "Editing " : "Edited ") + (path ?? "a file")
        case "patch":
            let files = diffs.map { relative($0.file) ?? $0.file }
            return (isActive ? "Editing " : "Edited ") + (files.count == 1 ? files[0] : files.isEmpty ? "files" : "\(files.count) files")
        case "shell":
            return (isActive ? "Running " : "Ran ") + (string("command").map { "`\($0)`" } ?? "a command") + exitSuffix
        case "grep": return "Searched for “\(string("pattern") ?? "")”" + (path.map { " in \($0)" } ?? "")
        case "glob": return "Found files matching \(string("pattern") ?? "")"
        case "webfetch": return (isActive ? "Fetching " : "Fetched ") + (string("url") ?? "a page")
        case "websearch": return "Searched the web for “\(string("query") ?? "")”"
        case "question": return isActive ? "Asking you a question" : "Asked you a question"
        case "subagent": return (string("description") ?? "Delegated a task") + (string("agent").map { " · \($0)" } ?? "")
        case "skill": return "Used a skill"
        default:
            if let browsing = browserSummary { return browsing }
            return call.name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// The panel browser's tools (served as "kuvo-browser_browser_…"), in words.
    private var browserSummary: String? {
        guard call.name.hasPrefix("kuvo-browser_") else { return nil }
        let index = input?["index"]?.number.map { "[\(Int($0))]" } ?? "an element"
        switch call.name.dropFirst("kuvo-browser_".count) {
        case "browser_navigate": return (isActive ? "Opening " : "Opened ") + (string("url") ?? "a page")
        case "browser_new_tab": return "Opened a new tab" + (string("url").map { " at \($0)" } ?? "")
        case "browser_snapshot": return isActive ? "Reading the page" : "Read the page"
        case "browser_text": return isActive ? "Reading the page's text" : "Read the page's text"
        case "browser_click": return (isActive ? "Clicking " : "Clicked ") + index
        case "browser_type": return (isActive ? "Typing into " : "Typed into ") + index + (string("text").map { ": “\($0)”" } ?? "")
        case "browser_select": return "Chose “\(string("option") ?? "")” in \(index)"
        case "browser_scroll": return "Scrolled " + (string("direction") ?? "down")
        case "browser_press": return "Pressed " + (string("key") ?? "a key")
        case "browser_back": return "Went back"
        case "browser_forward": return "Went forward"
        case "browser_screenshot": return isActive ? "Taking a screenshot" : "Took a screenshot"
        case "browser_wait": return "Waited for the page"
        default: return "Used the browser"
        }
    }

    private var exitSuffix: String {
        guard case .completed(_, _, let metadata) = call.state, let exit = metadata?["exit"]?.number, exit != 0 else { return "" }
        return " (exit \(Int(exit)))"
    }

    private var symbol: String {
        switch call.name {
        case "read": "doc.text"
        case "write": "doc.badge.plus"
        case "edit", "patch": "pencil"
        case "shell": "terminal"
        case "grep", "glob": "magnifyingglass"
        case "webfetch", "websearch": "globe"
        case "question": "questionmark.bubble"
        case "subagent": "person.2"
        case "skill": "wand.and.stars"
        default: call.name.hasPrefix("kuvo-browser_") ? "safari" : "wrench.and.screwdriver"
        }
    }

    private var diffs: [FileDiff] {
        (try? call.state.metadata?["files"]?.decode(as: [FileDiff].self)) ?? []
    }

    private var diffStat: (additions: Int, deletions: Int)? {
        let diffs = diffs
        guard !diffs.isEmpty else { return nil }
        return (diffs.reduce(0) { $0 + $1.additions }, diffs.reduce(0) { $0 + $1.deletions })
    }

    private var outputText: String {
        switch call.state {
        case .completed(_, let output, _): output.compactMap(\.text).joined(separator: "\n")
        case .failed(_, let error, let output, _): ([error.message] + (output ?? []).compactMap(\.text)).joined(separator: "\n")
        default: ""
        }
    }

    private var hasDetails: Bool {
        !diffs.isEmpty || (call.name == "shell" && !outputText.isEmpty) || call.state.isFailure
    }

    @ViewBuilder private var details: some View {
        if !diffs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(diffs) { diff in
                    DiffView(diff: diff, title: relative(diff.file) ?? diff.file, maxLines: 80)
                }
            }
        } else {
            ScrollView(.horizontal) {
                Text(outputText.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.transcriptCode)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
            .frame(maxHeight: 260)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        }
    }
}

extension Message.ToolState {
    var isFailure: Bool {
        if case .failed = self { true } else { false }
    }
}
