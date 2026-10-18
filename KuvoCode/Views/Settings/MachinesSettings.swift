import SwiftUI

/// Machines: Linux servers whose engine Kuvo Code runs over SSH, for projects on them. Each can
/// be connected again, disconnected or removed.
struct MachinesSettings: View {
    @Environment(AppModel.self) private var app
    @State private var showsAdd = false
    @State private var removing: Machine?

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
        }
        .settingsDetail(isPresented: $showsAdd, title: "Add a Machine") {
            MachineForm(style: .settings, added: { _ in showsAdd = false }, cancel: { showsAdd = false })
        }
        #if DEBUG
        // KUVO_DEMO_ADD_MACHINE: Add a Machine, open.
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
