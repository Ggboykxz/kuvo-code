import OpenCodeKit
import SwiftUI

/// Signing in to one provider, whichever way it supports: browser sign-in,
/// a device code, an API key, or credentials the Mac already has (AWS, gcloud).
/// The engine runs the OAuth exchange and stores the result; this view guides
/// the person through it.
struct ConnectView: View {
    let integrationID: String
    /// What the last step says the connection gives you.
    var connectedNote = "Its models are now in the model picker."
    /// Back to the account list (after "Done").
    var onDone: () -> Void = {}
    /// Leaves without connecting. When set (in a sheet), every step but the last has a Cancel
    /// beside its own buttons.
    var onCancel: (() -> Void)? = nil

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
    /// Why the engine didn't take the key, shown under it until you change it.
    @State private var keyError: String?
    @State private var copied = false
    @State private var copyReset: Task<Void, Never>?
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
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            if onCancel != nil {
                trailingCancel
                    .padding(.top, 14)
            }
        }
    }

    private func details(_ method: Integration.Method) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            FormFieldsView(fields: method.form, answers: $answers)
            HStack {
                backButton
                Spacer()
                cancelButton
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
                Text("API key")
                    .font(.callout.weight(.medium))
                SecureField("Paste your key", text: $key)
                    .wellField()
                    .onSubmit { connectKey(method) }
                    .onChange(of: key) { keyError = nil }
            }
            if !method.form.isEmpty {
                FormFieldsView(fields: method.form, answers: $answers)
            }
            if let keyError {
                ErrorCard(message: keyError)
                    .transition(.opacity)
            }
            HStack {
                backButton
                Spacer()
                cancelButton
                Button("Connect") { connectKey(method) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || !FormFieldsView.isComplete(method.form, answers) || isWorking)
            }
            .controlSize(.large)
        }
        .animation(.ui, value: keyError)
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
                        .buttonStyle(TextButtonStyle())
                        .contentTransition(.symbolEffect(.replace))
                }
            } else if attempt.mode == .auto {
                Text("Finish signing in with your browser. This updates on its own.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            if attempt.mode == .code {
                VStack(alignment: .leading, spacing: 8) {
                    Text(attempt.instructions)
                        .foregroundStyle(.secondary)
                    TextField("Paste the code", text: $pastedCode)
                        .wellField()
                        .onSubmit { complete(attempt) }
                    HStack {
                        Spacer()
                        cancelButton
                        Button("Continue") { complete(attempt) }
                            .buttonStyle(.glassProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                    }
                    .controlSize(.large)
                    .padding(.top, 8)
                }
            } else {
                HStack(spacing: 8) {
                    Spinner(size: 16)
                    Text("Waiting for you to finish…")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 16) {
                Button("Open the Page Again") { open(attempt.url) }
                // In a sheet, Cancel leaves it; here it goes back to the ways to sign in.
                if onCancel == nil {
                    Button("Cancel") {
                        cancelAttempt()
                        step = .choose
                    }
                }
            }
            .buttonStyle(.link)

            if onCancel != nil, attempt.mode != .code {
                trailingCancel
            }
        }
    }

    private var connected: some View {
        VStack(spacing: 16) {
            Text(connectedNote)
                .multilineTextAlignment(.center)
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
            // Centered on its own; in a sheet, at the trailing edge beside Cancel.
            HStack {
                if onCancel != nil {
                    Spacer()
                    cancelButton
                }
                Button("Try Again") { step = .choose }
                    .buttonStyle(.glass)
            }
            .controlSize(.large)
        }
    }

    /// Back to the ways to sign in, when there's more than one.
    @ViewBuilder private var backButton: some View {
        if supportedMethods.count > 1 {
            Button("Back") { step = .choose }
                .buttonStyle(TextButtonStyle(outset: true))
        }
    }

    /// Leaves the sheet without connecting; nothing outside a sheet.
    @ViewBuilder private var cancelButton: some View {
        if let onCancel {
            Button("Cancel", action: onCancel)
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
        }
    }

    /// Cancel on its own, at the trailing edge, for steps without a row of buttons.
    private var trailingCancel: some View {
        HStack {
            Spacer()
            cancelButton
        }
        .controlSize(.large)
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
            keyError = nil
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
                    finish(method: "external")
                default:
                    break
                }
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }

    private func connectKey(_ method: Integration.Method) {
        // Return in the field gets here too, past the disabled button.
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api = app.api, !trimmed.isEmpty, FormFieldsView.isComplete(method.form, answers), !isWorking else { return }
        let answer = FormFieldsView.payload(method.form, answers)
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await api.connectKey(integration: integrationID, key: trimmed, answer: answer.isEmpty ? nil : answer)
                finish(method: "api_key")
            } catch {
                // Stay on the key, so it can be fixed rather than pasted again.
                keyError = error.localizedDescription
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
                case .complete: finish(method: "oauth"); return
                case .failed: step = .failed(status.message ?? "Signing in didn't work."); return
                case .expired: step = .failed("The sign-in timed out. Try again."); return
                }
            }
        }
    }

    private func complete(_ attempt: OAuthAttempt) {
        let code = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api = app.api, !code.isEmpty, !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await api.completeOAuth(integration: integrationID, attempt: attempt.attemptID, code: code)
                finish(method: "oauth")
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }

    private func finish(method: String) {
        Analytics.shared.track("account_connected", ["provider": Analytics.provider(integrationID), "method": method])
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

    /// Copies the code, and says so for a moment.
    private func copy(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        withAnimation(.ui) { copied = true }
        copyReset?.cancel()
        copyReset = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.ui) { copied = false }
        }
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
