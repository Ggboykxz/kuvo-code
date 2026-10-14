import OpenCodeKit
import SwiftUI

/// The engine: how it's doing, and how it works: summaries, formatting, the shell, web search,
/// limits, files it ignores, plugins, and its settings file.
struct EngineSettings: View {
    @Environment(AppModel.self) private var app
    @State private var shells: [ShellOption] = []
    @State private var searchProviders: [WebSearchProvider] = []
    @State private var plugins: [PluginInfo] = []
    /// A search service's key, while it's being added.
    @State private var addingKey: IntegrationRef?
    @Environment(Catalog.self) private var catalog

    private var config: EngineConfig { app.engineConfig }

    var body: some View {
        ScrollingSettingsForm {
            Section {
                LabeledContent("Engine", value: "opencode \(OpenCodeEngine.version)")
                LabeledContent("Status") {
                    switch app.engine {
                    case .ready: Label(app.isLive ? "Running" : "Reconnecting", systemImage: "circle.fill").foregroundStyle(app.isLive ? .green : .orange)
                    case .failed: Label("Stopped", systemImage: "circle.fill").foregroundStyle(.red)
                    default: Text("Starting…")
                    }
                }
                LabeledContent("Data") {
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppInfo.supportDirectory]) }
                        Button("Restart Engine") { Task { await app.restart() } }
                    }
                }
            } footer: {
                Text("Sessions, accounts and settings are kept in the data folder, separate from any opencode you have installed.")
                    .foregroundStyle(.secondary)
            }
            .settingsTop()

            ConfigProblem()
            Section("Behavior") {
                Toggle(isOn: config.bool(["compaction", "auto"], default: true)) {
                    Text("Summarize long conversations automatically")
                    Text("Before the context window fills up, older messages are replaced by a summary.")
                }
                // Formatters set up by hand (an object) aren't this toggle's to replace.
                let customFormatters = config.value(at: ["formatter"])?.object != nil
                Toggle(isOn: customFormatters ? .constant(true) : config.bool(["formatter"], default: false)) {
                    Text("Format files after the agent changes them")
                    Text(customFormatters
                        ? "With the formatters set up in the settings file."
                        : "With the formatters the engine knows, such as Prettier, gofmt or rustfmt, when the project has them.")
                }
                .disabled(customFormatters)
                // Warming set up by hand (an object) isn't this switch's to replace.
                let customWarming = config.value(at: ["warming"])?.object != nil
                Toggle(isOn: customWarming ? .constant(true) : config.bool(["warming"], default: false)) {
                    Text("Keep recent sessions warm")
                    Text(customWarming
                        ? "As set up in the settings file."
                        : "Sends a small request every few minutes so the model's cache stays ready. Uses a little of your quota.")
                }
                .disabled(customWarming)
                Toggle(isOn: config.bool(["snapshots"], default: true)) {
                    Text("Keep snapshots of files")
                    Text("Undo From Here needs them to put files back.")
                }
                Picker("Shell", selection: config.string(["shell"])) {
                    Text("Your login shell").tag(String?.none)
                    ForEach(shells.filter(\.acceptable)) { shell in
                        Text("\(shell.name) (\(shell.path))").tag(Optional(shell.path))
                    }
                }
                Picker("Subagents can start subagents", selection: Binding(
                    get: { config.value(at: ["experimental", "subagent_depth"])?.int ?? 1 },
                    set: { config.set($0 == 1 ? nil : .number(Double($0)), at: ["experimental", "subagent_depth"]) }
                )) {
                    Text("No").tag(1)
                    ForEach(2...5, id: \.self) { Text("Up to \($0) levels").tag($0) }
                }
            }

            Section {
                Picker("Web search", selection: Binding<String>(
                    get: {
                        guard let value = config.value(at: ["websearch"]) else { return "" }
                        if value.bool == false { return "off" }
                        return value["provider"]?.string ?? ""
                    },
                    set: { choice in
                        switch choice {
                        case "": config.set(nil, at: ["websearch"])
                        case "off": config.set(.bool(false), at: ["websearch"])
                        default: config.set(.object(["provider": .string(choice)]), at: ["websearch"])
                        }
                    }
                )) {
                    Text("Ask the first time").tag("")
                    Text("Any connected service").tag("random")
                    ForEach(searchProviders) { Text($0.name).tag($0.id) }
                    Divider()
                    Text("Off").tag("off")
                }
                // The chosen service, if it still needs its key.
                if let provider = config.value(at: ["websearch", "provider"])?.string, provider != "random",
                   let integration = catalog.integrations.first(where: { $0.id == provider }) {
                    LabeledContent("\(integration.name) key") {
                        if integration.isConnected {
                            Text("Added").foregroundStyle(.secondary)
                        } else {
                            Button("Add API Key…") { addingKey = IntegrationRef(id: provider) }
                        }
                    }
                }
            } header: {
                Text("Web Search")
            } footer: {
                Text("Each search service needs its own API key. With none chosen, the agent asks the first time it searches.")
                    .foregroundStyle(.secondary)
            }

            Section("Limits") {
                ConfigNumberField(title: "Lines of tool output the agent keeps", path: ["tool_output", "max_lines"])
                ConfigNumberField(title: "Bytes of tool output the agent keeps", path: ["tool_output", "max_bytes"])
                Toggle("Shrink large images the agent reads", isOn: config.bool(["media", "image", "auto_resize"], default: true))
                ConfigNumberField(title: "Largest image width, in pixels", path: ["media", "image", "max_width"])
                ConfigNumberField(title: "Largest image height, in pixels", path: ["media", "image", "max_height"])
            }

            Section {
                ConfigStringList(path: ["watcher", "ignore"], prompt: "A pattern, like dist/** or *.log")
            } header: {
                Text("Files the Engine Doesn't Watch")
            } footer: {
                Text("Changes to these don't reach the agent while it works.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ConfigTextField(title: "Worktrees folder", path: ["worktree", "directory"], prompt: "Default")
            } footer: {
                Text("Where new git worktrees go. A relative path starts at the project's folder.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ConfigStringList(path: ["plugins"], prompt: "An npm package, like opencode-wakatime")
                ForEach(plugins.filter { $0.source.type != "builtin" && $0.state.status == "failed" }) { plugin in
                    Label("\(plugin.id): \(plugin.state.error ?? "didn't load")", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Plugins")
            } footer: {
                Text("Plugins add tools and change how the engine works. They run code on your Mac, so add only ones you trust.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Settings file") {
                    HStack {
                        Button("Open") { NSWorkspace.shared.open(config.file) }
                            .disabled(!FileManager.default.fileExists(atPath: config.file.path))
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([config.file]) }
                            .disabled(!FileManager.default.fileExists(atPath: config.file.path))
                    }
                }
            } footer: {
                Text("Everything in Settings is saved in this file, in opencode's format, and the engine picks up changes as you make them. A project's own opencode.json takes precedence for that project.")
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $addingKey) { ref in
            ConnectSheet(integrationID: ref.id) { addingKey = nil }
        }
        .task {
            guard let api = app.api else { return }
            shells = (try? await api.shells()) ?? []
            searchProviders = (try? await api.webSearchProviders()) ?? []
            plugins = (try? await api.plugins()) ?? []
        }
    }
}
