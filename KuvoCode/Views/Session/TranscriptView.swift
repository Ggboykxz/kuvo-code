import AppKit
import OpenCodeKit
import SwiftUI
import Textual

/// The conversation. Sticks to the bottom while the agent writes, unless you
/// scroll up to read.
struct TranscriptView: View {
    let model: SessionModel
    @State private var position = ScrollPosition(edge: .bottom)
    /// Whether to keep the newest text in view: true until you scroll up, true again
    /// once you scroll back to the end.
    @State private var followsEnd = true
    @State private var isScrolling = false

    var body: some View {
        ScrollView {
            let rows = rows
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    RowView(row: row, directory: model.session.location.directory, cancel: model.cancelPending, undo: model.undo(from:), redo: model.redo)
                        .padding(.top, index == 0 ? 0 : row.spacing(after: rows[index - 1]))
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 24)
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
            guard followsEnd, !isScrolling, new > old else { return }
            position.scrollTo(edge: .bottom)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .overlay {
            if model.isLoaded && rows.isEmpty {
                EmptyConversationView(directory: model.session.location.directory)
            }
        }
    }

    /// Messages, turned into what's drawn: notices are condensed, each finished
    /// turn gets a summary line, and queued messages come last.
    private var rows: [Row] {
        var rows: [Row] = []
        var turn = TurnStats()
        // An undo waiting to be kept ends the conversation at its message.
        let boundary = model.session.revert?.messageID
        let all = model.transcript.messages
        let messages = boundary.map { boundary in all.filter { $0.id < boundary } } ?? all
        for (index, message) in messages.enumerated() {
            switch message {
            case .user(let user):
                turn = TurnStats(started: user.time.created)
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
                rows.append(.turnEnd(idle, turn))
                turn = TurnStats()
            case .modelSwitched(let change):
                rows.append(.notice(change.id, "cpu", "Switched to \(change.model.id)"))
            case .agentSwitched(let change):
                rows.append(.notice(change.id, change.agent == "plan" ? "list.bullet.clipboard" : "hammer", "\(change.agent.capitalized) mode"))
            case .compaction(let compaction):
                rows.append(.notice(compaction.id, "rectangle.compress.vertical", compaction.status == "running" ? "Summarizing the conversation…" : "Summarized the conversation to save space"))
            case .shell(let shell):
                rows.append(.notice(shell.id, "terminal", "$ \(shell.command)" + (shell.exit.map { " (exit \($0))" } ?? "")))
            case .synthetic(let notice), .system(let notice):
                let sources = notice.instructionSources
                if !sources.isEmpty, sources.allSatisfy({ $0.contains(ProjectFolders.instructionKey) }) {
                    rows.append(.notice(notice.id, "folder", "Project folders updated"))
                } else if !sources.isEmpty, sources.allSatisfy({ $0.hasPrefix("core/") }) {
                    // The engine's own guidance (for the browser tools, say): nothing you set.
                    break
                } else {
                    rows.append(.notice(notice.id, "info.circle", notice.description ?? notice.text))
                }
            case .other:
                break
            }
        }
        if let boundary {
            let undone = all.count { if case .user(let user) = $0 { user.id >= boundary } else { false } }
            rows.append(.undone(max(undone, 1)))
        }
        // Messages waiting their turn are listed above the composer instead.
        let waiting = Set(model.waiting.map(\.id))
        rows += model.transcript.pending.filter { !waiting.contains($0.id) }.map(Row.pending)
        if model.transcript.isRunning && !isVisiblyWorking(messages.last) {
            rows.append(.working)
        }
        return rows
    }

    /// Whether the last message already shows activity (streaming text, open reasoning, a running tool).
    private func isVisiblyWorking(_ message: Message?) -> Bool {
        guard case .assistant(let assistant) = message, assistant.time.completed == nil, let last = assistant.content.last else { return false }
        switch last {
        case .reasoning(let block): return !block.isComplete
        case .tool(let call): return !call.state.isFinished
        case .text: return true
        case .other: return false
        }
    }
}

struct TurnStats: Hashable {
    var started: Milliseconds?
    var cost: Double = 0
    var outputTokens = 0
    var steps = 0
    /// What the agent wrote, for copying the reply.
    var text: [String] = []

    mutating func add(_ message: Message.Assistant) {
        cost += message.cost ?? 0
        outputTokens += (message.tokens?.output ?? 0) + (message.tokens?.reasoning ?? 0)
        steps += 1
        for block in message.content {
            if case .text(let part) = block, !part.text.isEmpty { text.append(part.text) }
        }
    }
}

enum Row: Identifiable, Hashable {
    case user(Message.User)
    case assistant(Message.Assistant, showsError: Bool)
    case turnEnd(Message.Idle, TurnStats)
    case notice(String, String, String)
    case pending(Transcript.Pending)
    /// An undo that the next message makes final, with how many messages it took back.
    case undone(Int)
    case working

    /// Space above this row: steps of one reply sit close, a new message gets room.
    func spacing(after previous: Row) -> CGFloat {
        switch (previous, self) {
        case (.assistant, .assistant), (.assistant, .turnEnd), (.assistant, .working): 10
        case (_, .user), (_, .pending): 28
        default: 16
        }
    }

    var id: String {
        switch self {
        case .user(let m): m.id
        case .assistant(let m, _): m.id
        case .turnEnd(let m, _): m.id
        case .notice(let id, _, _): id
        case .pending(let item): item.id
        case .undone: "undone"
        case .working: "working"
        }
    }
}

private struct RowView: View {
    let row: Row
    let directory: String
    let cancel: (Transcript.Pending) -> Void
    let undo: (Message.User) -> Void
    let redo: () -> Void
    @State private var confirmsUndo = false

    var body: some View {
        switch row {
        case .user(let message):
            let (withComments, paths) = Attachments.split(message.text)
            let (text, comments) = ReviewComments.split(withComments)
            let stored = (message.files ?? []).enumerated().map { AttachmentItem.stored($1, id: "\(message.id)#\($0)") }
            UserBubble(text: text, attachments: stored + paths.map(AttachmentItem.path), comments: comments)
                .contextMenu {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .disabled(text.isEmpty)
                    Divider()
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
            AssistantStepView(message: message, directory: directory, showsError: showsError)
        case .turnEnd(let idle, let stats):
            TurnEndView(idle: idle, stats: stats)
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
        case .working:
            ShimmerText(text: "Working…")
                .font(.callout)
        }
    }
}

struct UserBubble: View {
    let text: String
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
                Text(text)
                    .font(.transcript)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.fill.tertiary, in: .rect(cornerRadius: Metrics.bubbleRadius))
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

/// One model step: its reasoning, text and tool calls, in order.
private struct AssistantStepView: View {
    let message: Message.Assistant
    let directory: String
    let showsError: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(message.content.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    MarkdownText(text: text.text)
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

    var body: some View {
        StructuredText(markdown: text)
            .font(.transcript)
            .textual.structuredTextStyle(.gitHub)
            .textual.textSelection(.enabled)
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
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .frame(width: 16)
                    if block.isComplete {
                        Text(duration.map { "Thought for \($0)" } ?? "Thought")
                    } else {
                        ShimmerText(text: "Thinking…")
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(block.text.isEmpty)

            if isExpanded {
                Text(block.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 22)
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

    var body: some View {
        switch idle.outcome {
        case .failed:
            ErrorCard(message: idle.error?.message ?? "The run failed.")
        case .interrupted:
            Label("Stopped", systemImage: "stop.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .succeeded:
            HStack(spacing: 6) {
                if !parts.isEmpty {
                    Text(parts.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if !stats.text.isEmpty {
                    CopyButton(text: stats.text.joined(separator: "\n\n"), help: "Copy the Reply")
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

/// A quiet copy icon that turns into a checkmark for a moment once it's copied.
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
                .frame(width: 22, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
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

/// A session with nothing in it yet.
struct EmptyConversationView: View {
    let directory: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("What should we work on in \((directory as NSString).lastPathComponent)?")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 120)
    }
}
