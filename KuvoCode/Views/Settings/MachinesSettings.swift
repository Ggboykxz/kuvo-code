import OpenCodeKit
import SwiftUI

/// Machines: Linux servers whose engine Kuvo Code runs over SSH, for projects on them. Each can
/// be connected again, disconnected or removed.
struct MachinesSettings: View {
    @Environment(AppModel.self) private var app
    @State private var showsAdd = false
    @State private var removing: Machine?
    /// The machine whose coding agents are open.
    @State private var agentsOf: Machine?

    var body: some View {
        ScrollingSettingsForm {
            Section {
                if app.machines.list.isEmpty {
                    Text("None yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(app.machines.list) { machine in
                    if let engine = app.machines.engine(machine.id) { row(engine) }
                }
                Button("Add Machine…") { showsAdd = true }
            } header: {
                Text("Machines")
            } footer: {
                Text("Linux servers you reach with SSH, like a home server or a VPS. Their projects open next to this Mac’s, and their sessions run there. Kuvo Code installs its engine in ~/.kuvo-code on each, and stops it when you quit.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Your accounts, API keys and sign-ins alike, go to your machines’ engines and stay in step with this Mac’s: one you add, switch to or sign out of here does there too.")
            } header: {
                Text("Accounts")
            }

            if !app.machines.list.isEmpty {
                Section {
                    ForEach(app.machines.list) { machine in
                        if let engine = app.machines.engine(machine.id) { agentsRow(engine) }
                    }
                } header: {
                    Text("Coding Agents")
                } footer: {
                    Text("Claude Code, Codex, Cursor, Grok and Antigravity run on each machine too, signed in there: their sign-ins stay on the machine.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .settingsDetail(item: $agentsOf, title: { "Coding Agents on \($0.name)" }) { machine in
            if let engine = app.machines.engine(machine.id) { MachineAgentsPage(engine: engine) }
        }
        .settingsDetail(isPresented: $showsAdd, title: "Add a Machine") {
            MachineForm(style: .settings, added: { _ in showsAdd = false }, cancel: { showsAdd = false })
        }
        #if DEBUG
        // KUVO_DEMO_ADD_MACHINE: Add a Machine, open. KUVO_DEMO_MACHINE_AGENTS=<machine>: that
        // machine's coding agents, once it's connected.
        .task {
            let environment = ProcessInfo.processInfo.environment
            if environment["KUVO_DEMO_ADD_MACHINE"] != nil {
                try? await Task.sleep(for: .seconds(1))
                showsAdd = true
            }
            if let id = environment["KUVO_DEMO_MACHINE_AGENTS"], let engine = app.machines.engine(id) {
                for _ in 0..<600 where !(engine.isReady && engine.agents.api != nil) { try? await Task.sleep(for: .seconds(1)) }
                agentsOf = engine.machine
            }
        }
        #endif
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { machine in
            Button("Remove", role: .destructive) { app.removeMachine(machine.id) }
        } message: { _ in
            Text("Its projects leave the sidebar. Its sessions and the engine stay on the machine, for when you add it again.")
        }
    }

    /// A machine's coding agents: who's signed in there, opened for more.
    private func agentsRow(_ engine: MachineEngine) -> some View {
        let signedIn = engine.catalog.codingAgents.filter(\.isConnected).map { OutsideAgents.name($0.id) }
        return Button {
            agentsOf = engine.machine
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.machine.name)
                    Text(!engine.isReady ? "Not connected" : engine.agents.api == nil || engine.agents.isDown ? "Not running" : signedIn.isEmpty ? "None signed in" : Array(Set(signedIn)).sorted().formatted(.list(type: .and)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!engine.isReady)
    }

    private func row(_ engine: MachineEngine) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.machine.name)
                MachineStatus(engine: engine)
            }
            Spacer()
            switch engine.state {
            case .ready:
                Button("Disconnect") { app.disconnect(engine) }
            case .failed, .preparing:
                Button(engine.isRetrying ? "Connect Now" : "Connect") { app.connect(engine) }
            default:
                EmptyView()
            }
            Button("Remove…") { removing = engine.machine }
        }
    }
}

/// The coding agents on one machine, as Settings › Accounts shows this Mac's: each signs in there,
/// finishing in your browser here.
private struct MachineAgentsPage: View {
    let engine: MachineEngine
    @State private var connecting: Integration?

    var body: some View {
        ScrollingSettingsForm {
            Section {
                if let connecting {
                    ConnectView(integrationID: connecting.id, onDone: { self.connecting = nil }, onCancel: { self.connecting = nil })
                } else if let failure = engine.agents.failure, engine.agents.api == nil {
                    ErrorCard(message: "The coding agents aren’t running on \(engine.machine.name): \(failure)")
                } else if engine.agents.isDown {
                    ErrorCard(message: "The coding agents stopped on \(engine.machine.name). They start again with its engine: when nothing runs there, click Disconnect, then Connect.")
                } else {
                    SubscriptionsSection(connect: { connecting = $0 }, showsPlans: false)
                }
            }
        }
        .environment(engine.catalog)
        .environment(\.agentsBridge, engine.agents)
    }
}
