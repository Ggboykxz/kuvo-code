import OpenCodeKit
import SwiftUI

/// A subagent the agent handed part of the work to, in a row of its own in the conversation
/// rather than among the steps: its task and agent, what it's doing while it works (in the
/// background too, after the turn has ended) and what it used once done, opening to each step
/// it takes. Several started at once show one under another.
struct SubagentRow: View {
    let call: Message.ToolCall
    let directory: String
    @Environment(Workspace.self) private var workspace
    @State private var model: SessionModel?
    @State private var isExpanded = false

    private static let iconWidth: CGFloat = 16
    private static let iconGap: CGFloat = 8

    private var input: JSONValue? { call.state.input }
    /// Its session, once it has started.
    private var session: String? { call.state.metadata?["sessionID"]?.string }

    /// At work: its step not done yet, or done at once (sent off in the background) while its
    /// session still runs.
    private var isWorking: Bool {
        !call.state.isFinished || session.map { workspace.running.contains($0) } == true
    }

    private var title: String {
        if let task = input?["description"]?.string, !task.isEmpty { return task }
        return isWorking ? "Starting a subagent…" : "A subagent's task"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.ui) { isExpanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(TextButtonStyle(outset: true))
            .disabled(session == nil)
            .help(isExpanded ? "Hide its steps" : "Show its steps")

            if isExpanded, let session {
                SubagentSteps(id: session, task: input?["prompt"]?.string, directory: directory)
                    .padding(.leading, Self.iconWidth + Self.iconGap)
                    .padding(.top, 8)
                    .overlay(alignment: .topLeading) {
                        // The line down from the icon, beside its steps.
                        Capsule()
                            .fill(.separator)
                            .frame(width: 1)
                            .padding(.top, 3)
                            .padding(.leading, (Self.iconWidth - 1) / 2)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: session) {
            guard let session else { return }
            let model = await workspace.subagentModel(for: session, in: directory)
            if let model, !model.isLoaded { await model.load() }
            self.model = model
        }
    }

    private var header: some View {
        HStack(spacing: Self.iconGap) {
            icon
                .frame(width: Self.iconWidth)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            if let agent = input?["agent"]?.string {
                Text(agent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if session != nil {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            status
                .lineLimit(1)
                .layoutPriority(-1)
                .padding(.leading, 4)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .contentShape(.rect)
    }

    @ViewBuilder private var icon: some View {
        if isWorking {
            Spinner(size: 11)
        } else if case .failed(_, let error, _, _) = call.state, !error.isInterruption {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else {
            Image(systemName: "person.2")
        }
    }

    /// While it works, the step it's on; once done, what it used (under its steps, while it's
    /// open), or how it ended.
    @ViewBuilder private var status: some View {
        if isWorking {
            ShimmerText(text: currentStep)
                .font(.caption)
        } else if case .failed(_, let error, _, _) = call.state {
            Text(error.isInterruption ? "Stopped" : "Failed")
                .font(.caption)
                .foregroundStyle(error.isInterruption ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                .help(error.message)
        } else if !isExpanded, let model, let usage = SubagentSteps.usage(model) {
            Text(usage)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// "Ran a command", "Thinking…": its latest step, in a few words.
    private var currentStep: String {
        guard let model, case .assistant(let step)? = model.transcript.messages.last(where: { if case .assistant = $0 { true } else { false } }),
              let block = step.content.last else { return "Working…" }
        switch block {
        case .tool(let call): return StepsSummary.summary(of: [call])
        case .reasoning: return "Thinking…"
        case .text: return "Writing…"
        default: return "Working…"
        }
    }
}
