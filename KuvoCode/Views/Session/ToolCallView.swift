import AppKit
import OpenCodeKit
import SwiftUI

/// One tool call: a single line saying what the agent did, which opens to show
/// the details (a diff for edits, output for commands) inline under it, joined to its icon
/// by a thin line, like a tree.
struct ToolCallView: View {
    let call: Message.ToolCall
    let directory: String
    @Environment(AppModel.self) private var app
    @State private var isExpanded = false

    /// The icon's column, and the gap after it: the details line up with the title.
    private static let iconWidth: CGFloat = 16
    private static let iconGap: CGFloat = 8

    /// The file a read, write or edit was about, where it is on disk.
    private var file: URL? {
        guard ["read", "write", "edit"].contains(call.name), let path = string("path") else { return nil }
        return RemoteFolder.fileURL(path, in: directory)
    }

    var body: some View {
        // Something the agent made: drawn, not described.
        if WidgetCard.isWidget(call) {
            WidgetCard(call: call, send: answerAgent)
        } else {
            step
        }
    }

    @Environment(\.answerAgent) private var answerAgent

    @ViewBuilder private var step: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A step with details opens like a button, and lights up like one; the rest are lines.
            Group {
                if hasDetails {
                    Button {
                        withAnimation(.ui) { isExpanded.toggle() }
                    } label: {
                        header
                    }
                    .buttonStyle(TextButtonStyle(outset: true))
                } else if let shown = shownInPanel {
                    // What the agent showed you in the panel: a click shows it again.
                    Button {
                        app.utilities.show(shown.url, isFolder: shown.isFolder)
                    } label: {
                        header
                    }
                    .buttonStyle(TextButtonStyle(outset: true))
                    .help("Show it in the panel")
                } else {
                    header.foregroundStyle(.secondary)
                }
            }
            .contextMenu {
                if let file, !file.isFileURL {
                    Button("Open in Panel") { app.utilities.show(file) }
                } else if let file, FileManager.default.fileExists(atPath: file.path) {
                    Button("Open in Panel") { app.utilities.show(file) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
                if let file {
                    Button("Copy Path") { Clipboard.copy(file.path) }
                }
            }

            if isExpanded, hasDetails {
                details
                    .padding(.leading, Self.iconWidth + Self.iconGap)
                    .padding(.top, 8)
                    .overlay(alignment: .topLeading) {
                        // The line down from the icon, beside what it opened.
                        Capsule()
                            .fill(.separator)
                            .frame(width: 1)
                            .padding(.top, 3)
                            .padding(.leading, (Self.iconWidth - 1) / 2)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // A subagent at work shows what it's doing; opened later, its steps stay folded.
        .onAppear {
            if call.name == "subagent", !call.state.isFinished { isExpanded = true }
            #if DEBUG
            // KUVO_DEMO_OPEN_STEPS: every step shows its details, for screenshots.
            if ProcessInfo.processInfo.environment["KUVO_DEMO_OPEN_STEPS"] != nil { isExpanded = true }
            #endif
        }
    }

    private var header: some View {
        HStack(spacing: Self.iconGap) {
            icon
                .frame(width: Self.iconWidth)
            Text(summary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let stat = diffStat {
                DiffStat(additions: stat.additions, deletions: stat.deletions)
            }
            if case .failed(_, let error, _, _) = call.state {
                if error.isInterruption {
                    Text("Stopped")
                } else {
                    Text(error.message)
                        .lineLimit(1)
                        .foregroundStyle(.red)
                }
            }
            if hasDetails {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .contentShape(.rect)
    }

    @ViewBuilder private var icon: some View {
        switch call.state {
        case .streaming, .running:
            Spinner(size: 11)
        case .completed where isAtWork:
            Spinner(size: 11)
                .help("Working in the background")
        case .failed(_, let error, _, _) where error.isInterruption:
            Image(systemName: "stop.circle")
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
        // A machine's engine names files as they are there, without the ssh:// prefix.
        let directory = RemoteFolder.parse(directory)?.path ?? directory
        let base = directory.hasSuffix("/") ? directory : directory + "/"
        // The project folder itself goes by its name.
        if path == directory || path == base { return (directory as NSString).lastPathComponent }
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : (path as NSString).abbreviatingWithTildeInPath
    }

    private var isActive: Bool { !call.state.isFinished }

    /// What the call did, in words: its line in the transcript.
    static func summary(of call: Message.ToolCall, in directory: String) -> String {
        ToolCallView(call: call, directory: directory).summary
    }

    private var summary: String {
        let path = relative(string("path"))
        // A bot's memory file goes by what it is.
        if let raw = string("path"), Bots.isMemory(raw), ["read", "write", "edit"].contains(call.name) {
            return call.name == "read" ? (isActive ? "Reading its memory" : "Read its memory") : (isActive ? "Updating its memory" : "Updated its memory")
        }
        switch call.name {
        case "read": return (isActive ? "Reading " : "Read ") + (path ?? "a file")
        case "write": return (isActive ? "Writing " : "Wrote ") + (path ?? "a file")
        case "edit": return (isActive ? "Editing " : "Edited ") + (path ?? "a file")
        case "patch":
            let files = diffs.map { relative($0.file) ?? $0.file }
            return (isActive ? "Editing " : "Edited ") + (files.count == 1 ? files[0] : files.isEmpty ? "files" : "\(files.count) files")
        case "shell":
            if let wake = wake { return Self.summary(of: wake, isActive: isActive) + exitSuffix }
            return (isActive ? "Running " : "Ran ") + (string("command").map { "`\($0)`" } ?? "a command") + exitSuffix
        case "grep": return "Searched for “\(string("pattern") ?? "")”" + (path.map { " in \($0)" } ?? "")
        case "glob": return "Found files matching \(string("pattern") ?? "")"
        case "webfetch": return (isActive ? "Fetching " : "Fetched ") + (string("url") ?? "a page")
        case "websearch": return "Searched the web for “\(string("query") ?? "")”"
        case "question": return isActive ? "Asking you a question" : "Asked you a question"
        case "subagent": return (string("description") ?? (isActive ? "Starting a subagent…" : "A subagent's task")) + (string("agent").map { " · \($0)" } ?? "")
        case "skill": return "Used a skill"
        case "execute":
            // Code Mode: the agent wrote code that calls its tools.
            let calls = call.state.metadata?["toolCalls"]?.array?.count ?? 0
            let failed = call.state.metadata?["error"]?.bool == true
            return (isActive ? "Running code" : "Ran code") + (calls > 0 ? " using \(calls) tool\(calls == 1 ? "" : "s")" : "") + (failed && !isActive ? " (it failed)" : "")
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
        case "browser_wait": return string("text").map { (isActive ? "Waiting for “" : "Waited for “") + $0 + "”" } ?? "Waited for the page"
        case "browser_hover": return (isActive ? "Hovering over " : "Hovered over ") + index
        case "browser_tabs":
            let tab = input?["tab"]?.number.map { " [\(Int($0))]" } ?? ""
            switch string("action") {
            case "switch": return (isActive ? "Switching to tab" : "Switched to tab") + tab
            case "close": return (isActive ? "Closing tab" : "Closed tab") + tab
            default: return isActive ? "Looking at the tabs" : "Looked at the tabs"
            }
        case "browser_upload":
            let count = input?["files"]?.array?.count ?? 1
            return (isActive ? "Attaching " : "Attached ") + (count == 1 ? "a file" : "\(count) files") + " to \(index)"
        case "browser_sign_in": return isActive ? "Waiting for your sign-in" : "Asked you to sign in"
        case "browser_ask_code": return isActive ? "Waiting for your code" : "Asked you for a code"
        case "browser_ask_user": return isActive ? "Waiting for you on the page" : "Asked you to step in"
        case "list_agents": return isActive ? "Looking up the other agents" : "Looked up the other agents"
        case "send_message":
            let to = string("to") ?? "another agent"
            if input?["wait"]?.bool == true { return (isActive ? "Asking " : "Asked ") + to }
            return (isActive ? "Writing to " : "Wrote to ") + to
        case "show_in_panel": return (isActive ? "Showing " : "Showed ") + (relative(string("path")) ?? "a file")
        case "start_session": return (isActive ? "Starting a session" : "Started a session") + (string("title").map { ": \($0)" } ?? "")
        default: return "Used the browser"
        }
    }

    /// A bot's own wake-up command, read back.
    private var wake: Wakes.Command? {
        call.name == "shell" ? string("command").flatMap(Wakes.command(in:)) : nil
    }

    /// "Scheduled a wake-up in 2 hr: check whether CI passed".
    static func summary(of wake: Wakes.Command, isActive: Bool) -> String {
        switch wake.verb {
        case .list: return isActive ? "Checking its wake-ups" : "Checked its wake-ups"
        case .cancel: return isActive ? "Canceling a wake-up" : "Canceled a wake-up"
        case .watch:
            let every = wake.when.flatMap(Wakes.Repeat.init).map { " \($0.words)" } ?? ""
            return (isActive ? "Starting a watch" : "Started a watch") + every + (wake.note.map { ": \($0)" } ?? "")
        case .add:
            let when = wake.when.map(Self.when) ?? ""
            let every = wake.every.map { ", \($0.words)" } ?? ""
            return (isActive ? "Scheduling a wake-up" : "Scheduled a wake-up") + (when.isEmpty ? "" : " " + when) + every + (wake.note.map { ": \($0)" } ?? "")
        }
    }

    /// +2h as "in 2 hr", a date and time as "for Fri 9:00 AM".
    private static func when(_ text: String) -> String {
        if text.hasPrefix("+"), let unit = text.last, let count = Int(text.dropFirst().dropLast()) {
            let duration: Duration = switch unit {
            case "m": .seconds(count * 60)
            case "h": .seconds(count * 3600)
            default: .seconds(count * 86_400)
            }
            return "in " + duration.formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
        }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            parser.dateFormat = format
            if let date = parser.date(from: text) { return "for " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        }
        return "for \(text)"
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
        case "shell": wake == nil ? "terminal" : "alarm"
        case "grep", "glob": "magnifyingglass"
        case "webfetch", "websearch": "globe"
        case "question": "questionmark.bubble"
        case "subagent": "person.2"
        case "skill": "wand.and.stars"
        case "execute": "chevron.left.forwardslash.chevron.right"
        default: browserSymbol ?? "wrench.and.screwdriver"
        }
    }

    /// The browser's steps, each by what it does.
    private var browserSymbol: String? {
        guard call.name.hasPrefix("kuvo-browser_") else { return nil }
        return switch call.name.dropFirst("kuvo-browser_".count) {
        case "browser_click", "browser_hover": "cursorarrow.rays"
        case "browser_type", "browser_press": "keyboard"
        case "browser_select": "filemenu.and.selection"
        case "browser_scroll": "arrow.up.and.down"
        case "browser_back": "chevron.backward"
        case "browser_forward": "chevron.forward"
        case "browser_screenshot": "camera.viewfinder"
        case "browser_snapshot", "browser_text": "doc.text.magnifyingglass"
        case "browser_wait": "hourglass"
        case "browser_new_tab", "browser_tabs": "square.on.square"
        case "browser_upload": "paperclip"
        case "browser_sign_in": "key"
        case "browser_ask_code": "number"
        case "browser_ask_user": "hand.raised"
        case "list_agents": "person.2"
        case "send_message": "paperplane"
        case "show_in_panel": "sidebar.right"
        default: "safari"
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

    /// What a show_in_panel step showed, and whether it's a folder.
    private var shownInPanel: (url: URL, isFolder: Bool)? {
        guard call.name == "kuvo-browser_" + BrowserTools.showInPanel, case .completed = call.state, let path = string("path"),
              let isFolder = BrowserTools.shownFolder(in: outputText) else { return nil }
        return (RemoteFolder.fileURL(path, in: directory), isFolder)
    }

    /// The session a subagent works in, once it has started.
    private var subagentSession: String? {
        call.name == "subagent" ? call.state.metadata?["sessionID"]?.string : nil
    }

    /// A subagent sent off in the background, its step done at once, still at work.
    private var isAtWork: Bool {
        guard let subagentSession else { return false }
        return app.workspace.running.contains(subagentSession)
    }

    private var hasDetails: Bool {
        subagentSession != nil || !diffs.isEmpty || (call.name == "shell" && !outputText.isEmpty) || code != nil || call.state.isFailure || !pictures.isEmpty
    }

    /// Pictures the step brought back, like a screenshot of the page.
    private var pictures: [AttachmentItem] {
        guard case .completed(_, let output, _) = call.state else { return [] }
        return StepPictures.items(in: output, step: call.id)
    }

    /// The code a Code Mode step ran.
    private var code: String? {
        call.name == "execute" ? string("code") : nil
    }

    @ViewBuilder private var details: some View {
        if !pictures.isEmpty {
            StepPictures(items: pictures)
        } else if let subagentSession {
            SubagentSteps(id: subagentSession, task: string("prompt"), directory: directory)
        } else if let code {
            VStack(alignment: .leading, spacing: 8) {
                OutputBlock(text: code)
                if !outputText.isEmpty { OutputBlock(text: outputText) }
            }
        } else if !diffs.isEmpty {
            // The step names a single file already; several get a title each, and so does one
            // the patch created or deleted, since only its title says so.
            let diffs = diffs
            VStack(alignment: .leading, spacing: 10) {
                ForEach(diffs) { diff in
                    let titled = diffs.count > 1 || (diff.status != nil && diff.status != .modified)
                    DiffView(diff: diff, title: titled ? (relative(diff.file) ?? diff.file) : nil, maxLines: 80)
                }
            }
        } else {
            OutputBlock(text: outputText)
        }
    }
}

/// A command's output or a step's code, in a recessed well that scrolls sideways for long lines.
struct OutputBlock: View {
    let text: String
    @Environment(\.findHighlight) private var highlight

    var body: some View {
        ScrollView(.horizontal) {
            Text(FindText.marked(AttributedString(text.trimmingCharacters(in: .whitespacesAndNewlines)), highlight))
                .transcriptCodeFont()
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(12)
        }
        .frame(maxHeight: 260)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .recessedWell(RoundedRectangle(cornerRadius: 10))
    }
}

/// What a subagent was asked, and the steps it took and what it said, as they happen, under
/// its step or its row (which draws the line beside them).
struct SubagentSteps: View {
    let id: String
    /// What the agent asked it to do (its session's own first message adds the engine's
    /// preamble).
    let task: String?
    let directory: String
    @Environment(Workspace.self) private var workspace
    @State private var model: SessionModel?

    /// What it used, as a turn shows it: "4.2K tokens · $0.01".
    static func usage(_ model: SessionModel) -> String? {
        let steps = model.transcript.messages.compactMap { if case .assistant(let step) = $0 { step } else { nil } }
        let tokens = steps.reduce(0) { $0 + ($1.tokens?.output ?? 0) + ($1.tokens?.reasoning ?? 0) }
        guard tokens > 0 else { return nil }
        let cost = steps.reduce(0) { $0 + ($1.cost ?? 0) }
        return (["\(tokens.compactTokens) tokens"] + [cost.formattedCost].compactMap { $0 }).joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let task {
                Text(task)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            if let model {
                ForEach(model.transcript.messages) { message in
                    switch message {
                    case .assistant(let assistant):
                        ForEach(Array(assistant.content.enumerated()), id: \.offset) { _, block in
                            switch block {
                            case .text(let text):
                                MarkdownText(text: text.text, folders: { [directory] })
                            case .tool(let call):
                                ToolCallView(call: call, directory: directory)
                            default:
                                EmptyView()
                            }
                        }
                    default:
                        EmptyView()
                    }
                }
                if model.isRunning {
                    HStack(spacing: 8) {
                        Spinner(size: 11)
                        Text("Working…")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else if let usage = Self.usage(model) {
                    Text(usage)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Spinner(size: 11)
            }
        }
        .task(id: id) {
            let model = await workspace.subagentModel(for: id, in: directory)
            if let model, !model.isLoaded { await model.load() }
            self.model = model
        }
    }
}

extension Message.ToolState {
    var isFailure: Bool {
        if case .failed = self { true } else { false }
    }
}
