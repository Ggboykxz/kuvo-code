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
    @State private var isNaming = false
    @State private var newName = ""
    /// Claude Code's agents, to bring over.
    @State private var claudeAgents: [ClaudeAgents.Agent] = []

    private var config: EngineConfig { app.engineConfig }

    /// The engine's own agents that people see; the hidden ones (titles, summaries) aren't
    /// listed, but their models can be set above.
    static let builtIn = ["build", "plan", "general", "explore"]
    private static let hiddenBuiltIn: Set = ["compaction", "title", "summary"]

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
            .settingsTop()

            ConfigProblem()

            Section {
                ForEach(agents, id: \.id) { agent in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(agent.name)
                                Text(Self.modeTitle(agent.mode))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if agent.isOff {
                                    Text("Off").font(.caption).foregroundStyle(.orange)
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
                        Button("Edit…") { editing = AgentEdit(id: agent.id, isBuiltIn: agent.isBuiltIn) }
                    }
                }
                Button("New Agent…") {
                    newName = ""
                    isNaming = true
                }
            } header: {
                Text("Agents")
            } footer: {
                Text("Primary agents are the modes you pick in the composer. Subagents are ones the agent hands part of a task to.")
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
        .sheet(item: $editing, onDismiss: removePending) { edit in
            AgentEditor(id: edit.id, isBuiltIn: edit.isBuiltIn) { editing = nil } remove: { path in
                removal = path
                editing = nil
            }
        }
        .alert("New Agent", isPresented: $isNaming) {
            TextField("Name, like reviewer", text: $newName)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A short name without spaces. It's how the agent is chosen.")
        }
    }

    private func create() {
        let id = newName.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !id.isEmpty, config.value(at: ["agents", id]) == nil, catalog.agents.first(where: { $0.id == id }) == nil else { return }
        config.set(.object(["mode": .string("primary"), "description": .string("")]), at: ["agents", id])
        Analytics.shared.track("agent_created")
        editing = AgentEdit(id: id, isBuiltIn: false)
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
    var id: String
    var isBuiltIn: Bool
}

/// One agent's settings, saved as you change them.
private struct AgentEditor: View {
    let id: String
    let isBuiltIn: Bool
    let done: () -> Void
    /// Removes this entry, once the sheet has closed.
    let remove: ([String]) -> Void
    @Environment(AppModel.self) private var app
    @Environment(Catalog.self) private var catalog
    @State private var confirmsRemoval = false

    private var config: EngineConfig { app.engineConfig }
    private var path: [String] { ["agents", id] }
    private var name: String { catalog.agents.first { $0.id == id }?.name ?? id }
    /// A built-in agent's own description, shown until you write another.
    private var builtInDescription: String? { isBuiltIn ? catalog.agents.first { $0.id == id }?.description : nil }

    var body: some View {
        VStack(spacing: 0) {
            Text(name)
                .font(.headline)
                .padding(.top, 16)
            Form {
                Section {
                    ConfigTextField(title: "Description", path: path + ["description"], prompt: builtInDescription ?? "What it's for, so the agent knows when to use it")
                    Picker("Use as", selection: Binding(
                        get: { config.value(at: path + ["mode"])?.string ?? catalog.agents.first { $0.id == id }?.mode ?? "primary" },
                        set: { config.set(.string($0), at: path + ["mode"]) }
                    )) {
                        Text("A mode you pick").tag("primary")
                        Text("A subagent").tag("subagent")
                        Text("Both").tag("all")
                    }
                    ConfigModelPicker(title: "Model", path: path + ["model"], defaultTitle: "The session's model")
                    ConfigNumberField(title: "Most steps per message", path: path + ["steps"], prompt: "No limit")
                    Toggle("Turned on", isOn: Binding(
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
            .formStyle(.grouped)
            HStack {
                if config.value(at: path) != nil {
                    Button(isBuiltIn ? "Reset to Built-In…" : "Delete Agent…", role: .destructive) { confirmsRemoval = true }
                }
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: 640)
        .navigationTitle(name)
        .confirmationDialog(isBuiltIn ? "Reset \(name) to how it's built in?" : "Delete \(name)?", isPresented: $confirmsRemoval) {
            Button(isBuiltIn ? "Reset" : "Delete", role: .destructive) {
                remove(path)
            }
        } message: {
            Text(isBuiltIn ? "Your changes to it are removed." : "It's removed from the engine's settings.")
        }
    }
}
