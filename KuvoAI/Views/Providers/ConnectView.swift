import OpenCodeKit
import SwiftUI

/// Signing in to one provider, whichever way it supports: browser sign-in,
/// a device code, an API key, or credentials the Mac already has (AWS, gcloud).
/// The engine runs the OAuth exchange and stores the result; this view guides
/// the person through it.
struct ConnectView: View {
    let integrationID: String
    /// Back to the account list (after "Done").
    var onDone: () -> Void = {}

    @Environment(AppModel.self) private var app
    @Environment(Catalog.self) private var catalog

    private enum Step: Equatable {
        case choose
        case details(Integration.Method)
        case key(Integration.Method)
        case waiting(OAuthAttempt)
        case connected
        case failed(String)
    }

    @State private var step = Step.choose
    @State private var answers: FormAnswer = [:]
    @State private var key = ""
    @State private var pastedCode = ""
    @State private var isWorking = false
    @State private var copied = false
    @State private var pollTask: Task<Void, Never>?

    private var integration: Integration? {
        catalog.integrations.first { $0.id == integrationID }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                Group {
                    switch step {
                    case .choose: methods
                    case .details(let method): details(method)
                    case .key(let method): keyEntry(method)
                    case .waiting(let attempt): waiting(attempt)
                    case .connected: connected
                    case .failed(let message): failed(message)
                    }
                }
                .frame(maxWidth: 420)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .animation(.ui, value: step)
        .onAppear(perform: chooseOnlyMethod)
        .onDisappear(perform: cancelAttempt)
    }

    // MARK: Steps

    private var header: some View {
        VStack(spacing: 12) {
            ProviderLogo(id: integrationID, size: 40)
                .frame(width: 72, height: 72)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .overlay(alignment: .bottomTrailing) {
                    if step == .connected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white, .green)
                            .offset(x: 6, y: 6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            Text(step == .connected ? "Connected to \(integration?.name ?? "")" : "Connect \(integration?.name ?? "")")
                .font(.title2.weight(.semibold))
        }
    }

    private var methods: some View {
        // Signing in with a subscription leads; an API key is the fallback.
        let methods = supportedMethods.sorted { rank($0) < rank($1) }
        let primary = methods.filter { !isLegacy($0) }
        let legacy = methods.filter(isLegacy)
        return VStack(spacing: 10) {
            ForEach(Array(primary.enumerated()), id: \.element.id) { index, method in
                Button { start(method) } label: {
                    Label(label(for: method), systemImage: symbol(for: method))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(index == 0 ? AnyPrimitiveButtonStyle(.glassProminent) : AnyPrimitiveButtonStyle(.glass))
                .controlSize(.extraLarge)
            }
            if !legacy.isEmpty {
                DisclosureGroup("Other ways to sign in") {
                    VStack(spacing: 8) {
                        ForEach(legacy) { method in
                            Button(label(for: method)) { start(method) }
                                .buttonStyle(.link)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 6)
                }
                .padding(.top, 6)
            }
            if let names = integration?.environmentVariables, !names.isEmpty {
                Text("Or set \(names.joined(separator: " or ")) in your shell profile.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
            }
        }
    }

    private func details(_ method: Integration.Method) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            FormFieldsView(fields: method.form, answers: $answers)
            HStack {
                backButton
                Spacer()
                Button("Continue") { proceed(method) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!FormFieldsView.isComplete(method.form, answers) || isWorking)
            }
            .controlSize(.large)
        }
    }

    private func keyEntry(_ method: Integration.Method) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(label(for: method))
                    .font(.callout.weight(.medium))
                SecureField("Paste your key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .onSubmit { connectKey(method) }
            }
            if !method.form.isEmpty {
                FormFieldsView(fields: method.form, answers: $answers)
            }
            HStack {
                backButton
                Spacer()
                Button("Connect") { connectKey(method) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || !FormFieldsView.isComplete(method.form, answers) || isWorking)
            }
            .controlSize(.large)
        }
    }

    private func waiting(_ attempt: OAuthAttempt) -> some View {
        VStack(spacing: 18) {
            if let code = attempt.userCode {
                VStack(spacing: 10) {
                    Text("Enter this code on the page that opened")
                        .foregroundStyle(.secondary)
                    Text(code)
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .kerning(3)
                        .textSelection(.enabled)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .glassEffect(.regular, in: .rect(cornerRadius: 16))
                    Button(copied ? "Copied" : "Copy Code", systemImage: copied ? "checkmark" : "doc.on.doc") { copy(code) }
                        .buttonStyle(.borderless)
                        .contentTransition(.symbolEffect(.replace))
                }
            } else if attempt.mode == .auto {
                Text("Finish signing in in your browser. This page updates on its own.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            if attempt.mode == .code {
                VStack(alignment: .leading, spacing: 8) {
                    Text(attempt.instructions)
                        .foregroundStyle(.secondary)
                    TextField("Paste the code", text: $pastedCode)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .onSubmit { complete(attempt) }
                    Button("Continue") { complete(attempt) }
                        .buttonStyle(.glassProminent)
                        .disabled(pastedCode.isEmpty || isWorking)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to finish…")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 16) {
                Button("Open the Page Again") { open(attempt.url) }
                Button("Cancel") {
                    cancelAttempt()
                    step = .choose
                }
            }
            .buttonStyle(.link)
        }
    }

    private var connected: some View {
        VStack(spacing: 16) {
            Text("Its models are now in the model picker.")
                .foregroundStyle(.secondary)
            Button("Done", action: onDone)
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 16) {
            ErrorCard(message: message)
            Button("Try Again") { step = .choose }
                .buttonStyle(.glass)
                .controlSize(.large)
        }
    }

    private var backButton: some View {
        Button("Back") { step = .choose }
            .buttonStyle(.borderless)
            .opacity(supportedMethods.count > 1 ? 1 : 0)
    }

    // MARK: Actions

    private var supportedMethods: [Integration.Method] {
        integration?.signInMethods.filter(isSupported) ?? []
    }

    private func chooseOnlyMethod() {
        if supportedMethods.count == 1, let method = supportedMethods.first { start(method) }
    }

    private func start(_ method: Integration.Method) {
        answers = FormFieldsView.defaults(for: method.form)
        switch method {
        case .key:
            key = ""
            step = .key(method)
        default:
            // Ask for details first if the method has any visible fields.
            if method.form.contains(where: { !$0.isHidden }) {
                step = .details(method)
            } else {
                proceed(method)
            }
        }
    }

    private func proceed(_ method: Integration.Method) {
        guard let api = app.api else { return }
        let answer = FormFieldsView.payload(method.form, answers)
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                switch method {
                case .oauth(let id, _, _):
                    let attempt = try await api.startOAuth(integration: integrationID, method: id, answer: answer.isEmpty ? nil : answer)
                    step = .waiting(attempt)
                    if let code = attempt.userCode { copy(code) }
                    open(attempt.url)
                    if attempt.mode == .auto { poll(attempt) }
                case .external(let id, _, _):
                    try await api.connectExternal(integration: integrationID, method: id, answer: answer.isEmpty ? nil : answer)
                    finish()
                default:
                    break
                }
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }

    private func connectKey(_ method: Integration.Method) {
        guard let api = app.api else { return }
        let answer = FormFieldsView.payload(method.form, answers)
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await api.connectKey(integration: integrationID, key: key.trimmingCharacters(in: .whitespacesAndNewlines), answer: answer.isEmpty ? nil : answer)
                finish()
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }

    /// The engine finishes the sign-in by itself; ask how it's going once a second.
    private func poll(_ attempt: OAuthAttempt) {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let api = app.api else { return }
                guard let status = try? await api.oauthStatus(integration: integrationID, attempt: attempt.attemptID) else { continue }
                switch status.status {
                case .pending: continue
                case .complete: finish(); return
                case .failed: step = .failed(status.message ?? "Signing in didn't work."); return
                case .expired: step = .failed("The sign-in timed out. Try again."); return
                }
            }
        }
    }

    private func complete(_ attempt: OAuthAttempt) {
        guard let api = app.api else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await api.completeOAuth(integration: integrationID, attempt: attempt.attemptID, code: pastedCode.trimmingCharacters(in: .whitespacesAndNewlines))
                finish()
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }

    private func finish() {
        pollTask?.cancel()
        pollTask = nil
        step = .connected
        NSApp.activate()
        Task { await catalog.refresh() }
    }

    private func cancelAttempt() {
        pollTask?.cancel()
        pollTask = nil
        if case .waiting(let attempt) = step, let api = app.api {
            Task { try? await api.cancelOAuth(integration: integrationID, attempt: attempt.attemptID) }
        }
    }

    private func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    private func copy(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        withAnimation(.ui) { copied = true }
    }

    // MARK: Describing methods

    private func isSupported(_ method: Integration.Method) -> Bool {
        switch method {
        case .oauth, .key, .external: true
        default: false
        }
    }

    private func rank(_ method: Integration.Method) -> Int {
        switch method {
        case .oauth: 0
        case .external: 1
        default: 2
        }
    }

    private func isLegacy(_ method: Integration.Method) -> Bool {
        label(for: method).localizedCaseInsensitiveContains("legacy")
    }

    private func label(for method: Integration.Method) -> String {
        switch method {
        case .oauth(_, let label, _), .external(_, let label, _): label
        case .key(let label, _): label ?? "Use an API key"
        default: ""
        }
    }

    private func symbol(for method: Integration.Method) -> String {
        switch method {
        case .oauth: "person.crop.circle"
        case .key: "key"
        case .external: "cloud"
        default: "link"
        }
    }
}

/// Lets one call site pick between two button styles.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init(_ style: some PrimitiveButtonStyle) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
