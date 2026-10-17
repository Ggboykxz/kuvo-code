import OpenCodeKit
import SwiftUI

// Controls for the engine's settings file (`EngineConfig`). Each reads its value from the file
// and writes it back: toggles and pickers at once, text when you press Return or leave the
// field. An empty field removes the setting, so the engine's default applies.

extension EngineConfig {
    func bool(_ path: [String], default fallback: Bool) -> Binding<Bool> {
        Binding(get: { self.value(at: path)?.bool ?? fallback }, set: { self.set(.bool($0), at: path) })
    }

    /// A string choice; `nil` (the "Default" option) removes the setting.
    func string(_ path: [String]) -> Binding<String?> {
        Binding(get: { self.value(at: path)?.string }, set: { self.set($0.map(JSONValue.string), at: path) })
    }

    /// A list's items as they are, whatever they hold.
    func items(_ path: [String]) -> [JSONValue] {
        value(at: path)?.array ?? []
    }

    func setItems(_ items: [JSONValue], at path: [String]) {
        set(items.isEmpty ? nil : .array(items), at: path)
    }
}

/// A text setting, saved when you press Return or leave the field.
struct ConfigTextField: View {
    let title: String
    let path: [String]
    var prompt = ""
    /// For a few sentences (a description): its name above it, and the field as tall as what's
    /// written in it, so all of it shows.
    var multiline = false
    @Environment(AppModel.self) private var app
    @State private var field = SettingField()
    @FocusState private var isFocused: Bool

    var body: some View {
        if multiline {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                text
                    .labelsHidden()
                    .lineLimit(1...10)
            }
        } else {
            text
        }
    }

    private var text: some View {
        let stored = app.engineConfig.value(at: path)?.string ?? ""
        return TextField(title, text: $field.text, prompt: Text(prompt), axis: multiline ? .vertical : .horizontal)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { if !isFocused { commit() } }
            .onAppear { field.load(stored) }
            .onChange(of: stored) { if !isFocused { field.load(stored) } }
            .onDisappear(perform: commit)
    }

    private func commit() {
        guard let value = field.edit(trimming: true) else { return }
        app.engineConfig.set(value.isEmpty ? nil : .string(value), at: path)
    }
}

/// A whole-number setting, more than zero; empty means the engine's default.
struct ConfigNumberField: View {
    let title: String
    let path: [String]
    var prompt = "Default"
    @Environment(AppModel.self) private var app
    @State private var field = SettingField()
    @FocusState private var isFocused: Bool

    var body: some View {
        let stored = app.engineConfig.value(at: path)?.int.map(String.init) ?? ""
        TextField(title, text: $field.text, prompt: Text(prompt))
            .multilineTextAlignment(.trailing)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { if !isFocused { commit() } }
            .onAppear { field.load(stored) }
            .onChange(of: stored) { if !isFocused { field.load(stored) } }
            .onDisappear(perform: commit)
    }

    private func commit() {
        // Digits only; zero isn't a setting the engine takes, so it means the default.
        let number = Int(field.text.filter(\.isNumber)).flatMap { $0 > 0 ? $0 : nil }
        field.text = number.map(String.init) ?? ""
        guard field.edit(trimming: true) != nil else { return }
        app.engineConfig.set(number.map { .number(Double($0)) }, at: path)
    }
}

/// Longer text, like an agent's instructions: saved when you leave it. Monospaced, like a
/// skill's instructions, and on the row's own background rather than a box of its own.
struct ConfigTextEditor: View {
    let path: [String]
    var minHeight: CGFloat = 120
    @Environment(AppModel.self) private var app
    @State private var field = SettingField()
    @FocusState private var isFocused: Bool

    var body: some View {
        let stored = app.engineConfig.value(at: path)?.string ?? ""
        TextEditor(text: $field.text)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .focused($isFocused)
            .onChange(of: isFocused) { if !isFocused { commit() } }
            .onAppear { field.load(stored) }
            .onChange(of: stored) { if !isFocused { field.load(stored) } }
            .onDisappear(perform: commit)
    }

    private func commit() {
        guard let value = field.edit(trimming: true) else { return }
        app.engineConfig.set(value.isEmpty ? nil : .string(value), at: path)
    }
}

/// A field's text and what the file had when it was shown. Only a change you made is
/// saved: leaving a field you didn't touch writes nothing (so it can't bring back an entry
/// you just removed, or undo an edit made to the file elsewhere).
struct SettingField {
    var text = ""
    private var loaded = ""

    mutating func load(_ value: String) {
        text = value
        loaded = value
    }

    /// The text to save, if you changed it; it counts as saved from then on.
    mutating func edit(trimming: Bool) -> String? {
        let value = trimming ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
        guard value != loaded else { return nil }
        loaded = value
        return value
    }
}

/// A model setting, as "provider/model"; Default removes it.
struct ConfigModelPicker: View {
    let title: String
    let path: [String]
    var defaultTitle = "Default"
    @Environment(AppModel.self) private var app
    @Environment(Catalog.self) private var catalog

    var body: some View {
        Picker(title, selection: app.engineConfig.string(path)) {
            Text(defaultTitle).tag(String?.none)
            ForEach(catalog.modelsByProvider, id: \.provider) { group in
                Section(group.provider) {
                    ForEach(group.models) { model in
                        Text(model.name).tag(Optional("\(model.providerID)/\(model.id)"))
                    }
                }
            }
            // One set by hand, or one the pickers don't offer (its account isn't connected here),
            // as it's written.
            if let current = app.engineConfig.value(at: path)?.string,
               !catalog.offered.contains(where: { "\($0.providerID)/\($0.id)" == current }) {
                Text(current).tag(Optional(current))
            }
        }
    }
}

/// A list of strings (paths, patterns, packages): each removable, a field to add one. Items
/// that aren't plain strings (set up by hand) are kept as they are and shown as such.
struct ConfigStringList: View {
    let path: [String]
    let prompt: String
    @Environment(AppModel.self) private var app
    @State private var newItem = ""

    var body: some View {
        let value = app.engineConfig.value(at: path)
        if let value, value.array == nil {
            Text("Set up by hand in the settings file.")
                .foregroundStyle(.secondary)
        } else {
            let items = app.engineConfig.items(path)
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack {
                    Text(item.string ?? item["package"]?.string ?? "Set up in the settings file")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .foregroundStyle(item.string == nil ? .secondary : .primary)
                    Spacer()
                    Button {
                        var items = items
                        items.remove(at: index)
                        app.engineConfig.setItems(items, at: path)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(RemoveButtonStyle())
                    .help("Remove")
                }
            }
            TextField("Add", text: $newItem, prompt: Text(prompt))
                .labelsHidden()
                .onSubmit {
                    let item = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !item.isEmpty, !items.contains(.string(item)) else { return }
                    app.engineConfig.setItems(items + [.string(item)], at: path)
                    newItem = ""
                }
        }
    }
}

/// Names and values (environment variables, headers): each value editable in place and each
/// removable, a row to add one. A name and value typed in the last row are added on Return,
/// with Add, or when the list goes away (a sheet's Done).
struct ConfigKeyValueList: View {
    let path: [String]
    var keyPrompt = "Name"
    var valuePrompt = "Value"
    @Environment(AppModel.self) private var app
    @State private var newKey = ""
    @State private var newValue = ""

    /// The names' column, the same in every row so the values line up.
    static let keyWidth: CGFloat = 210

    var body: some View {
        let items = (app.engineConfig.value(at: path)?.object ?? [:]).compactMapValues(\.string).sorted { $0.key < $1.key }
        ForEach(items, id: \.key) { item in
            KeyValueRow(key: item.key, value: item.value, prompt: valuePrompt) { value in
                app.engineConfig.set(.string(value), at: path + [item.key])
            } remove: {
                app.engineConfig.set(nil, at: path + [item.key])
            }
        }
        HStack {
            TextField(keyPrompt, text: $newKey, prompt: Text(keyPrompt))
                .labelsHidden()
                .fontDesign(.monospaced)
                .frame(width: Self.keyWidth)
                .onSubmit(add)
            TextField(valuePrompt, text: $newValue, prompt: Text(valuePrompt))
                .labelsHidden()
                .onSubmit(add)
            Button("Add", action: add)
                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onDisappear(perform: add)
    }

    private func add() {
        let key = newKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        app.engineConfig.set(.string(newValue), at: path + [key])
        newKey = ""
        newValue = ""
    }
}

/// One name and its value. The value is saved when you press Return or leave the field. Values
/// are often secrets, so one that isn't a reference to an environment variable ({env:NAME})
/// shows as dots until you click into it.
private struct KeyValueRow: View {
    let key: String
    let value: String
    let prompt: String
    let change: (String) -> Void
    let remove: () -> Void
    @State private var field = SettingField()
    @FocusState private var isFocused: Bool

    private var isMasked: Bool {
        !isFocused && !field.text.isEmpty && !field.text.hasPrefix("{env:")
    }

    var body: some View {
        HStack {
            Text(key)
                .fontDesign(.monospaced)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(key)
                .frame(width: ConfigKeyValueList.keyWidth, alignment: .leading)
            TextField(prompt, text: Binding(
                get: { isMasked ? "••••••••" : field.text },
                set: { if !isMasked { field.text = $0 } }
            ), prompt: Text(prompt))
            .labelsHidden()
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { if !isFocused { commit() } }
            .onAppear { field.load(value) }
            .onChange(of: value) { if !isFocused { field.load(value) } }
            .onDisappear(perform: commit)
            Button {
                // Drop what was typed first, so going away doesn't save it back.
                field.load(value)
                remove()
            } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(RemoveButtonStyle())
            .help("Remove")
        }
    }

    private func commit() {
        guard let edited = field.edit(trimming: false) else { return }
        change(edited)
    }
}

/// When the settings file can't be used: why, and a way to open it.
struct ConfigProblem: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let problem = app.engineConfig.problem {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The engine's settings file can't be changed here")
                        Text(problem).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                HStack {
                    Button("Open Settings File") { NSWorkspace.shared.open(app.engineConfig.file) }
                    Button("Try Again") { app.engineConfig.reload() }
                }
            }
        }
    }
}

/// A page of settings: a grouped form on the page's card, lined up with its title, that
/// opens at its top. (Shown, a form can land elsewhere, under the toolbar or at its end, so it's
/// taken to its top edge once it's laid out.)
struct ScrollingSettingsForm<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var position = ScrollPosition(edge: .top)

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .scrollPosition($position)
            .onAppear {
                Task {
                    await Task.yield()
                    position.scrollTo(edge: .top)
                }
            }
    }
}

/// Signing in to something from a Settings page (an MCP server, a web search service), in the
/// page's place: the same steps as in Accounts, under the service's mark, with the page's way
/// back as the way out.
struct ConnectDetail: View {
    let integrationID: String
    var name: String? = nil
    var symbol: String? = nil
    /// What the last step says the connection gives you.
    var note = "Its models are now in the model picker."
    var highlights: [ConnectView.Highlight] = []
    let done: () -> Void

    var body: some View {
        ConnectView(integrationID: integrationID, name: name, symbol: symbol, connectedNote: note, highlights: highlights, onDone: done)
    }
}

/// The engine's MCP servers and how each is doing, for a page that shows them (MCP Servers,
/// Integrations): read again a moment after the settings change, as the engine picks up the
/// file, and every few seconds while it's open, as servers connect in their own time.
struct LiveMCPServers<Change: Equatable>: ViewModifier {
    @Binding var servers: [MCPServer]
    /// The engine as it is each time (it restarts to take a new key).
    let api: () -> OpenCodeAPI?
    /// What, changing, means the engine's settings did.
    let change: Change

    func body(content: Content) -> some View {
        content
            .task(id: change) { servers = await MCPStatus.read(api()) ?? [] }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    if let read = try? await api()?.mcpServers() { servers = read }
                }
            }
    }

}

enum MCPStatus {
    /// The engine's MCP servers, after a moment for it to pick up a change to its settings.
    static func read(_ api: OpenCodeAPI?) async -> [MCPServer]? {
        try? await Task.sleep(for: .milliseconds(400))
        return try? await api?.mcpServers()
    }
}

/// The buttons along the bottom of an editor a Settings page opens in its place (an agent, a
/// command, an MCP server, a provider). Making one: Cancel and the button that makes it. Editing
/// one, which is saved as you go: Done, the way back; and its Remove or Delete at the leading edge.
struct SettingsEditorButtons: View {
    /// What makes a new one ("Create Agent"); nil while editing one.
    let create: String?
    var canCreate = true
    var onCreate: () -> Void = {}
    /// Deletes the one being edited ("Delete Agent…"), when it can be.
    var remove: String?
    var onRemove: () -> Void = {}
    let done: () -> Void

    var body: some View {
        EditorFooter(primary: create ?? "Done", canDoPrimary: create == nil || canCreate, onPrimary: create == nil ? done : onCreate, onCancel: create == nil ? nil : done) {
            if create == nil, let remove {
                EditorFooterRemove(title: remove, action: onRemove)
            }
        }
    }
}

/// An integration, by its ID, for a sign-in; with what you know it as, when that's another name.
struct IntegrationRef: Identifiable {
    let id: String
    var service: Integrations.Service? = nil
}

/// A search field as a row of a settings group: a magnifying glass, the text, and a clear button.
struct SettingsSearchRow: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .labelsHidden()
                .multilineTextAlignment(.leading)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(ClearFieldButtonStyle())
                .help("Clear")
            }
        }
    }
}
