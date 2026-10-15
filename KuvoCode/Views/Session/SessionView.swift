import OpenCodeKit
import SwiftUI

struct SessionView: View {
    let model: SessionModel
    @Environment(Catalog.self) private var catalog
    @Environment(AppModel.self) private var app
    @LastModel private var lastModel

    var body: some View {
        TranscriptView(model: model)
            // A bar, not just an inset: the conversation scrolls on under the composer, softly
            // blurred there by the scroll view's edge effect.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                BottomStack(model: model, lastModel: $lastModel)
            }
            .navigationTitle(model.session.title ?? "New Session")
            .task { if !model.isLoaded { await model.load() } }
            .task(id: model.session.location.directory) { await catalog.loadCommands(in: model.session.location.directory) }
            .alert("Something went wrong", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
                Button("OK") {}
            } message: {
                Text(model.failure ?? "")
            }
    }
}

/// Questions and permission requests, stacked on the composer in one glass
/// container so they grow out of it and melt back in when answered.
private struct BottomStack: View {
    @Bindable var model: SessionModel
    @Binding var lastModel: ModelRef?
    @Environment(Catalog.self) private var catalog
    @Environment(Workspace.self) private var workspace
    @Environment(AppModel.self) private var app
    @AppStorage(ToolApproval.key) private var defaultApproval = ToolApproval.approveAll
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                ForEach(model.transcript.permissions) { request in
                    PermissionCard(request: request, directory: model.session.location.directory) { decision in
                        model.reply(to: request, decision)
                    }
                    .glassEffect(.regular, in: .rect(cornerRadius: Metrics.composerRadius))
                    .glassEffectID(request.id, in: glass)
                }
                ForEach(model.transcript.forms) { form in
                    QuestionCard(form: form) { answer in
                        model.answer(form, with: FormFieldsView.payload(form.fields, answer))
                    } dismiss: {
                        model.dismiss(form)
                    }
                    .glassEffect(.regular, in: .rect(cornerRadius: Metrics.composerRadius))
                    .glassEffectID(form.id, in: glass)
                }
                ForEach(app.browserAsks.asks(for: model.session.id)) { ask in
                    BrowserAskCard(ask: ask)
                        .glassEffect(.regular, in: .rect(cornerRadius: Metrics.composerRadius))
                        .glassEffectID(ask.id, in: glass)
                }
                if !model.waiting.isEmpty {
                    QueueDock(model: model)
                        .glassEffect(.regular, in: .rect(cornerRadius: Metrics.composerRadius))
                        .glassEffectID("waiting", in: glass)
                }
                Composer(
                    text: $model.draftText,
                    files: $model.draftFiles,
                    agent: model.agent,
                    approval: model.approval,
                    model: model.session.model ?? lastModel ?? catalog.defaultModel?.ref,
                    isRunning: model.isRunning,
                    hasQueue: !model.waiting.isEmpty,
                    history: model.sentMessages,
                    folders: [model.session.location.directory] + workspace.extraFolders(model.session.location.directory),
                    commands: catalog.commands(in: model.session.location.directory),
                    focusRequest: model.composerFocus,
                    commentCount: model.reviewComments.count,
                    onDiscardComments: { model.reviewComments = [] },
                    onSelectAgent: model.selectAgent,
                    onSelectApproval: { approval in
                        model.setApproval(approval)
                        defaultApproval = approval
                    },
                    onSelectModel: { ref in
                        model.selectModel(ref)
                        lastModel = ref
                    },
                    onSend: { send(queue: false) },
                    onQueue: { send(queue: true) },
                    onEditLast: model.editLast,
                    onStop: model.stop
                )
                .glassEffectID("composer", in: glass)
            }
            .animation(.ui, value: model.transcript.permissions.map(\.id))
            .animation(.ui, value: model.transcript.forms.map(\.id))
            .animation(.ui, value: model.waiting.isEmpty)
            .animation(.ui, value: app.browserAsks.asks(for: model.session.id).map(\.id))
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 16)
        .readableColumn()
    }

    private func send(queue: Bool) {
        model.submit(model.draftText, files: model.draftFiles, for: catalog.model(model.session.model), queue: queue, commands: catalog.commands(in: model.session.location.directory))
        model.draftText = ""
        model.draftFiles = []
    }
}

/// A new conversation, before its first message creates it on the server.
struct DraftSessionView: View {
    let directory: String
    /// Puts the cursor in the composer when it changes.
    var focusRequest = 0
    /// Each session the message starts (several, for attempts), the first first.
    let created: (Session, String, [URL]) -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(Catalog.self) private var catalog
    @Environment(AppModel.self) private var app
    /// Picked in the composer; until then, the mode Settings starts new sessions in.
    @State private var pickedAgent: String?
    private var agent: String { pickedAgent ?? catalog.startingAgent(chosen: app.engineConfig.value(at: ["default_agent"])?.string) }
    @AppStorage(ToolApproval.key) private var approval = ToolApproval.approveAll
    /// New sessions in a git repository get a worktree of their own (remembered).
    @AppStorage("newSessionWorktree") private var worktree = false
    /// How many sessions try the task, each in its own worktree; back to one after sending.
    @State private var attempts = 1
    @State private var isCreating = false

    /// Worktrees are for git repositories.
    private var isRepository: Bool { workspace.branches[directory] != nil || workspace.defaultBranches[directory] != nil }

    /// The project's new session keeps its draft under this key until it's created.
    private var draftKey: String { SidebarView.draftTag(directory) }
    @State private var failure: String?
    @LastModel private var lastModel

    /// The model picked last, when this engine has it (a machine may not have every account),
    /// or its default.
    private var startingModel: ModelRef? {
        if let lastModel, catalog.model(lastModel) != nil { return lastModel }
        return catalog.defaultModel?.ref
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Text(Workspace.isChat(directory) ? "What's on your mind?" : "What should we work on?")
                .font(.system(size: 30, weight: .semibold))
                .padding(.bottom, 28)

            Composer(
                text: Binding(get: { Drafts.shared[draftKey].text }, set: { Drafts.shared[draftKey].text = $0 }),
                files: Binding(get: { Drafts.shared[draftKey].files }, set: { Drafts.shared[draftKey].files = $0 }),
                agent: agent,
                approval: approval,
                model: startingModel,
                isRunning: isCreating,
                folders: [directory] + workspace.extraFolders(directory),
                commands: catalog.commands(in: directory),
                focusRequest: focusRequest,
                onSelectAgent: { pickedAgent = $0 },
                onSelectApproval: { approval = $0 },
                onSelectModel: { lastModel = $0 },
                worktree: isRepository ? worktree : nil,
                onSelectWorktree: { worktree = $0 },
                attempts: attempts,
                onSelectAttempts: { attempts = $0 },
                onSend: send,
                onStop: {}
            )
            .padding(.horizontal, Metrics.gutter)
            .readableColumn()

            if isCreating, isRepository, worktree {
                Label(attempts > 1 ? "Setting up \(attempts) worktrees…" : "Setting up a worktree…", systemImage: "arrow.triangle.branch")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }
            if let failure {
                ErrorCard(message: failure)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.top, 12)
                    .readableColumn()
            }
            Spacer()
            Spacer()
        }
        .navigationTitle("New Session")
        .task(id: directory) { await catalog.loadCommands(in: directory) }
    }

    private func send() {
        guard !isCreating else { return }
        isCreating = true
        let message = Drafts.shared[draftKey].text
        let attachments = Drafts.shared[draftKey].files
        let inWorktrees = isRepository && worktree
        let count = inWorktrees ? attempts : 1
        Task {
            do {
                // One after another: each worktree's setup runs on its own.
                var sessions: [Session] = []
                for _ in 0..<count {
                    sessions.append(try await workspace.createSession(in: directory, model: startingModel, agent: agent, approval: approval, worktree: inWorktrees))
                }
                if count > 1 { Analytics.shared.track("attempts_started", ["count": count]) }
                Drafts.shared.remove(draftKey)
                for session in sessions { created(session, message, attachments) }
            } catch {
                failure = error.localizedDescription
                isCreating = false
            }
        }
    }
}

/// The model picked last, so new sessions start with it.
@propertyWrapper
struct LastModel: DynamicProperty {
    @AppStorage("lastModel") private var stored = ""

    var wrappedValue: ModelRef? {
        get {
            let parts = stored.split(separator: "/", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return nil }
            return ModelRef(id: parts[1], providerID: parts[0], variant: parts.count > 2 ? parts[2] : nil)
        }
        nonmutating set {
            stored = newValue.map { [$0.providerID, $0.id, $0.variant].compactMap { $0 }.joined(separator: "/") } ?? ""
        }
    }

    var projectedValue: Binding<ModelRef?> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}
