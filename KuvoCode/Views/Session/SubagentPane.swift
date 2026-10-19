import OpenCodeKit
import SwiftUI

// Subagents, where you can keep up with them: a bar over the conversation's composer while
// they work, and a tab of the side panel for each one you open, with what it does as it does
// it and a composer of its own to talk to it, stop it, or give it another model.

/// The task a subagent's session starts with: the agent's words, after the engine's line
/// saying it's a subagent.
enum SubagentTask {
    static let preamble = "You are a subagent spawned by another session."

    /// The task in a subagent's first message; nil for any other message.
    static func parse(_ text: String) -> String? {
        guard text.hasPrefix(preamble) else { return nil }
        return text.dropFirst(preamble.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension SessionModel {
    /// Its latest step, in a few words: "Ran a command", "Thinking…".
    var currentStep: String {
        guard case .assistant(let step)? = transcript.messages.last(where: { if case .assistant = $0 { true } else { false } }),
              let block = step.content.last else { return "Working…" }
        switch block {
        case .tool(let call): return StepsSummary.summary(of: [call])
        case .reasoning: return "Thinking…"
        case .text: return "Writing…"
        default: return "Working…"
        }
    }

    /// How its last step ended, if it failed (or was stopped).
    var lastStepError: StructuredError? {
        guard case .assistant(let step)? = transcript.messages.last(where: { if case .assistant = $0 { true } else { false } }) else { return nil }
        return step.error
    }

    /// It's waiting for an answer to something it asked (a permission, a question), which shows
    /// in the conversation it works for.
    var waitsForYou: Bool { !permissions.isEmpty || !forms.isEmpty }
}

extension Workspace {
    /// At work: its step not done yet, or done at once (sent off in the background) while its
    /// session still runs.
    func isWorking(_ subagent: SessionModel.Subagent) -> Bool {
        !subagent.isStepDone || running.contains(subagent.id)
    }
}

// MARK: - The bar over the composer

/// The conversation's subagents at work, in a bar over the composer like the one for commands
/// left running: one line that says so, and under it each one, what it's doing, Open (to watch
/// and talk to it beside the conversation) and Stop. Hidden, the line stays.
struct SubagentsBar: View {
    let subagents: [SessionModel.Subagent]
    /// The conversation's folder, where they work.
    let folder: String
    /// The conversation they work for.
    let session: String
    @Binding var isHidden: Bool

    private static let rowHeight: CGFloat = 30
    private static let visibleRows = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isHidden {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(subagents) { subagent in
                            SubagentsBarRow(subagent: subagent, folder: folder, session: session)
                                .frame(height: Self.rowHeight)
                        }
                    }
                }
                .frame(height: CGFloat(min(subagents.count, Self.visibleRows)) * Self.rowHeight)
                .scrollBounceBehavior(.basedOnSize)
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .animation(.ui, value: subagents.map(\.id))
    }

    private var title: String {
        subagents.count == 1 ? "A subagent is at work" : "\(subagents.count) subagents at work"
    }

    private var header: some View {
        Button {
            withAnimation(.ui) { isHidden.toggle() }
        } label: {
            HStack(spacing: 10) {
                Spinner(size: 14)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if isHidden, subagents.count == 1, let subagent = subagents.first {
                    Text(subagent.task)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isHidden ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .padding(.leading, 14)
            .padding(.trailing, 16)
            .frame(height: 36)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isHidden ? "Show the subagents at work" : "Hide them: this line stays while they work")
        .accessibilityLabel(title)
        .accessibilityValue(isHidden ? "Hidden" : "Shown")
    }
}

private struct SubagentsBarRow: View {
    let subagent: SessionModel.Subagent
    let folder: String
    let session: String
    @Environment(Workspace.self) private var workspace
    @Environment(AppModel.self) private var app
    @Environment(Catalog.self) private var catalog
    @State private var model: SessionModel?

    private var agentName: String? {
        subagent.agent.map { agent in catalog.agents.first { $0.id == agent }?.name ?? agent }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(subagent.task.isEmpty ? "A subagent's task" : subagent.task)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            // Its agent and the step it's on, in one line that gives way at its end.
            Group {
                if let model, model.waitsForYou {
                    Text("Waiting for you")
                        .foregroundStyle(.orange)
                } else {
                    ShimmerText(text: [agentName, model?.currentStep ?? "Starting…"].compactMap { $0 }.joined(separator: " · "))
                }
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open", systemImage: "sidebar.right") {
                app.utilities.showSubagent(subagent.id, folder: folder, of: session)
            }
            .buttonStyle(TextButtonStyle())
            .font(.system(size: 13))
            // Whole, in a narrow conversation too: the step gives way first.
            .fixedSize()
            .help("Watch it beside the conversation, and talk to it")
            Button("Stop", systemImage: "stop.circle") { model?.stop() }
                .buttonStyle(TextButtonStyle())
                .font(.system(size: 13))
                .fixedSize()
                .disabled(model == nil)
                .help("Stop it: the agent hears it was stopped, and carries on")
        }
        // Under the line's words, past its mark.
        .padding(.leading, 42)
        .padding(.trailing, 10)
        .task(id: subagent.id) {
            let model = await workspace.subagentModel(for: subagent.id, in: folder)
            if let model, !model.isLoaded { await model.load() }
            self.model = model
        }
    }
}

// MARK: - The panel's tab

/// A subagent in a tab of the side panel: what it was asked and everything it does as it does
/// it, its model and Stop, and a composer to talk to it. While it works, what you send reaches it
/// at its next step; once it's done, it carries on from where it left off.
struct SubagentPane: View {
    let id: String
    /// The folder of the conversation it works for.
    let folder: String
    @Environment(Workspace.self) private var workspace
    @State private var model: SessionModel?
    @State private var isMissing = false

    var body: some View {
        Group {
            if let model {
                SubagentConversation(model: model)
            } else if isMissing {
                ContentUnavailableView("Subagent Not Found", systemImage: "person.2", description: Text("Its session is gone, or its machine can't be reached. Close this tab."))
                    .frame(maxHeight: .infinity)
            } else {
                Spinner(size: 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: id) {
            let model = await workspace.subagentModel(for: id, in: folder)
            if let model, !model.isLoaded { await model.load() }
            self.model = model
            isMissing = model == nil
        }
    }
}

private struct SubagentConversation: View {
    @Bindable var model: SessionModel
    @Environment(Workspace.self) private var workspace
    @Environment(Catalog.self) private var catalog
    @Environment(AppModel.self) private var app
    @LastModel private var lastModel

    private var isWorking: Bool { model.isRunning || workspace.running.contains(model.id) }

    private var agentName: String? {
        model.session.agent.map { agent in catalog.agents.first { $0.id == agent }?.name ?? agent }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TranscriptView(model: model)
                .frame(maxHeight: .infinity)
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    VStack(spacing: 10) {
                        if model.waitsForYou {
                            Label("It's asking you something in the conversation it works for.", systemImage: "hand.raised")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .glassEffect(.regular, in: .rect(cornerRadius: Metrics.composerRadius))
                        }
                        if let failure = model.failure {
                            Label(failure, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .glassEffect(.regular, in: .rect(cornerRadius: Metrics.composerRadius))
                                .onTapGesture { model.failure = nil }
                        }
                        composer
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Group {
                if isWorking {
                    Spinner(size: 13)
                } else if let error = model.lastStepError, !error.isInterruption {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                } else {
                    Image(systemName: "person.2").foregroundStyle(.secondary)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.session.title ?? "Subagent")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Group {
                    if isWorking {
                        ShimmerText(text: [agentName, model.currentStep].compactMap { $0 }.joined(separator: " · "))
                    } else {
                        Text([agentName, status].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12))
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isWorking {
                Button("Stop", systemImage: "stop.circle", action: model.stop)
                    .buttonStyle(TextButtonStyle())
                    .font(.system(size: 13))
                    .help("Stop it: the agent that started it hears it was stopped, and carries on")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    /// How it ended, with what it used.
    private var status: String? {
        if let error = model.lastStepError { return error.isInterruption ? "Stopped" : "Failed" }
        return ["Done", SubagentSteps.usage(model)].compactMap { $0 }.joined(separator: " · ")
    }

    private var composer: some View {
        Composer(
            session: model.id,
            text: $model.draftText,
            files: $model.draftFiles,
            quotes: $model.draftQuotes,
            quoteFocus: model.quoteFocus,
            agent: model.agent,
            approval: model.approval,
            model: model.session.model ?? catalog.startingModel(lastModel),
            isRunning: isWorking,
            hasQueue: !model.waiting.isEmpty,
            history: { model.sentMessages },
            folders: [model.session.location.directory],
            focusRequest: model.composerFocus,
            onSelectAgent: { _ in },
            onSelectApproval: { _ in },
            onSelectModel: { ref in model.selectModel(ref) },
            onSend: send,
            onQueue: send,
            onStop: model.stop,
            showsMode: false,
            scope: .engine,
            focusesOnAppear: false,
            prompt: isWorking ? "Tell it something: it reads it at its next step…" : "Message it: it carries on from where it left off…"
        )
    }

    private func send() {
        model.failure = nil
        let text = Quoting.message(quotes: model.draftQuotes, text: model.draftText)
        let files = model.draftFiles
        // Emptied first: what can't be sent comes back to it.
        model.draftText = ""
        model.draftFiles = []
        model.draftQuotes = []
        Analytics.shared.track("subagent_messaged", ["working": isWorking])
        model.submit(text, files: files, for: catalog.model(model.session.model), queue: false, commands: [])
    }
}
