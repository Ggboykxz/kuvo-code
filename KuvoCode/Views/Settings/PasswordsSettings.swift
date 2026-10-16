import AppKit
import SwiftUI

/// Passwords: the sign-ins the panel's browser saved, and the sites it doesn't offer to save for.
struct PasswordsSettings: View {
    @AppStorage(Passwords.offersKey) private var offersToSave = true
    @State private var logins: [Passwords.Login] = []
    @State private var never: [String] = []
    @State private var agentSites: [String] = []
    @State private var search = ""
    /// Passwords shown, by login, after you've confirmed it's you.
    @State private var revealed: [String: String] = [:]
    @State private var deleting: Passwords.Login?

    private var shown: [Passwords.Login] {
        logins.filter { search.isEmpty || $0.host.localizedCaseInsensitiveContains(search) || $0.account.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ScrollingSettingsForm {
            Section {
                Toggle(isOn: $offersToSave) {
                    Text("Offer to save passwords")
                    Text("When you sign in to a site in the panel’s browser. Click the key in its toolbar to fill one in.")
                }
            } footer: {
                Text("Kept in your login keychain, where Keychain Access lists them too. Kuvo Code fills one in only when you ask, or for a site you let agents sign in to on their own, and the agent never sees them.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if logins.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                } else {
                    SettingsSearchRow(text: $search, prompt: "Search passwords")
                    ForEach(shown) { login in
                        LabeledContent {
                            HStack(spacing: 4) {
                                if let password = revealed[login.id] {
                                    Text(password)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                        .lineLimit(1)
                                        .frame(maxWidth: 180, alignment: .trailing)
                                }
                                Button {
                                    toggleReveal(login)
                                } label: {
                                    Image(systemName: revealed[login.id] == nil ? "eye" : "eye.slash")
                                }
                                .buttonStyle(IconButtonStyle(width: 28, height: 24))
                                .help(revealed[login.id] == nil ? "Show Password" : "Hide Password")
                                Button {
                                    copy(login)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(IconButtonStyle(width: 28, height: 24))
                                .help("Copy Password")
                                Button {
                                    deleting = login
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(IconButtonStyle(width: 28, height: 24))
                                .help("Delete")
                            }
                        } label: {
                            Text(login.host)
                            Text(login.account.isEmpty ? "No username" : login.account)
                        }
                    }
                }
            } header: {
                Text(logins.isEmpty ? "Saved Passwords" : "Saved Passwords (\(logins.count))")
            }

            if !agentSites.isEmpty {
                Section {
                    ForEach(agentSites, id: \.self) { host in
                        LabeledContent(host) {
                            Button("Remove") {
                                Passwords.setAgentSignIn(host, false)
                                load()
                            }
                        }
                    }
                } header: {
                    Text("Agents Sign In On Their Own")
                } footer: {
                    Text("When an agent asks to sign in to one of these, its saved password goes straight into the page without asking you. Remove one to be asked again.")
                        .foregroundStyle(.secondary)
                }
            }
            if !never.isEmpty {
                Section {
                    ForEach(never, id: \.self) { host in
                        LabeledContent(host) {
                            Button("Remove") {
                                Passwords.setNever(host, false)
                                load()
                            }
                        }
                    }
                } header: {
                    Text("Never Saved For")
                } footer: {
                    Text("Sites you chose Never for. Remove one to be offered again.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: load)
        .confirmationDialog("Delete the password for \(deleting?.account ?? "") on \(deleting?.host ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { login in
            Button("Delete", role: .destructive) {
                Passwords.delete(login)
                revealed[login.id] = nil
                load()
            }
        } message: { _ in
            Text("It’s removed from your keychain. The site’s own account isn’t affected.")
        }
    }

    private func load() {
        logins = Passwords.logins()
        never = Passwords.neverSites
        agentSites = Passwords.agentSites
    }

    private func toggleReveal(_ login: Passwords.Login) {
        if revealed[login.id] != nil {
            revealed[login.id] = nil
            return
        }
        Task {
            guard await Passwords.authenticate(reason: "show the password for \(login.host)") else { return }
            revealed[login.id] = Passwords.password(for: login)
        }
    }

    private func copy(_ login: Passwords.Login) {
        Task {
            guard await Passwords.authenticate(reason: "copy the password for \(login.host)"), let password = Passwords.password(for: login) else { return }
            NSPasteboard.general.clearContents()
            // Marked concealed, so clipboard managers that respect it don't keep it.
            NSPasteboard.general.setString(password, forType: .string)
            NSPasteboard.general.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
    }
}
