import OpenCodeKit
import SwiftUI

/// Accounts' first section: the coding agents you may already pay for (Claude Code, Codex,
/// Cursor, Grok, Antigravity), each signed in as you, the way its maker's own app signs in. Their
/// models then show in the model picker of a new session on this Mac. Each can have more accounts
/// than its own sign-in (work and personal, say): each shows in the picker as its own.
struct CodingAgentsSection: View {
    /// Opens an agent's sign-in, in the page's place.
    let connect: (Integration) -> Void
    @Environment(Catalog.self) private var catalog
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Coding Agents")
                        .font(.headline)
                    Text("Use the plan you already have. Sessions with these agents run on this Mac, signed in as you.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                // You installed one or signed in to one elsewhere: asked anew (so is everything
                // when you come back to the app).
                Button {
                    Task { await catalog.refreshAgents(fresh: true) }
                } label: {
                    if catalog.isRefreshingAgents {
                        Spinner(size: 14)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.glass)
                .disabled(catalog.isRefreshingAgents || app.agents.api == nil)
                .help("Check again which agents are installed and signed in")
            }
            let agents = Self.ordered(catalog.codingAgents)
            if agents.isEmpty {
                Group {
                    if let failure = app.agents.failure {
                        ErrorCard(message: "The coding agents couldn't start. \(failure)")
                    } else {
                        HStack(spacing: 8) {
                            Spinner(size: 14)
                            Text("Looking for your coding agents…")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(agents) { agent in
                        AgentRow(agent: agent, connect: { connect(agent) }, connectAdded: connectAdded)
                        if agent.id != agents.last?.id {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(Surface.cardFill(scheme, focused: false), in: .rect(cornerRadius: Metrics.cardRadius))
                .specularRim(RoundedRectangle(cornerRadius: Metrics.cardRadius))
            }
        }
        .task(id: app.agents.api != nil) { await catalog.refreshAgents(fresh: true) }
    }

    /// Each agent's own sign-in, then the accounts you added to it, in the order you added them.
    static func ordered(_ agents: [Integration]) -> [Integration] {
        agents.enumerated().sorted { lhs, rhs in
            let left = OutsideAgents.order.firstIndex(of: OutsideAgents.base(lhs.element.id)) ?? 99
            let right = OutsideAgents.order.firstIndex(of: OutsideAgents.base(rhs.element.id)) ?? 99
            let leftAdded = OutsideAgents.account(lhs.element.id) == nil ? 0 : 1
            let rightAdded = OutsideAgents.account(rhs.element.id) == nil ? 0 : 1
            return (left, leftAdded, lhs.offset) < (right, rightAdded, rhs.offset)
        }
        .map(\.element)
    }

    /// An account just added: its sign-in opens, once the bridge lists it.
    private func connectAdded(_ providerID: String) {
        Task {
            await catalog.refreshAgents(fresh: true)
            if let added = catalog.codingAgents.first(where: { $0.id == providerID }) { connect(added) }
        }
    }
}

extension Integration {
    /// The ways to sign in Accounts offers. A ChatGPT plan is used through Codex and a SuperGrok
    /// plan through Grok's CLI (Coding Agents), so the engine's own sign-ins with those plans
    /// aren't offered: two ways to one plan read as two accounts. One made before still works,
    /// and shows as connected.
    var offeredSignInMethods: [Method] {
        signInMethods.filter { method in
            guard case .oauth(let id, _, _) = method else { return true }
            switch self.id {
            case "openai": return !id.hasPrefix("chatgpt")
            case "xai": return id != "device"
            default: return true
            }
        }
    }
}

private struct AgentRow: View {
    let agent: Integration
    let connect: () -> Void
    /// Opens the sign-in of an account just added.
    let connectAdded: (String) -> Void
    @Environment(AppModel.self) private var app
    @Environment(Catalog.self) private var catalog
    @State private var copied = false
    @State private var isSigningOut = false
    /// Adding another account, or renaming this one: the name being typed.
    @State private var naming: Naming?
    @State private var name = ""
    @State private var confirmsRemove = false
    @State private var failure: String?

    private enum Naming { case add, rename }

    /// One you added, rather than the agent's own sign-in.
    private var isAdded: Bool { OutsideAgents.account(agent.id) != nil }
    /// The bridge's name for the agent: `claude`, `codex`…
    private var kind: String? { agent.metadata?["agent"]?.string }
    private var agentName: String { OutsideAgents.name(agent.id) }

    private var isInstalled: Bool { agent.metadata?["installed"]?.bool ?? false }
    private var installCommand: String? { agent.metadata?["install"]?.string }
    private var signsOut: Bool { agent.metadata?["signsOut"]?.bool ?? false }

    private var detail: String {
        if let status = agent.connections.first?.status { return status.message }
        return agent.metadata?["message"]?.string ?? (isInstalled ? "Not signed in" : "Not installed")
    }

    var body: some View {
        HStack(spacing: 12) {
            ProviderLogo(id: OutsideAgents.logo(agent.id), size: 22)
                .frame(width: 32)
                // An account you added sits under its agent's own.
                .padding(.leading, isAdded ? 18 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if agent.isConnected {
                Button("Sign In Again", action: connect)
                    .buttonStyle(.glass)
                if signsOut {
                    Button("Sign Out", role: .destructive, action: signOut)
                        .buttonStyle(.glass)
                        .disabled(isSigningOut)
                }
            } else if isInstalled || installCommand == nil {
                Button("Sign In", action: connect)
                    .buttonStyle(.glassProminent)
            } else if let installCommand {
                Button(copied ? "Copied" : "Copy Install Command", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    Clipboard.copy(installCommand)
                    withAnimation(.ui) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation(.ui) { copied = false }
                    }
                }
                .buttonStyle(.glass)
                .help("Run it in Terminal, then sign in here.")
            }
            Menu {
                if isAdded {
                    Button("Rename…") {
                        name = agent.metadata?["accountLabel"]?.string ?? ""
                        naming = .rename
                    }
                    Divider()
                    Button("Remove Account…", role: .destructive) { confirmsRemove = true }
                } else {
                    Button("Add Another \(agentName) Account…") {
                        name = ""
                        naming = .add
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .disabled(kind == nil || app.agents.api == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .alert(naming == .rename ? "Rename This Account" : "Add Another \(agentName) Account", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name, like Work or Personal", text: $name)
            Button(naming == .rename ? "Rename" : "Add") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(naming == .rename ? "The name it goes by in Accounts and the model picker." : "It signs in on its own, and its models show in the model picker apart from your other \(agentName) account's.")
        }
        .alert("Remove \(agent.name)?", isPresented: $confirmsRemove) {
            Button("Remove", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Kuvo Code signs it out and forgets it. Sessions on its models go on when you pick another model.")
        }
        .alert("Couldn't Change This Account", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func save() {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = naming
        naming = nil
        Task {
            do {
                if mode == .rename {
                    try await app.agents.renameAccount(agent.id, label: label)
                    await catalog.refreshAgents()
                } else if let kind {
                    connectAdded(try await app.agents.addAccount(agent: kind, label: label))
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func remove() {
        Task {
            do {
                try await app.agents.removeAccount(agent.id)
                await catalog.refreshAgents()
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func signOut() {
        isSigningOut = true
        Task {
            defer { isSigningOut = false }
            try? await app.agents.signOut(agent.id)
            await catalog.refreshAgents()
        }
    }
}
