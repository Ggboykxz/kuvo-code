import OpenCodeKit
import SwiftUI

/// Accounts' first section: the coding agents you may already pay for (Claude Code, Codex,
/// Cursor, Grok, Antigravity), each signed in as you, the way its maker's own app signs in. Their
/// models then show in the model picker of a new session on this Mac.
struct CodingAgentsSection: View {
    /// Opens an agent's sign-in, in the page's place.
    let connect: (Integration) -> Void
    @Environment(Catalog.self) private var catalog
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Coding Agents")
                    .font(.headline)
                Text("Use the plan you already have. Sessions with these agents run on this Mac, signed in as you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            let agents = catalog.codingAgents
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
                        AgentRow(agent: agent, connect: { connect(agent) })
                        if agent.id != agents.last?.id {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(Surface.cardFill(scheme, focused: false), in: .rect(cornerRadius: Metrics.cardRadius))
                .specularRim(RoundedRectangle(cornerRadius: Metrics.cardRadius))
            }
        }
    }
}

private struct AgentRow: View {
    let agent: Integration
    let connect: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(Catalog.self) private var catalog
    @State private var copied = false
    @State private var isSigningOut = false

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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
