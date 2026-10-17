import OpenCodeKit
import SwiftUI

/// The agents: the defaults new sessions start with, the built-in agents (Build, Plan and the
/// subagents), and your own, each with its instructions, model and permissions.
struct AgentsSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(Catalog.self) private var catalog
    @State private var editing: AgentEdit?
    /// What to remove once its sheet has closed (and its fields are done saving).
    @State private var removal: [String]?
    /// Claude Code's agents, to bring over.
    @State private var claudeAgents: [ClaudeAgents.Agent] = []

    private var config: EngineConfig { app.engineConfig }

    /// The engine's own agents that people see; the hidden ones (titles, summaries) aren't
    /// listed, but their models can be set above.
    static let builtIn = ["build", "plan", "general", "explore"]
    static let hiddenBuiltIn: Set = ["compaction", "title", "summary"]

    /// Built-in ones first, then yours: from the engine's list and from the settings (one
    /// that's turned off is only there).
    private var agents: [(id: String, name: String, mode: String, description: String?, isBuiltIn: Bool, isOff: Bool)] {
        let configured = config.value(at: ["agents"])?.object ?? [:]
        var rows: [(id: String, name: String, mode: String, description: String?, isBuiltIn: Bool, isOff: Bool)] = []
        for id in Self.builtIn + configured.keys.sorted() where !rows.contains(where: { $0.id == id }) && !Self.hiddenBuiltIn.contains(id) {
            let live = catalog.agents.first { $0.id == id }
            let settings = configured[id]
            rows.append((
                id,
                live?.name ?? id,
                settings?["mode"]?.string ?? live?.mode ?? "primary",
                settings?["description"]?.string ?? live?.description,
                Self.builtIn.contains(id),
                settings?["disabled"]?.bool == true
            ))
        }
        return rows
    }

    var body: some View {
        ScrollingSettingsForm {
            Section {
                Picker("Mode for new sessions", selection: config.string(["default_agent"])) {
                    Text("Build").tag(String?.none)
                    ForEach(catalog.primaryAgents.filter { $0.id != "build" }) { Text($0.name).tag(Optional($0.id)) }
                }
                ConfigModelPicker(title: "Model for new sessions", path: ["model"], defaultTitle: "The engine's choice")
                ConfigModelPicker(title: "Model for session titles", path: ["agents", "title", "model"], defaultTitle: "The session's model")
            } footer: {
                Text("New sessions use the model you picked last; this one is for when there's none. A small, fast model is enough for titles.")
                    .foregroundStyle(.secondary)
            }

            ConfigProblem()

            Section {
                ForEach(agents, id: \.id) { agent in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(agent.name)
                                Text(Self.modeTitle(agent.mode))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if agent.isOff {
                                    Text("Off").font(.subheadline).foregroundStyle(.orange)
                                }
                            }
                            if let description = agent.description, !description.isEmpty {
                                Text(description)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Button("Edit…") { editing = AgentEdit(agentID: agent.id, isBuiltIn: agent.isBuiltIn) }
                    }
                }
                Button("New Agent…") { editing = AgentEdit(agentID: nil) }
            } header: {
                Text("Agents")
            } footer: {
                Text("Modes are the agents you pick in the composer. Subagents are ones the agent hands part of a task to.")
                    .foregroundStyle(.secondary)
            }

            if !claudeAgents.isEmpty {
                Section {
                    ForEach(claudeAgents) { agent in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.name)
                                if !agent.description.isEmpty {
                                    Text(agent.description)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            if config.value(at: ["agents", agent.id]) != nil {
                                Label("Imported", systemImage: "checkmark")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                Button("Import") { importAgent(agent) }
                            }
                        }
                    }
                } header: {
                    Text("From Claude Code")
                } footer: {
                    Text("Agents in ~/.claude/agents, brought over as subagents with their description and instructions. They use the session's model and the permissions here, not the tools and model Claude Code gives them.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { claudeAgents = await Task.detached { ClaudeAgents.load() }.value }
        .settingsDetail(item: $editing, title: { $0.agentID ?? "New Agent" }, onDismiss: removePending) { edit in
            AgentEditor(id: edit.agentID, isBuiltIn: edit.isBuiltIn) { editing = nil } remove: { path in
                removal = path
                editing = nil
            }
        }
    }

    private func importAgent(_ agent: ClaudeAgents.Agent) {
        config.set(.object(["mode": .string("subagent"), "description": .string(agent.description), "system": .string(agent.instructions)]), at: ["agents", agent.id])
        Analytics.shared.track("agent_created", ["from": "claude"])
    }

    static func modeTitle(_ mode: String) -> String {
        switch mode {
        case "subagent": "Subagent"
        case "all": "Mode and subagent"
        default: "Mode"
        }
    }

    private func removePending() {
        guard let removal else { return }
        app.engineConfig.set(nil, at: removal)
        self.removal = nil
    }
}

private struct AgentEdit: Identifiable {
    /// Nil for a new one.
    var agentID: String?
    var isBuiltIn = false

    var id: String { agentID ?? "" }
}

/// One agent's settings, in the page's place. A new one is named first; after that, changes are
/// saved as you make them.
private struct AgentEditor: View {
    /// Nil for a new one, until it's named.
    @State var id: String?
    let isBuiltIn: Bool
    let done: () -> Void
    /// Removes this entry, once it's closed.
    let remove: ([String]) -> Void
    @Environment(AppModel.self) private var app
    @Environment(Catalog.self) private var catalog
    @State private var newName = ""
    @State private var confirmsRemoval = false

    private var config: EngineConfig { app.engineConfig }
    private var name: String {
        guard let id else { return "New Agent" }
        return catalog.agents.first { $0.id == id }?.name ?? id
    }

    /// The name you typed, as an agent's: lowercase, with hyphens for spaces, and only letters,
    /// digits, hyphens and underscores.
    private var newID: String {
        newName.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Why the name you typed can't be used, if it can't.
    private var problem: String? {
        if newID.isEmpty {
            return newName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : "A name needs a letter or a number."
        }
        // Not one the engine already has: that would change it instead.
        let isTaken = config.value(at: ["agents", newID]) != nil || catalog.agents.contains(where: { $0.id == newID })
            || AgentsSettings.builtIn.contains(newID) || AgentsSettings.hiddenBuiltIn.contains(newID)
        return isTaken ? "There's an agent called \(newID) already." : nil
    }

    var body: some View {
        SettingsDetailPage {
            if let id {
                editor(id)
            } else {
                naming
            }
        } footer: {
            SettingsEditorButtons(create: id == nil ? "Create Agent" : nil, canCreate: !newID.isEmpty && problem == nil, onCreate: create,
                                  remove: id.flatMap { config.value(at: ["agents", $0]) } != nil ? (isBuiltIn ? "Reset to Built-In…" : "Delete Agent…") : nil,
                                  onRemove: { confirmsRemoval = true }, done: done)
        }
        .settingsDetailTitle(name)
        .confirmationDialog(isBuiltIn ? "Reset \(name) to how it's built in?" : "Delete \(name)?", isPresented: $confirmsRemoval) {
            Button(isBuiltIn ? "Reset" : "Delete", role: .destructive) {
                if let id { remove(["agents", id]) }
            }
        } message: {
            Text(isBuiltIn ? "Your changes to it are removed." : "It's removed from the engine's settings.")
        }
    }

    /// A new agent's name, before anything is written: what's wrong with it, or what it'll be
    /// called when that isn't quite what you typed.
    private var naming: some View {
        Section {
            TextField("Name", text: $newName, prompt: Text("reviewer"))
                .onSubmit(create)
        } footer: {
            if let problem {
                Text(problem).foregroundStyle(.red)
            } else if !newID.isEmpty, newID != newName.trimmingCharacters(in: .whitespaces) {
                Text(verbatim: "It'll be called \(newID).").foregroundStyle(.secondary)
            } else {
                Text("A short name without spaces. It's how the agent is chosen.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func editor(_ id: String) -> some View {
        let path = ["agents", id]
        // A built-in agent's own description, shown until you write another.
        let builtInDescription = isBuiltIn ? catalog.agents.first(where: { $0.id == id })?.description : nil
        Group {
            Section {
                ConfigTextField(title: "Description", path: path + ["description"], prompt: builtInDescription ?? "What it's for, so the agent knows when to use it", multiline: true)
                Picker("Use as", selection: Binding(
                    get: { config.value(at: path + ["mode"])?.string ?? catalog.agents.first { $0.id == id }?.mode ?? "primary" },
                    set: { config.set(.string($0), at: path + ["mode"]) }
                )) {
                    ForEach(["primary", "subagent", "all"], id: \.self) { mode in
                        Text(AgentsSettings.modeTitle(mode)).tag(mode)
                    }
                }
                ConfigModelPicker(title: "Model", path: path + ["model"], defaultTitle: "The session's model")
                ConfigNumberField(title: "Most steps per message", path: path + ["steps"], prompt: "No limit")
                Toggle("Use this agent", isOn: Binding(
                    get: { config.value(at: path + ["disabled"])?.bool != true },
                    set: { config.set($0 ? nil : .bool(true), at: path + ["disabled"]) }
                ))
            }
            Section {
                ConfigTextEditor(path: path + ["system"])
            } header: {
                Text("Instructions")
            } footer: {
                Text(isBuiltIn
                    ? "Leave empty to keep the built-in instructions. Anything here replaces them; the project's AGENTS.md, skills and MCP servers still apply."
                    : "How it should work. The project's AGENTS.md, skills and MCP servers still apply.")
                    .foregroundStyle(.secondary)
            }
            Section {
                RulesEditor(path: path + ["permissions"])
            } header: {
                Text("Permissions")
            } footer: {
                Text("Added after the ones in Settings › Permissions, so these win for this agent.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func create() {
        guard !newID.isEmpty, problem == nil else { return }
        config.set(.object(["mode": .string("primary"), "description": .string("")]), at: ["agents", newID])
        Analytics.shared.track("agent_created")
        id = newID
    }
}
