import OpenCodeKit
import SwiftUI

struct SessionView: View {
    let model: SessionModel
    @Environment(Catalog.self) private var catalog
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @State private var files: [URL] = []
    @LastModel private var lastModel

    var body: some View {
        TranscriptView(model: model)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                BottomStack(model: model, text: $text, files: $files, lastModel: $lastModel)
            }
            .navigationTitle(model.session.title ?? "New Session")
            .task { if !model.isLoaded { await model.load() } }
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
    let model: SessionModel
    @Binding var text: String
    @Binding var files: [URL]
    @Binding var lastModel: ModelRef?
    @Environment(Catalog.self) private var catalog
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
                Composer(
                    text: $text,
                    files: $files,
                    agent: model.agent,
                    approval: model.approval,
                    model: model.session.model ?? lastModel ?? catalog.defaultModel?.ref,
                    isRunning: model.isRunning,
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
                    onSend: {
                        model.send(text, files: files, for: catalog.model(model.session.model))
                        text = ""
                        files = []
                    },
                    onStop: model.stop
                )
                .glassEffectID("composer", in: glass)
            }
            .animation(.ui, value: model.transcript.permissions.map(\.id))
            .animation(.ui, value: model.transcript.forms.map(\.id))
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 16)
        .readableColumn()
    }
}

/// A new conversation, before its first message creates it on the server.
struct DraftSessionView: View {
    let directory: String
    let created: (Session, String, [URL]) -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(Catalog.self) private var catalog
    @State private var text = ""
    @State private var files: [URL] = []
    @State private var agent = "build"
    @AppStorage(ToolApproval.key) private var approval = ToolApproval.approveAll
    @State private var isCreating = false
    @State private var failure: String?
    @LastModel private var lastModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Text("What should we work on?")
                .font(.system(size: 30, weight: .semibold))
                .padding(.bottom, 28)

            Composer(
                text: $text,
                files: $files,
                agent: agent,
                approval: approval,
                model: lastModel ?? catalog.defaultModel?.ref,
                isRunning: isCreating,
                onSelectAgent: { agent = $0 },
                onSelectApproval: { approval = $0 },
                onSelectModel: { lastModel = $0 },
                onSend: send,
                onStop: {}
            )
            .padding(.horizontal, Metrics.gutter)
            .readableColumn()

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
    }

    private func send() {
        guard !isCreating else { return }
        isCreating = true
        let message = text
        let attachments = files
        Task {
            do {
                let session = try await workspace.createSession(in: directory, model: lastModel ?? catalog.defaultModel?.ref, agent: agent, approval: approval)
                created(session, message, attachments)
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
