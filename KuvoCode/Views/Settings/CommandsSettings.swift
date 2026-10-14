import OpenCodeKit
import SwiftUI

/// Slash commands: prompts you use often, run by typing "/" and their name in the composer.
struct CommandsSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(Catalog.self) private var catalog
    @State private var editing: CommandEdit?
    /// What to remove once its sheet has closed (and its fields are done saving).
    @State private var removal: [String]?
    @State private var isNaming = false
    @State private var newName = ""
    /// Claude Code's commands, to bring over.
    @State private var claudeCommands: [ClaudeCommands.Command] = []

    private var config: EngineConfig { app.engineConfig }
    static let path = ["commands"]

    private var names: [String] { (config.value(at: Self.path)?.object?.keys).map { $0.sorted() } ?? [] }
    /// The engine's own, and ones from plugins and MCP servers.
    private var others: [Command] { catalog.commands.filter { !names.contains($0.name) } }

    var body: some View {
        ScrollingSettingsForm {
            Section {
                if names.isEmpty {
                    Text("None yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(names, id: \.self) { name in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("/" + name)
                            if let description = config.value(at: Self.path + [name, "description"])?.string, !description.isEmpty {
                                Text(description)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Button("Edit…") { editing = CommandEdit(id: name) }
                    }
                }
                Button("New Command…") {
                    newName = ""
                    isNaming = true
                }
            } header: {
                Text("Your Commands")
            } footer: {
                Text("Type / and a command's name at the start of a message to run it. What you type after the name fills in $ARGUMENTS.")
                    .foregroundStyle(.secondary)
            }

            ConfigProblem()

            if !claudeCommands.isEmpty {
                Section {
                    ForEach(claudeCommands) { command in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("/" + command.id)
                                if !command.description.isEmpty {
                                    Text(command.description)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            if config.value(at: Self.path + [command.id]) != nil {
                                Label("Imported", systemImage: "checkmark")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                Button("Import") {
                                    config.set(.object(["template": .string(command.template), "description": .string(command.description)]), at: Self.path + [command.id])
                                    Analytics.shared.track("command_created", ["from": "claude"])
                                }
                            }
                        }
                    }
                } header: {
                    Text("From Claude Code")
                } footer: {
                    Text("Commands in ~/.claude/commands. Their prompts come over as they are.")
                        .foregroundStyle(.secondary)
                }
            }

            if !others.isEmpty {
                Section("Also Available") {
                    ForEach(others) { command in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("/" + command.name)
                            if let description = command.description {
                                // The engine's own read "guided AGENTS.md setup": a capital, like ours.
                                Text(description.prefix(1).uppercased() + description.dropFirst())
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .task { claudeCommands = await Task.detached { ClaudeCommands.load() }.value }
        .sheet(item: $editing, onDismiss: removePending) { edit in
            CommandEditor(name: edit.id) { editing = nil } remove: { path in
                removal = path
                editing = nil
            }
        }
        .alert("New Command", isPresented: $isNaming) {
            TextField("Name, like test", text: $newName)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A short name without spaces: you'll type / and this name.")
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !name.isEmpty, config.value(at: Self.path + [name]) == nil else { return }
        config.set(.object(["template": .string("")]), at: Self.path + [name])
        editing = CommandEdit(id: name)
    }

    private func removePending() {
        guard let removal else { return }
        app.engineConfig.set(nil, at: removal)
        self.removal = nil
    }
}

private struct CommandEdit: Identifiable {
    var id: String
}

/// One command's settings, saved as you change them.
private struct CommandEditor: View {
    let name: String
    let done: () -> Void
    /// Removes this entry, once the sheet has closed.
    let remove: ([String]) -> Void
    @Environment(AppModel.self) private var app
    @Environment(Catalog.self) private var catalog
    @State private var confirmsRemoval = false

    private var config: EngineConfig { app.engineConfig }
    private var path: [String] { CommandsSettings.path + [name] }

    var body: some View {
        VStack(spacing: 0) {
            Text("/" + name)
                .font(.headline)
                .padding(.top, 16)
            Form {
                Section {
                    ConfigTextField(title: "Description", path: path + ["description"], prompt: "Shown in the list when you type /")
                    Picker("Agent", selection: config.string(path + ["agent"])) {
                        Text("The session's").tag(String?.none)
                        ForEach(catalog.agents.filter { !$0.hidden }) { Text($0.name).tag(Optional($0.id)) }
                    }
                    ConfigModelPicker(title: "Model", path: path + ["model"], defaultTitle: "The agent's or the session's")
                    Toggle(isOn: Binding(
                        get: { config.value(at: path + ["subagent"])?.bool == true },
                        set: { config.set($0 ? .bool(true) : nil, at: path + ["subagent"]) }
                    )) {
                        Text("Run as a subagent")
                        Text("In the background, without filling up the conversation.")
                    }
                }
                Section {
                    ConfigTextEditor(path: path + ["template"], minHeight: 180)
                } header: {
                    Text("Prompt")
                } footer: {
                    Text("What the agent gets. $ARGUMENTS is what you type after the command; $1, $2 and so on are its words. !`command` puts in a command's output.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Delete Command…", role: .destructive) { confirmsRemoval = true }
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 600, height: 560)
        .confirmationDialog("Delete /\(name)?", isPresented: $confirmsRemoval) {
            Button("Delete", role: .destructive) {
                remove(path)
            }
        }
    }
}
