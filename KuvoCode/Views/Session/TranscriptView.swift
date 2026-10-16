import AppKit
import OpenCodeKit
import SwiftUI
import Textual

/// The conversation. Sticks to the bottom while the agent writes, unless you
/// scroll up to read.
struct TranscriptView: View {
    let model: SessionModel
    @Environment(Workspace.self) private var workspace
    @State private var position = ScrollPosition(edge: .bottom)
    /// Whether to keep the newest text in view: true until you scroll up, true again
    /// once you scroll back to the end.
    @State private var followsEnd = true
    @State private var isScrolling = false
    /// Find in the conversation (⌘F): what's looked for, and which match is in view.
    @State private var isFinding = false
    @State private var query = ""
    @State private var matchIndex = 0

    var body: some View {
        let rows = rows
        let matches = isFinding ? Self.matches(of: query, in: rows) : []
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    RowView(row: row, directory: model.session.location.directory, folders: model.folders, cancel: model.cancelPending, undo: model.undo(from:), redo: model.redo, fork: fork, retry: model.retry(_:), buildPlan: model.agent == "plan" ? { model.buildPlan() } as () -> Void : nil)
                        .background {
                            if matches.contains(row.id) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.yellow.opacity(matches.indices.contains(matchIndex) && matches[matchIndex] == row.id ? 0.3 : 0.12))
                                    .padding(-6)
                            }
                        }
                        .id(row.id)
                        .padding(.top, index == 0 ? 0 : row.spacing(after: rows[index - 1]))
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
            .padding(.horizontal, Metrics.gutter)
            // Room under the card's header, which the conversation scrolls beneath.
            .padding(.top, 16)
            // Room under the last reply, so it doesn't sit on the composer.
            .padding(.bottom, 32)
            .readableColumn()
            .animation(.ui, value: rows.map(\.id))
        }
        .scrollPosition($position)
        // Only where it starts. An anchor for size changes fought the rubber band: the lazy
        // stack re-measures rows during a bounce, so the end kept moving and the bounce
        // crawled, then snapped back. Following the end is done below, only while idle.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollPhaseChange { _, phase in isScrolling = phase != .idle }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - 40
        } action: { _, atEnd in
            // Your scrolling decides; growth below the fold doesn't.
            if isScrolling { followsEnd = atEnd }
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { old, new in
            // Shrinking too: the lazy stack's first guess at the height can be too big, and a
            // session would then open part of the way up.
            guard followsEnd, !isScrolling, new != old else { return }
            position.scrollTo(edge: .bottom)
        }
        // Messages scroll on under the card's header and the composer, blurring away there
        // instead of being cut at an edge.
        .scrollEdgeEffectStyle(.soft, for: .all)
        .overlay {
            if model.isLoaded && rows.isEmpty {
                EmptyConversationView(directory: model.session.location.directory) { text in
                    model.submit(text, files: [], for: nil, queue: false, commands: [])
                }
            }
        }
        .overlay(alignment: .bottom) {
            // Scrolled up: a way back to the newest, which also follows it again.
            if !followsEnd, !rows.isEmpty {
                Button {
                    followsEnd = true
                    withAnimation(.ui) { position.scrollTo(edge: .bottom) }
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Scroll to the End")
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.ui, value: followsEnd)
        .overlay(alignment: .top) {
            if isFinding {
                FindBar(query: $query, current: matchIndex, count: matches.count) { step in
                    guard !matches.isEmpty else { return }
                    matchIndex = (matchIndex + step + matches.count) % matches.count
                    reveal(matches[matchIndex])
                } close: {
                    withAnimation(.ui) { isFinding = false }
                }
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: query) {
            matchIndex = 0
            if let first = Self.matches(of: query, in: self.rows).first { reveal(first) }
        }
        .onChange(of: model.findRequest, initial: true) {
            guard model.findRequest > 0 else { return }
            if let preset = model.findPreset {
                query = preset
                model.findPreset = nil
            }
            withAnimation(.ui) { isFinding = true }
        }
    }

    /// Rows whose words have `query`, in order.
    private static func matches(of query: String, in rows: [Row]) -> [String] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return rows.filter { $0.searchText.localizedStandardContains(query) }.map(\.id)
    }

    private func reveal(_ id: String) {
        followsEnd = false
        withAnimation(.ui) { position.scrollTo(id: id, anchor: .center) }
    }

    /// Messages, turned into what's drawn: notices are condensed, each finished
    /// turn gets a summary line, and queued messages come last.
    private var rows: [Row] {
        var rows: [Row] = []
        var turn = TurnStats()
        // An undo waiting to be kept ends the conversation at its message: by where it is, as a
        // message queued during a run is older than that run's later steps.
        let boundary = model.session.revert?.messageID
        let all = model.transcript.messages
        let cut = boundary.map { boundary in all.firstIndex { $0.id == boundary } ?? all.firstIndex { $0.id >= boundary } ?? all.count }
        let messages = cut.map { Array(all[..<$0]) } ?? all
        for (index, message) in messages.enumerated() {
            switch message {
            case .user(let user):
                turn = TurnStats(started: user.time.created, message: user)
                rows.append(.user(user))
            case .assistant(let assistant):
                turn.add(assistant)
                // The run's error shows once, at the end of the turn. A step you stopped isn't an
                // error: the turn's end says "Stopped".
                let nextIdle = messages[(index + 1)...].lazy.compactMap { if case .idle(let idle) = $0 { idle } else { nil } }.first
                let showsError = assistant.error.map { !$0.isInterruption } == true && assistant.error?.message != nextIdle?.error?.message
                if !assistant.content.isEmpty || showsError || assistant.retry != nil {
                    rows.append(.assistant(assistant, showsError: showsError))
                }
            case .idle(let idle):
                rows.append(.turnEnd(idle, turn, isLast: index == messages.count - 1))
                turn = TurnStats()
            case .modelSwitched(let change):
                rows.append(.notice(change.id, "cpu", "Switched to \(change.model.id)" + (change.model.variant.map { " · \(EffortLevel.title($0))" } ?? "")))
            case .agentSwitched(let change):
                rows.append(.notice(change.id, change.agent == "plan" ? "list.bullet.clipboard" : "hammer", "\(change.agent.capitalized) mode"))
            case .compaction(let compaction):
                rows.append(.notice(compaction.id, "rectangle.compress.vertical", compaction.status == "running" ? "Summarizing the conversation…" : "Summarized the conversation to save space"))
            case .shell(let shell):
                rows.append(.shell(shell))
            case .synthetic(let notice), .system(let notice):
                let sources = notice.instructionSources
                if !sources.isEmpty, sources.allSatisfy({ $0.contains(ProjectFolders.instructionKey) }) {
                    rows.append(.notice(notice.id, "folder", "Project folders updated"))
                } else if !sources.isEmpty, sources.allSatisfy({ $0.hasPrefix("core/") }) {
                    // The engine's own guidance (for the browser tools, say): nothing you set.
                    break
                } else if notice.text.hasPrefix("Your last response hit the output token limit") {
                    // The engine asking the model to go on after a reply ran out of room.
                    rows.append(.notice(notice.id, "arrow.turn.down.right", "Hit the length limit for one reply, so it carried on"))
                } else {
                    rows.append(.notice(notice.id, "info.circle", notice.description ?? notice.text))
                }
            case .other:
                break
            }
        }
        if let cut {
            let undone = all[cut...].count { if case .user = $0 { true } else { false } }
            rows.append(.undone(max(undone, 1)))
        }
        // Messages waiting their turn are listed above the composer instead.
        let waiting = Set(model.waiting.map(\.id))
        rows += model.transcript.pending.filter { !waiting.contains($0.id) }.map(Row.pending)
        // Always while it works, with the time since your message, so a long step is plainly
        // still going.
        if model.transcript.isRunning {
            rows.append(.working(since: turn.started))
        }
        return rows
    }

    private func fork(_ message: Message.User) {
        Task {
            do { try await workspace.fork(model.id, from: message) } catch { model.failure = error.localizedDescription }
        }
    }

}

struct TurnStats: Hashable {
    var started: Milliseconds?
    /// The message that started the turn, for Try Again.
    var message: Message.User?
    var cost: Double = 0
    var outputTokens = 0
    var steps = 0
    /// What the agent wrote, for copying the reply.
    var text: [String] = []
    /// The mode that answered: a plan can be built from its end.
    var agent: String?
    /// The files the agent changed, in the order first changed, with their lines.
    var files: [TurnFile] = []

    /// A file a turn changed. A file written whole has no line counts.
    struct TurnFile: Hashable, Identifiable {
        var file: String
        var lines: (additions: Int, deletions: Int)?

        var id: String { file }

        static func == (a: TurnFile, b: TurnFile) -> Bool {
            a.file == b.file && a.lines?.additions == b.lines?.additions && a.lines?.deletions == b.lines?.deletions
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(file)
            hasher.combine(lines?.additions)
            hasher.combine(lines?.deletions)
        }
    }

    mutating func add(_ message: Message.Assistant) {
        agent = message.agent
        for block in message.content {
            guard case .tool(let call) = block, case .completed(let input, _, let metadata) = call.state else { continue }
            // Read straight from the JSON: this runs on every update while a reply streams, and
            // the diffs carry whole patches.
            for diff in metadata?["files"]?.array ?? [] {
                guard let file = diff["file"]?.string else { continue }
                note(file, lines: (Int(diff["additions"]?.number ?? 0), Int(diff["deletions"]?.number ?? 0)))
            }
            if call.name == "write", let path = input["path"]?.string {
                note(path, lines: nil)
            }
        }
        cost += message.cost ?? 0
        outputTokens += (message.tokens?.output ?? 0) + (message.tokens?.reasoning ?? 0)
        steps += 1
        for block in message.content {
            if case .text(let part) = block, !part.text.isEmpty { text.append(part.text) }
        }
    }

    private mutating func note(_ file: String, lines: (additions: Int, deletions: Int)?) {
        guard let index = files.firstIndex(where: { $0.file == file }) else {
            files.append(TurnFile(file: file, lines: lines))
            return
        }
        // Once written whole, its lines aren't known.
        if let old = files[index].lines, let lines {
            files[index].lines = (old.additions + lines.additions, old.deletions + lines.deletions)
        } else {
            files[index].lines = nil
        }
    }
}

enum Row: Identifiable, Hashable {
    case user(Message.User)
    case assistant(Message.Assistant, showsError: Bool)
    /// `isLast`: the conversation ends here, so a failed run can be tried again.
    case turnEnd(Message.Idle, TurnStats, isLast: Bool)
    case notice(String, String, String)
    /// A command you ran with "!".
    case shell(Message.Shell)
    case pending(Transcript.Pending)
    /// An undo that the next message makes final, with how many messages it took back.
    case undone(Int)
    /// The agent at work, since the time of your message.
    case working(since: Milliseconds?)

    /// The words Find looks in: messages and replies.
    var searchText: String {
        switch self {
        case .user(let message): CommandMessages.shared.text(of: message)
        case .assistant(let message, _): message.content.compactMap { if case .text(let part) = $0 { part.text } else { nil } }.joined(separator: " ")
        case .pending(let item): item.text
        case .shell(let shell): shell.command + " " + (shell.output?.output ?? "")
        default: ""
        }
    }

    /// Space above this row: steps of one reply sit close, a new message gets room.
    func spacing(after previous: Row) -> CGFloat {
        switch (previous, self) {
        case (.assistant, .assistant), (.assistant, .turnEnd), (.assistant, .working(_)): 10
        case (_, .user), (_, .pending): 28
        case (.shell, .shell): 12
        case (_, .shell): 20
        // A message's buttons already take room under it.
        case (.user, _): 4
        default: 16
        }
    }

    var id: String {
        switch self {
        case .user(let m): m.id
        case .assistant(let m, _): m.id
        case .turnEnd(let m, _, _): m.id
        case .notice(let id, _, _): id
        case .shell(let m): m.id
        case .pending(let item): item.id
        case .undone: "undone"
        case .working: "working"
        }
    }
}

private struct RowView: View {
    let row: Row
    @Environment(\.bot) private var bot
    let directory: String
    let folders: () -> [String]
    let cancel: (Transcript.Pending) -> Void
    let undo: (Message.User) -> Void
    let redo: () -> Void
    let fork: (Message.User) -> Void
    let retry: (Message.User) -> Void
    /// While the session is in Plan mode: build what the last answer planned.
    let buildPlan: (() -> Void)?
    @State private var confirmsUndo = false
    /// Under the pointer: a message shows its buttons.
    @State private var isHovering = false

    static func sentAt(_ created: Milliseconds) -> String {
        MessageTime.sentAt(Date(timeIntervalSince1970: created / 1000))
    }

    /// " 12s", " 1m 5s" after a few seconds, then " · Esc to stop".
    static func elapsed(since: Milliseconds?, now: Date) -> String {
        guard let since else { return "" }
        let seconds = Int(now.timeIntervalSince1970 - since / 1000)
        guard seconds >= 2 else { return "" }
        let time = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        return " \(time) · Esc to stop"
    }

    var body: some View {
        switch row {
        case .user(let message) where CommandMessages.shared.text(of: message).hasPrefix(Wakes.marker):
            WakeRow(note: String(CommandMessages.shared.text(of: message).dropFirst(Wakes.marker.count)), at: message.time.created)
        case .user(let message):
            let (withComments, paths) = Attachments.split(CommandMessages.shared.text(of: message))
            let (text, comments) = ReviewComments.split(withComments)
            let stored = (message.files ?? []).enumerated().map { AttachmentItem.stored($1, id: "\(message.id)#\($0)") }
            VStack(alignment: .trailing, spacing: 2) {
                UserBubble(text: text, attachments: stored + paths.map(AttachmentItem.path), comments: comments)
                // Always laid out, shown under the pointer: nothing moves when they appear.
                HStack(spacing: 0) {
                    Text(Self.sentAt(message.time.created))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 6)
                    if !text.isEmpty {
                        CopyButton(text: text, help: "Copy")
                    }
                    MessageActionButton(symbol: "arrow.triangle.branch", help: "New Session From Here") { fork(message) }
                    MessageActionButton(symbol: "arrow.uturn.backward", help: "Undo From Here…") { confirmsUndo = true }
                }
                .opacity(isHovering ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: isHovering)
            }
            .contentShape(.rect)
            .onHover { isHovering = $0 }
                .contextMenu {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .disabled(text.isEmpty)
                    Divider()
                    Button("New Session From Here") { fork(message) }
                    Button("Undo From Here…") { confirmsUndo = true }
                }
                .alert("Undo from this message?", isPresented: $confirmsUndo) {
                    Button("Undo") { undo(message) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The conversation goes back to before this message, and so do the files the agent changed since. The message comes back to the composer. You can redo it all until you send something.")
                }
        case .pending(let item):
            let (withComments, paths) = Attachments.split(item.text)
            let (text, comments) = ReviewComments.split(withComments)
            UserBubble(text: text, attachments: item.files.map(AttachmentItem.local) + paths.map(AttachmentItem.path), comments: comments,
                       status: item.isLocal ? "Sending" : item.delivery == .queue ? "Queued" : "Sending")
                .contextMenu { Button("Cancel", role: .destructive) { cancel(item) } }
        case .assistant(let message, let showsError):
            AssistantStepView(message: message, directory: directory, folders: folders, showsError: showsError)
        case .turnEnd(let idle, let stats, let isLast):
            TurnEndView(idle: idle, stats: stats, directory: directory, retry: isLast ? stats.message.map { message in { retry(message) } } : nil,
                        build: isLast && stats.agent == "plan" ? buildPlan : nil)
        case .shell(let shell):
            ShellRow(shell: shell)
        case .notice(_, let symbol, let text):
            Label(text, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: .capsule)
                .frame(maxWidth: .infinity)
        case .undone(let count):
            HStack(spacing: 10) {
                Label(count == 1 ? "Undid 1 message" : "Undid \(count) messages", systemImage: "arrow.uturn.backward")
                Button("Redo", action: redo)
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: .capsule)
            .frame(maxWidth: .infinity)
            .help("Sending a message makes the undo final")
        case .working(let since):
            HStack(spacing: 8) {
                // A bot shows itself at work.
                if let bot {
                    BotAvatar(look: bot.look, size: 18, mood: .working)
                        .frame(width: 16)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ShimmerText(text: "Working…" + Self.elapsed(since: since, now: context.date))
                        .font(.callout)
                }
            }
        }
    }
}

struct UserBubble: View {
    let text: String
    /// The words with styling of their own (a group chat's mentions), in place of plain `text`.
    var styled: AttributedString?
    var attachments: [AttachmentItem] = []
    var comments: [ReviewComment] = []
    var status: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if !attachments.isEmpty {
                MessageAttachments(items: attachments)
                    .padding(.bottom, text.isEmpty ? 0 : 2)
            }
            ForEach(comments) { comment in
                CommentReference(comment: comment)
            }
            if !text.isEmpty {
                MessageText(text: text, styled: styled)
            }
            if let status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(status == nil ? 1 : 0.7)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 80)
    }
}

/// A message's words in its bubble. A long one (a pasted log, say) shows its first lines,
/// fading out, until you ask for the rest.
private struct MessageText: View {
    let text: String
    var styled: AttributedString?
    @State private var isExpanded = false
    @State private var shownHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0
    private static let lines = 12

    /// Short messages can't reach the limit, so they aren't measured twice.
    private var mayBeLong: Bool {
        text.count > 300 || text.utf8.count { $0 == 10 } >= Self.lines
    }

    private var isCut: Bool { isExpanded || fullHeight > shownHeight + 1 }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(styled ?? AttributedString(text))
                .transcriptFont()
                .lineLimit(isExpanded ? nil : Self.lines)
                .textSelection(.enabled)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
                .background(alignment: .top) {
                    // The whole text, unseen, to tell whether the limit cuts anything.
                    if mayBeLong, !isExpanded {
                        Text(styled ?? AttributedString(text))
                            .transcriptFont()
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                    }
                }
                .mask {
                    if isCut && !isExpanded {
                        LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .black.opacity(0.15), location: 1)], startPoint: .top, endPoint: .bottom)
                    } else {
                        Color.black
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                // Your words in accent glass, apart from the agent's on the card.
                .accentGlass(RoundedRectangle(cornerRadius: Metrics.bubbleRadius))
            if mayBeLong, isCut {
                Button(isExpanded ? "Show Less" : "Show More") {
                    withAnimation(.ui) { isExpanded.toggle() }
                }
                .buttonStyle(TextButtonStyle(outset: true))
                .font(.system(size: 12, weight: .medium))
                .padding(.trailing, 6)
            }
        }
    }
}

/// One model step: its reasoning, text and tool calls, in order.
private struct AssistantStepView: View {
    let message: Message.Assistant
    let directory: String
    let folders: () -> [String]
    let showsError: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(message.content.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    MarkdownText(text: text.text, folders: folders)
                case .reasoning(let reasoning):
                    ReasoningView(block: reasoning)
                case .tool(let call):
                    ToolCallView(call: call, directory: directory)
                case .other:
                    EmptyView()
                }
            }
            if let retry = message.retry {
                Label("Retrying (attempt \(retry.attempt)): \(retry.error.message)", systemImage: "arrow.clockwise")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if showsError, let error = message.error {
                ErrorCard(message: error.message)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownText: View {
    let text: String
    /// The project's folders: file names written as code in them become links.
    var folders: () -> [String] = { [] }
    /// In a group chat, its bots, for their mentions.
    var mentions: [Bot] = []
    @Environment(AppModel.self) private var app

    var body: some View {
        StructuredText(text, parser: FileLinkingParser(folders: folders, mentions: mentions))
            .transcriptFont()
            // Closer to the text than the GitHub style, so it wins for code blocks.
            .textual.codeBlockStyle(CopyableCodeBlockStyle())
            .textual.highlighterTheme(CodeColors.theme)
            .textual.structuredTextStyle(.gitHub)
            .textual.textSelection(.enabled)
            // A file opens in the side panel; web links in the browser.
            .environment(\.openURL, OpenURLAction { url in
                guard url.isFileURL else { return .systemAction }
                app.utilities.show(url)
                return .handled
            })
    }
}

/// The model's thinking: one quiet line, open it to read.
private struct ReasoningView: View {
    let block: Message.Content.Text
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.ui) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "brain")
                        .frame(width: 16)
                    if block.isComplete {
                        Text(duration.map { "Thought for \($0)" } ?? "Thought")
                    } else {
                        ShimmerText(text: "Thinking…")
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(.callout)
            }
            .buttonStyle(TextButtonStyle(outset: true))
            .disabled(block.text.isEmpty)

            if isExpanded {
                Text(block.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 24)
                    .overlay(alignment: .topLeading) {
                        // The line down from the icon, beside the thinking, as steps have.
                        Capsule()
                            .fill(.separator)
                            .frame(width: 1)
                            .padding(.leading, 7.5)
                    }
                    .transition(.opacity)
            }
        }
    }

    private var duration: String? {
        guard let start = block.time?.created, let end = block.time?.completed else { return nil }
        let seconds = max(1, Int((end - start) / 1000))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// The end of a turn: how long it took and what it cost, or what went wrong.
private struct TurnEndView: View {
    let idle: Message.Idle
    let stats: TurnStats
    /// The session's folder, where the files the turn changed are.
    let directory: String
    /// Sends the turn's message again; offered on the last turn when it failed.
    var retry: (() -> Void)?
    /// Builds what a plan described; offered under Plan mode's last answer.
    var build: (() -> Void)?

    var body: some View {
        switch idle.outcome {
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                ErrorCard(message: idle.error?.message ?? "The run failed.")
                HStack(spacing: 8) {
                    if let retry {
                        Button("Try Again", systemImage: "arrow.clockwise", action: retry)
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .help("Send your last message again")
                    }
                    // What it changed before failing.
                    if !stats.files.isEmpty {
                        TurnFiles(files: stats.files, directory: directory)
                    }
                }
            }
        case .interrupted:
            HStack(spacing: 6) {
                Label("Stopped", systemImage: "stop.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !stats.files.isEmpty {
                    TurnFiles(files: stats.files, directory: directory)
                }
            }
        case .succeeded:
            HStack(spacing: 6) {
                if !parts.isEmpty {
                    Text(parts.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if !stats.files.isEmpty {
                    TurnFiles(files: stats.files, directory: directory)
                }
                if !stats.text.isEmpty {
                    CopyButton(text: stats.text.joined(separator: "\n\n"), help: "Copy the Reply")
                }
                if let build {
                    Button("Build It", systemImage: "hammer", action: build)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .help("Switch to Build mode and have the agent carry out this plan")
                        .padding(.leading, 4)
                }
            }
        }
    }

    private var parts: [String] {
        var parts: [String] = []
        if let started = stats.started {
            let seconds = Int((idle.time.created - started) / 1000)
            if seconds >= 1 { parts.append(seconds < 60 ? "Worked for \(seconds)s" : "Worked for \(seconds / 60)m \(seconds % 60)s") }
        }
        if stats.outputTokens > 0 { parts.append("\(stats.outputTokens.compactTokens) tokens") }
        if let cost = stats.cost.formattedCost { parts.append(cost) }
        return parts
    }
}

/// Find in the conversation: the words, which match is in view, and a way through them.
/// Return goes to the next match, Shift-Return to the previous, Escape closes.
private struct FindBar: View {
    @Binding var query: String
    let current: Int
    let count: Int
    let step: (Int) -> Void
    let close: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in Conversation", text: $query)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .frame(width: 220)
                .onKeyPress(.return, phases: .down) { press in
                    step(press.modifiers.contains(.shift) ? -1 : 1)
                    return .handled
                }
                .onExitCommand(perform: close)
            if !query.isEmpty {
                Text(count == 0 ? "No matches" : "\(current + 1) of \(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Button("Previous", systemImage: "chevron.up") { step(-1) }
                .buttonStyle(CardActionStyle())
                .disabled(count == 0)
                .help("Previous Match (⇧Return)")
            Button("Next", systemImage: "chevron.down") { step(1) }
                .buttonStyle(CardActionStyle())
                .disabled(count == 0)
                .help("Next Match (Return)")
            Button("Done", action: close)
                .buttonStyle(.borderless)
                .font(.callout.weight(.medium))
        }
        .font(.callout)
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .onAppear { isFocused = true }
    }
}

/// "Edited 3 files" under a turn: the files it changed, each a click from the panel.
private struct TurnFiles: View {
    let files: [TurnStats.TurnFile]
    let directory: String
    @Environment(AppModel.self) private var app
    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            Label(files.count == 1 ? "Edited 1 file" : "Edited \(files.count) files", systemImage: "plus.forwardslash.minus")
                .font(.caption)
        }
        .buttonStyle(TextButtonStyle(outset: true))
        .help("What this turn changed")
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(files) { file in
                    Button {
                        isShowing = false
                        app.utilities.show(url(of: file))
                    } label: {
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(of: url(of: file)))
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(relative(file.file))
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 12)
                            if let lines = file.lines {
                                DiffStat(additions: lines.additions, deletions: lines.deletions)
                            } else {
                                Text("Written")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .contentShape(.rect)
                        .hoverHighlight(in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Open in the Panel")
                }
                Divider().padding(.vertical, 4)
                Button("Show All Changes") {
                    isShowing = false
                    app.utilities.revealChanges()
                }
                .buttonStyle(.link)
                .font(.callout)
                .padding(.horizontal, 8)
            }
            .font(.callout)
            .padding(8)
            .frame(width: 320)
        }
    }

    private func url(of file: TurnStats.TurnFile) -> URL {
        RemoteFolder.fileURL(file.file, in: directory)
    }

    private func relative(_ path: String) -> String {
        // A machine's engine names files as they are there, without the ssh:// prefix.
        let directory = RemoteFolder.parse(directory)?.path ?? directory
        return path.hasPrefix(directory + "/") ? String(path.dropFirst(directory.count + 1)) : path
    }
}

/// One of the small buttons under a message, like the copy icon beside it.
/// When a message was sent: the time today, the day and time before that.
enum MessageTime {
    static func sentAt(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday " + date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

struct MessageActionButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
        }
        .buttonStyle(IconButtonStyle())
        .help(help)
    }
}

/// A copy icon that turns into a checkmark for a moment once it's copied.
struct CopyButton: View {
    let text: String
    var help = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.ui) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.ui) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(IconButtonStyle())
        .help(copied ? "Copied" : help)
    }
}

struct ErrorCard: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.red.opacity(0.2)))
    }
}

/// A bot woke itself up, as it planned: its note to itself, in place of a message from you.
private struct WakeRow: View {
    let note: String
    let at: Milliseconds

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "alarm")
                .foregroundStyle(.tint)
                .frame(width: 16)
            (Text("Woke up").fontWeight(.semibold).foregroundStyle(.primary) + Text("  ") + Text(note).foregroundStyle(.secondary))
                // Room for what a watch saw, after its note.
                .lineLimit(6)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Text(Date(timeIntervalSince1970: at / 1000), format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .recessedWell(RoundedRectangle(cornerRadius: 10))
        // The well reaches past the column, so its icon and text line up with the steps'.
        .padding(.horizontal, -10)
        .help("A wake-up the bot scheduled for itself")
    }
}

/// A session with nothing in it yet.
struct EmptyConversationView: View {
    let directory: String
    /// Sends a message, for a bot's first start.
    var send: (String) -> Void = { _ in }
    @Environment(\.bot) private var bot
    @State private var isHoveringBot = false

    var body: some View {
        if let bot {
            // A bot, before its first task: who it is and what it's for.
            VStack(spacing: 12) {
                // Still: the bot moves in its sidebar row; pointed at, it notices.
                BotAvatar(look: bot.look, size: 64, mood: .idle, noticed: isHoveringBot, animates: false)
                    .onHover { isHoveringBot = $0 }
                VStack(spacing: 4) {
                    Text(bot.name)
                        .font(.title2.weight(.semibold))
                    if !bot.job.isEmpty {
                        Text(bot.job)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(bot.instructions.isEmpty
                    ? "Give \(bot.name) its first task. It keeps this conversation, remembers what it learns, and can wake itself up later to carry on."
                    : "Start \(bot.name) on its job, or give it a task of your own. It keeps this conversation, remembers what it learns, and can wake itself up later to carry on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                if !bot.instructions.isEmpty {
                    Button("Start Its Job") { send(Self.kickoff) }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .padding(.top, 4)
                        .help("\(bot.name) reads its job, asks you for anything it needs, and starts")
                }
            }
            .padding(.bottom, 120)
        } else {
            plain
        }
    }

    /// A bot's first message: start on the job it was given.
    static let kickoff = "Start on your job now: read your instructions and your memory, ask me for anything you need to get going (like what to watch or which topics), do the first round, and if your job repeats or keeps an eye on something, set that up (a repeating wake-up, or a watch)."

    private var plain: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(Workspace.isChat(directory) ? "What's on your mind?" : "What should we work on in \((directory as NSString).lastPathComponent)?")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 120)
    }
}
