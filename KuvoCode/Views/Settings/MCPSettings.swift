import OpenCodeKit
import SwiftUI

/// MCP servers: programs on this Mac or services on the web that give the agent more tools.
/// Each can be turned off, connected again, or signed in to.
struct MCPSettings: View {
    @Environment(AppModel.self) private var app
    @State private var live: [MCPServer] = []
    @State private var editing: ServerEdit?
    /// What to remove once its sheet has closed (and its fields are done saving).
    @State private var removal: [String]?
    @State private var isNaming = false
    @State private var newName = ""
    /// A server's sign-in, while it's open.
    @State private var signingIn: IntegrationRef?

    private var config: EngineConfig { app.engineConfig }
    static let path = ["mcp", "servers"]
    /// The app's own browser tools: not yours to change.
    private static let builtIn: Set = ["kuvo-browser"]

    private var names: [String] {
        let configured = config.value(at: Self.path)?.object?.keys.map { $0 } ?? []
        return Set(configured + live.map(\.name)).subtracting(Self.builtIn).sorted()
    }

    var body: some View {
        ScrollingSettingsForm {
            Section {
                if names.isEmpty {
                    Text("None yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(names, id: \.self) { name in
                    row(name)
                }
                Button("Add Server…") {
                    newName = ""
                    isNaming = true
                }
            } header: {
                Text("Servers")
            } footer: {
                Text("MCP servers give the agent more tools, like a database, an issue tracker or your design files. A server on this Mac runs a command; one on the web is a URL.")
                    .foregroundStyle(.secondary)
            }
            .settingsTop()

            ConfigProblem()

            Section {
                ConfigNumberField(title: "Time to start, in milliseconds", path: ["mcp", "timeout", "startup"], prompt: "30000")
                ConfigNumberField(title: "Time to list tools, in milliseconds", path: ["mcp", "timeout", "catalog"], prompt: "30000")
                ConfigNumberField(title: "Time for one tool call, in milliseconds", path: ["mcp", "timeout", "execution"], prompt: "43200000")
            } header: {
                Text("Timeouts")
            } footer: {
                Text("For every server, unless one sets its own.")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: config.settings) { await refresh() }
        // Servers connect in their own time: keep the statuses current while this is open.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                live = (try? await app.api?.mcpServers()) ?? live
            }
        }
        .sheet(item: $editing, onDismiss: removePending) { edit in
            ServerEditor(name: edit.id) { editing = nil } remove: { path in
                removal = path
                editing = nil
            }
        }
        .sheet(item: $signingIn) { ref in
            ConnectSheet(integrationID: ref.id) {
                signingIn = nil
                Task {
                    for server in live where server.integrationID == ref.id { try? await app.api?.connectMCP(server.name) }
                    await refresh()
                }
            }
        }
        .alert("Add MCP Server", isPresented: $isNaming) {
            TextField("Name, like github", text: $newName)
            Button("Add") { add() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A short name without spaces. The server's tools are named after it.")
        }
    }

    private func row(_ name: String) -> some View {
        let settings = config.value(at: Self.path + [name])
        let status = live.first { $0.name == name }?.status
        let isOn = settings?["disabled"]?.bool != true
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                    StatusLabel(status: status, isOn: isOn)
                }
                if let detail = Self.detail(of: settings) {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let error = status?.error, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if isOn, let server = live.first(where: { $0.name == name }), server.status.status == "needs_auth", let integrationID = server.integrationID {
                // Signing in goes through the server's sign-in, as an account does.
                Button("Sign In…") { signingIn = IntegrationRef(id: integrationID) }
            } else if isOn, status?.status == "failed" {
                Button("Connect") {
                    Task {
                        try? await app.api?.connectMCP(name)
                        await refresh()
                    }
                }
            }
            if settings != nil {
                Toggle("Turn on \(name)", isOn: Binding(
                    get: { isOn },
                    set: { config.set($0 ? nil : .bool(true), at: Self.path + [name, "disabled"]) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                Button("Edit…") { editing = ServerEdit(id: name) }
            }
        }
    }

    /// The command it runs, or its URL.
    static func detail(of settings: JSONValue?) -> String? {
        if let url = settings?["url"]?.string { return url }
        if let command = settings?["command"]?.array?.compactMap(\.string), !command.isEmpty { return command.joined(separator: " ") }
        return nil
    }

    private func refresh() async {
        // Give the engine a moment to pick up a change to the file.
        try? await Task.sleep(for: .milliseconds(400))
        live = (try? await app.api?.mcpServers()) ?? []
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !name.isEmpty, config.value(at: Self.path + [name]) == nil, !Self.builtIn.contains(name) else { return }
        // Off until it has a command or URL, so the engine doesn't try to start an empty one.
        config.set(.object(["type": .string("local"), "command": .array([]), "disabled": .bool(true)]), at: Self.path + [name])
        editing = ServerEdit(id: name)
    }

    private func removePending() {
        guard let removal else { return }
        app.engineConfig.set(nil, at: removal)
        self.removal = nil
    }
}

private struct ServerEdit: Identifiable {
    var id: String
}

private struct StatusLabel: View {
    let status: MCPServer.Status?
    let isOn: Bool

    var body: some View {
        let (title, color): (String, Color) = switch (isOn, status?.status) {
        case (false, _): ("Off", .secondary)
        case (_, "connected"): ("Connected", .green)
        case (_, "pending"): ("Connecting…", .secondary)
        case (_, "needs_auth"): ("Needs sign-in", .orange)
        case (_, "failed"): ("Couldn't connect", .red)
        case (_, "disabled"): ("Off", .secondary)
        default: ("Not started", .secondary)
        }
        return Text(title)
            .font(.caption)
            .foregroundStyle(color)
    }
}

/// One server's settings, saved as you change them.
private struct ServerEditor: View {
    let name: String
    let done: () -> Void
    /// Removes this entry, once the sheet has closed.
    let remove: ([String]) -> Void
    @Environment(AppModel.self) private var app
    @State private var command = ""
    /// The command as shown, to tell whether you changed it.
    @State private var shownCommand = ""
    @State private var confirmsRemoval = false

    private var config: EngineConfig { app.engineConfig }
    private var path: [String] { MCPSettings.path + [name] }
    private var isRemote: Bool { config.value(at: path + ["type"])?.string == "remote" }

    var body: some View {
        VStack(spacing: 0) {
            Text(name)
                .font(.headline)
                .padding(.top, 16)
            Form {
                Section {
                    Picker("Runs", selection: Binding(
                        get: { isRemote ? "remote" : "local" },
                        set: { kind in
                            // The two kinds have different fields; keep the shared ones.
                            var settings = config.value(at: path)?.object ?? [:]
                            for key in ["command", "cwd", "environment", "url", "headers", "oauth"] { settings[key] = nil }
                            settings["type"] = .string(kind)
                            if kind == "local" { settings["command"] = .array([]) }
                            config.set(.object(settings), at: path)
                        }
                    )) {
                        Text("On this Mac").tag("local")
                        Text("On the web").tag("remote")
                    }
                    .pickerStyle(.segmented)
                    if isRemote {
                        ConfigTextField(title: "URL", path: path + ["url"], prompt: "https://example.com/mcp")
                        // Sign-in set up by hand (an object) isn't this switch's to replace.
                        let customSignIn = config.value(at: path + ["oauth"])?.object != nil
                        Toggle(isOn: customSignIn ? .constant(true) : Binding(
                            get: { config.value(at: path + ["oauth"])?.bool != false },
                            set: { config.set($0 ? nil : .bool(false), at: path + ["oauth"]) }
                        )) {
                            Text("Sign in when the server asks")
                            Text(customSignIn ? "With the sign-in set up in the settings file." : "Turn off for a server that takes an API key in a header instead.")
                        }
                        .disabled(customSignIn)
                    } else {
                        TextField("Command", text: $command, prompt: Text("npx -y @modelcontextprotocol/server-github"))
                            .onSubmit(saveCommand)
                            .onDisappear(perform: saveCommand)
                        ConfigTextField(title: "Working folder", path: path + ["cwd"], prompt: "The project's folder")
                    }
                    Toggle(isOn: config.bool(path + ["codemode"], default: true)) {
                        Text("Let the agent call its tools from code")
                        Text("Code Mode: the agent can combine several of this server's tools in one step.")
                    }
                }
                if isRemote {
                    Section {
                        ConfigKeyValueList(path: path + ["headers"], keyPrompt: "Header, like Authorization", valuePrompt: "Value")
                    } header: {
                        Text("Headers")
                    } footer: {
                        Text("To keep a key out of this file, write {env:NAME} to use an environment variable.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ConfigKeyValueList(path: path + ["environment"], keyPrompt: "Variable, like GITHUB_TOKEN", valuePrompt: "Value")
                    } header: {
                        Text("Environment Variables")
                    } footer: {
                        Text("To keep a key out of this file, write {env:NAME} to use one of yours.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Remove Server…", role: .destructive) { confirmsRemoval = true }
                Spacer()
                Button("Done") {
                    saveCommand()
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 600, height: 560)
        .onAppear {
            command = config.value(at: path + ["command"])?.array?.compactMap(\.string).map(Self.quoted).joined(separator: " ") ?? ""
            shownCommand = command
        }
        .confirmationDialog("Remove \(name)?", isPresented: $confirmsRemoval) {
            Button("Remove", role: .destructive) {
                remove(path)
            }
        } message: {
            Text("The agent loses its tools.")
        }
    }

    /// The command as its words (quotes keep spaces in one); a server with a command is
    /// turned on.
    private func saveCommand() {
        // Only what you changed: the file's own form is kept otherwise.
        guard !isRemote, command != shownCommand else { return }
        shownCommand = command
        let words = Self.words(command)
        let old = config.value(at: path + ["command"])?.array?.compactMap(\.string) ?? []
        guard words != old else { return }
        config.set(.array(words.map(JSONValue.string)), at: path + ["command"])
        if old.isEmpty, !words.isEmpty { config.set(nil, at: path + ["disabled"]) }
    }

    /// A command line's words, as a shell splits them: quotes keep spaces in one word, and a
    /// backslash takes the next character as it is (except inside single quotes).
    static func words(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var hasWord = false
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
                hasWord = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                hasWord = true
            } else if character.isWhitespace {
                if hasWord { words.append(current) }
                current = ""
                hasWord = false
            } else {
                current.append(character)
                hasWord = true
            }
        }
        if hasWord { words.append(current) }
        return words
    }

    /// A word as it can be typed back: in double quotes, with quotes and backslashes escaped,
    /// when it has spaces, quotes or backslashes.
    static func quoted(_ word: String) -> String {
        guard word.isEmpty || word.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "\\" }) else { return word }
        return "\"" + word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
