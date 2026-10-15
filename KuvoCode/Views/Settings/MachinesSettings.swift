import SwiftUI

/// Machines: Linux servers whose engine Kuvo Code runs over SSH, for projects on them. Each can
/// be connected again, disconnected or removed.
struct MachinesSettings: View {
    @Environment(AppModel.self) private var app
    @State private var showsAdd = false
    @State private var removing: Machine?
    /// Accounts that can't go to a machine (a ChatGPT sign-in).
    @State private var staysHere: [String] = []

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
                Text("API keys and a GitHub Copilot sign-in go to your machines’ engines, held in memory there and never written to their disks.")
                if !staysHere.isEmpty {
                    Text("\(staysHere.formatted(.list(type: .and))) can’t go, so \(staysHere.count == 1 ? "its" : "their") models are only on this Mac.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Accounts")
            }
        }
        .sheet(isPresented: $showsAdd) { MachineSheet() }
        #if DEBUG
        // KUVO_DEMO_ADD_MACHINE: the Add Machine sheet, open.
        .task {
            if ProcessInfo.processInfo.environment["KUVO_DEMO_ADD_MACHINE"] != nil {
                try? await Task.sleep(for: .seconds(1))
                showsAdd = true
            }
        }
        #endif
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { machine in
            Button("Remove", role: .destructive) { app.removeMachine(machine.id) }
        } message: { _ in
            Text("Its projects leave the sidebar. Its sessions and the engine stay on the machine, for when you add it again.")
        }
        .task(id: app.machines.list) { staysHere = await app.machineEnvironment().staysHere }
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
