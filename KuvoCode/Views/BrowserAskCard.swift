import AppKit
import SwiftUI

/// Asks Kuvo Code can't show in a conversation: from a bot in a group chat, or from an agent it
/// couldn't tell. A card at the top of the window, over whatever is in view, for the oldest one.
/// The rest show in the conversation that asked, over its composer.
struct BrowserAskOverlay: View {
    @Environment(AppModel.self) private var app

    private var loose: [BrowserAsks.Ask] {
        app.browserAsks.asks.filter { ask in ask.session.map { app.workspace.seats.contains($0) } ?? true }
    }

    var body: some View {
        if let ask = loose.first {
            BrowserAskCard(ask: ask, inThread: false, waiting: loose.count - 1)
                .id(ask.id)
                .frame(width: 400)
                .glassEffect(.regular, in: .rect(cornerRadius: Metrics.composerRadius))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
                .padding(.top, 52)
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// The agent asks for your sign-in, a code, or a step only you can do. What you type goes into
/// the page, never to the agent: the card says so, and names the page's real site.
struct BrowserAskCard: View {
    let ask: BrowserAsks.Ask
    /// In the conversation that asked, rather than over the window.
    var inThread = true
    /// More asks after this one.
    var waiting = 0
    @Environment(AppModel.self) private var app
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""
    @State private var saves = false
    /// Let agents sign in to this site with its saved password from now on, without asking.
    @State private var allowsAgents = false
    @FocusState private var focus: Field?

    private enum Field { case username, password, code }

    private var saved: [Passwords.Login] { Passwords.logins(for: ask.host) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch ask.kind {
            case .signIn: signIn
            case .code(let prompt): codeField(prompt)
            case .action(let instruction):
                Text(instruction)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            footer
        }
        .padding(16)
        .onAppear {
            switch ask.kind {
            case .signIn:
                if let login = saved.first { use(login) }
                saves = saved.isEmpty && Passwords.offersToSave && !Passwords.neverSites.contains(ask.host)
                focus = username.isEmpty ? .username : .password
            case .code: focus = .code
            case .action: break
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.browserAsks.title(ask))
                    .font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if waiting > 0 {
                Text("+\(waiting)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: .capsule)
                    .help(waiting == 1 ? "1 more waiting" : "\(waiting) more waiting")
            }
        }
    }

    private var symbol: String {
        switch ask.kind {
        case .signIn: "key.fill"
        case .code: "number"
        case .action: "hand.raised.fill"
        }
    }

    /// Where the browser runs, and who asks when it isn't the conversation's own agent.
    private var subtitle: String {
        let browser = ask.machine.map { "the browser on \($0)" } ?? "the browser"
        let who = inThread ? "" : "\(ask.asker ?? "The agent") asks, in \(browser). "
        switch ask.kind {
        case .signIn, .code:
            return inThread ? "It goes straight into the page in \(browser); the agent doesn’t see it." : who + "It goes straight into the page; the agent doesn’t see it."
        case .action:
            return inThread ? "In \(browser). The agent waits until you’re done." : "\(ask.asker ?? "The agent") needs you to do this in \(browser)."
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Username or email", text: $username)
                .wellField()
                .focused($focus, equals: .username)
                .onSubmit { focus = .password }
            SecureField("Password", text: $password)
                .wellField()
                .focused($focus, equals: .password)
                .onSubmit(send)
            HStack {
                if !saved.isEmpty {
                    Menu {
                        ForEach(saved) { login in
                            Button(login.account.isEmpty ? "No username" : login.account) { use(login) }
                        }
                    } label: {
                        Label("Saved Passwords", systemImage: "key")
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .controlSize(.small)
                }
                Spacer()
                Toggle("Save in Passwords", isOn: $saves)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(!saved.isEmpty && saved.contains { $0.account == username })
            }
            if saves || saved.contains(where: { $0.account == username }) {
                Toggle("Let agents sign in here on their own next time", isOn: $allowsAgents)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("With its saved password, without asking you; it still goes straight into the page. Settings › Passwords lists these sites.")
            }
        }
    }

    private func codeField(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !prompt.isEmpty {
                Text(prompt)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Code", text: $code)
                .font(.body.monospaced().weight(.medium))
                .wellField()
                .focused($focus, equals: .code)
                .onSubmit(send)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            switch ask.kind {
            case .signIn, .code:
                Button("Not Now", role: .cancel) { app.browserAsks.answer(ask.id, .declined) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isSignIn ? "Sign In" : "Fill", action: send)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSignIn ? username.isEmpty && password.isEmpty : code.isEmpty)
            case .action:
                Button("I Can’t", role: .cancel) { app.browserAsks.answer(ask.id, .declined) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if inThread {
                    Button("Show Page") { app.utilities.revealBrowser() }
                        .help("Show the browser in the panel")
                }
                Button("Done") { app.browserAsks.answer(ask.id, .done) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }

    private var isSignIn: Bool {
        if case .signIn = ask.kind { return true }
        return false
    }

    private func use(_ login: Passwords.Login) {
        username = login.account
        password = Passwords.password(for: login) ?? ""
    }

    private func send() {
        switch ask.kind {
        case .signIn:
            guard !username.isEmpty || !password.isEmpty else { return }
            let typed = saves && !password.isEmpty
            if typed { _ = Passwords.save(host: ask.host, account: username, password: password) }
            let answer = BrowserAsks.Answer.signIn(username: username.isEmpty ? nil : username, password: password.isEmpty ? nil : password)
            guard allowsAgents, !password.isEmpty else {
                app.browserAsks.answer(ask.id, answer)
                return
            }
            // A password you typed now is yours to allow; one filled in from Passwords asks you
            // first, as showing it in Settings does.
            let host = ask.host, id = ask.id, asks = app.browserAsks
            Task {
                let allowed = typed ? true : await Passwords.authenticate(reason: "let agents sign in to \(host) with its saved password")
                if allowed { Passwords.setAgentSignIn(host, true) }
                asks.answer(id, answer)
            }
        case .code:
            guard !code.isEmpty else { return }
            app.browserAsks.answer(ask.id, .code(code.trimmingCharacters(in: .whitespaces)))
        case .action:
            app.browserAsks.answer(ask.id, .done)
        }
    }
}
