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
    /// A server's sign-in, while it's open.
    @State private var signingIn: IntegrationRef?

    private var config: EngineConfig { app.engineConfig }
    static let path = ["mcp", "servers"]
    /// The app's own browser tools: not yours to change.
    static let builtIn: Set = ["kuvo-browser"]

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
                Button("Add Server…") { editing = ServerEdit(name: nil) }
            } header: {
                Text("Servers")
            } footer: {
                Text("MCP servers give the agent more tools, like a database, an issue tracker or your design files. A server on this Mac runs a command; one on the web is a URL.")
                    .foregroundStyle(.secondary)
            }

            ConfigProblem()

            Section {
                ForEach(MCPCatalog.servers) { server in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(server.title)
                                Text(server.access.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Text(server.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if config.value(at: Self.path + [server.id]) != nil {
                            Label("Added", systemImage: "checkmark")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Add") { add(server) }
                        }
                    }
                }
            } header: {
                Text("Popular Servers")
            } footer: {
                Text("Each from the company behind it, as listed in the official MCP Registry. One that needs an account asks you to sign in here once it's added.")
                    .foregroundStyle(.secondary)
            }

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
            ServerEditor(name: edit.name, taken: Set(live.map(\.name))) { editing = nil } remove: { path in
                removal = path
                editing = nil
            }
        }
        .sheet(item: $signingIn) { ref in
            ConnectSheet(integrationID: ref.id, name: ref.service?.title, symbol: ref.service?.symbol, note: "The agent can use its tools now.") {
                signingIn = nil
                Task {
                    for server in live where server.integrationID == ref.id { try? await app.api?.connectMCP(server.name) }
                    await refresh()
                    app.syncSignIns()
                }
            }
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
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .help(error)
                }
            }
            Spacer()
            // Centered on each other, so the switch sits level with the buttons rather than on
            // their text's baseline; the buttons line up with the name. The switch is last, at
            // the edge, as in the other tabs.
            HStack {
                if isOn, let server = live.first(where: { $0.name == name }), server.status.status == "needs_auth", let integrationID = server.integrationID {
                    // Signing in goes through the server's sign-in, as an account does.
                    Button("Sign In…") { signingIn = IntegrationRef(id: integrationID, service: Integrations.service(name)) }
                } else if isOn, status?.status == "failed" {
                    Button("Try Again") {
                        Task {
                            try? await app.api?.connectMCP(name)
                            await refresh()
                        }
                    }
                }
                if settings != nil {
                    Button("Edit…") { editing = ServerEdit(name: name) }
                    Toggle("Turn on \(name)", isOn: Binding(
                        get: { isOn },
                        set: { config.set($0 ? nil : .bool(true), at: Self.path + [name, "disabled"]) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
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

    private func add(_ server: MCPCatalog.Server) {
        config.set(server.settings, at: Self.path + [server.id])
        Analytics.shared.track("mcp_server_added", ["catalog": server.id])
    }

    private func removePending() {
        guard let removal else { return }
        app.engineConfig.set(nil, at: removal)
        self.removal = nil
    }
}

private struct ServerEdit: Identifiable {
    /// Nil for a new one.
    var name: String?
    var id: String { name ?? "" }
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
            .font(.subheadline)
            .foregroundStyle(color)
    }
}

/// One server's settings. A new one is named first; after that, changes are saved as you
/// make them.
private struct ServerEditor: View {
    /// Nil for a new one, until it's named.
    @State var name: String?
    /// The servers the engine has, from anywhere: a new one can't take their names.
    let taken: Set<String>
    let done: () -> Void
    /// Removes this entry, once the sheet has closed.
    let remove: ([String]) -> Void
    @Environment(AppModel.self) private var app
    @State private var newName = ""
    @State private var command = ""
    /// The command as shown, to tell whether you changed it.
    @State private var shownCommand = ""
    /// What the kind you switched away from had (its command or URL and the rest, and whether
    /// it was on), to bring back if you switch back while this is open.
    @State private var putAside: [String: JSONValue] = [:]
    @State private var confirmsRemoval = false

    private var config: EngineConfig { app.engineConfig }
    /// The fields only one kind has: a command and what it runs with, or a URL and how it
    /// signs in.
    private static let kindFields = ["command", "cwd", "environment", "url", "headers", "oauth"]
    /// Under headers and environment variables alike.
    private static var keyNote: some View {
        Text("To keep a key out of the settings file, write {env:NAME} to use one of your environment variables.")
            .foregroundStyle(.secondary)
    }

    /// The name you typed, as a server's: hyphens for spaces, and only letters, digits,
    /// hyphens and underscores.
    private var newID: String {
        newName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Why the name you typed can't be used, if it can't.
    private var problem: String? {
        if newID.isEmpty {
            return newName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : "A name needs a letter or a number."
        }
        if MCPSettings.builtIn.contains(newID) { return "Kuvo Code uses that name for its own tools." }
        let isTaken = config.value(at: MCPSettings.path + [newID]) != nil || taken.contains(newID)
        return isTaken ? "There's a server called \(newID) already." : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(name ?? "Add Server")
                .font(.headline)
                .padding(.top, 16)
            if let name {
                editor(MCPSettings.path + [name])
            } else {
                naming
            }
            HStack {
                if name != nil {
                    Button("Remove Server…", role: .destructive) { confirmsRemoval = true }
                }
                Spacer()
                if let name {
                    Button("Done") { close(MCPSettings.path + [name]) }
                        .keyboardShortcut(.defaultAction)
                        // Changes are saved as you make them, so Escape closes it too.
                        .background {
                            Button("Close") { close(MCPSettings.path + [name]) }
                                .keyboardShortcut(.cancelAction)
                                .opacity(0)
                                .accessibilityHidden(true)
                        }
                } else {
                    Button("Cancel", role: .cancel, action: done)
                        .keyboardShortcut(.cancelAction)
                    Button("Add Server", action: add)
                        .keyboardShortcut(.defaultAction)
                        .disabled(newID.isEmpty || problem != nil)
                }
            }
            .padding(16)
        }
        .frame(width: SettingsView.sheetWidth, height: name == nil ? 220 : SettingsView.sheetHeight)
        .confirmationDialog("Remove \(name ?? "")?", isPresented: $confirmsRemoval) {
            Button("Remove", role: .destructive) {
                if let name { remove(MCPSettings.path + [name]) }
            }
        } message: {
            Text("The agent loses its tools.")
        }
    }

    /// A new server's name, before anything is written: what's wrong with it, or what it'll
    /// be called when that isn't quite what you typed.
    private var naming: some View {
        Form {
            Section {
                TextField("Name", text: $newName, prompt: Text("github"))
                    .onSubmit(add)
            } footer: {
                if let problem {
                    Text(problem).foregroundStyle(.red)
                } else if !newID.isEmpty, newID != newName.trimmingCharacters(in: .whitespaces) {
                    Text(verbatim: "It'll be called \(newID).").foregroundStyle(.secondary)
                } else {
                    Text("A short name without spaces. The server's tools are named after it.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func editor(_ path: [String]) -> some View {
        let isRemote = config.value(at: path + ["type"])?.string == "remote"
        Form {
            Section {
                Picker("Runs", selection: Binding(
                    get: { isRemote ? "remote" : "local" },
                    set: { switchKind(of: path, to: $0) }
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
                    // A command is often long: it wraps, in a typeface that keeps its flags apart.
                    TextField(text: $command, prompt: Text(verbatim: "npx -y @modelcontextprotocol/server-github"), axis: .vertical) {
                        Text("Command").font(.body)
                    }
                    .font(.body.monospaced())
                    .lineLimit(1...4)
                    .onSubmit { saveCommand(path) }
                    .onDisappear { saveCommand(path) }
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
                    Self.keyNote
                }
            } else {
                Section {
                    ConfigKeyValueList(path: path + ["environment"], keyPrompt: "Variable, like GITHUB_TOKEN", valuePrompt: "Value")
                } header: {
                    Text("Environment Variables")
                } footer: {
                    Self.keyNote
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            command = Self.commandLine(config.value(at: path + ["command"]))
            shownCommand = command
        }
        // A URL typed into a server that had none turns it on, as a command does. (Switching
        // kinds brings back its own URL, on or off as it was, so that's left alone.)
        .onChange(of: config.value(at: path)) { old, new in
            guard old?["type"] == new?["type"], (old?["url"]?.string ?? "").isEmpty, !(new?["url"]?.string ?? "").isEmpty else { return }
            config.set(nil, at: path + ["disabled"])
        }
    }

    private func add() {
        guard !newID.isEmpty, problem == nil else { return }
        // Off until it has a command or URL, so the engine doesn't try to start an empty one.
        config.set(.object(["type": .string("local"), "command": .array([]), "disabled": .bool(true)]), at: MCPSettings.path + [newID])
        Analytics.shared.track("mcp_server_added")
        name = newID
    }

    private func close(_ path: [String]) {
        saveCommand(path)
        done()
    }

    /// Switches between running a command and connecting to a URL. What the kind you leave
    /// has is put aside, and what the other had comes back; one with nothing to run yet is
    /// off, as a new server is, until you give it a command or URL.
    private func switchKind(of path: [String], to kind: String) {
        let isRemote = config.value(at: path + ["type"])?.string == "remote"
        guard kind != (isRemote ? "remote" : "local") else { return }
        // A command you typed and didn't press Return on is put aside with the rest.
        saveCommand(path)
        var settings = config.value(at: path)?.object ?? [:]
        var leaving: [String: JSONValue] = [:]
        for key in Self.kindFields + ["disabled"] { leaving[key] = settings.removeValue(forKey: key) }
        if putAside.isEmpty {
            settings["disabled"] = .bool(true)
        } else {
            for (key, value) in putAside { settings[key] = value }
        }
        putAside = leaving
        settings["type"] = .string(kind)
        if kind == "local", settings["command"] == nil { settings["command"] = .array([]) }
        config.set(.object(settings), at: path)
        // The field shows the command that came back, or none, as saved.
        command = Self.commandLine(settings["command"])
        shownCommand = command
    }

    /// The command as its words (quotes keep spaces in one); a server with a command is
    /// turned on.
    private func saveCommand(_ path: [String]) {
        // Only what you changed: the file's own form is kept otherwise.
        guard config.value(at: path + ["type"])?.string != "remote", command != shownCommand else { return }
        shownCommand = command
        let words = Self.words(command)
        let old = config.value(at: path + ["command"])?.array?.compactMap(\.string) ?? []
        guard words != old else { return }
        config.set(.array(words.map(JSONValue.string)), at: path + ["command"])
        if old.isEmpty, !words.isEmpty { config.set(nil, at: path + ["disabled"]) }
    }

    /// A command as one line to edit: its words, quoted where they need it.
    static func commandLine(_ command: JSONValue?) -> String {
        command?.array?.compactMap(\.string).map(quoted).joined(separator: " ") ?? ""
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
