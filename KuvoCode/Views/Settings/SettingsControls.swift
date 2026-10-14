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
    @Environment(AppModel.self) private var app
    @State private var field = SettingField()
    @FocusState private var isFocused: Bool

    var body: some View {
        let stored = app.engineConfig.value(at: path)?.string ?? ""
        TextField(title, text: $field.text, prompt: Text(prompt))
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

/// Longer text, like an agent's instructions: saved when you leave it.
struct ConfigTextEditor: View {
    let path: [String]
    var minHeight: CGFloat = 120
    @Environment(AppModel.self) private var app
    @State private var field = SettingField()
    @FocusState private var isFocused: Bool

    var body: some View {
        let stored = app.engineConfig.value(at: path)?.string ?? ""
        TextEditor(text: $field.text)
            .font(.body)
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
            // One set by hand that the catalog doesn't have.
            if let current = app.engineConfig.value(at: path)?.string,
               !catalog.models.contains(where: { "\($0.providerID)/\($0.id)" == current }) {
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
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
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

/// Names and values (environment variables, headers): each removable, a row to add one.
struct ConfigKeyValueList: View {
    let path: [String]
    var keyPrompt = "Name"
    var valuePrompt = "Value"
    @Environment(AppModel.self) private var app
    @State private var newKey = ""
    @State private var newValue = ""

    var body: some View {
        let items = (app.engineConfig.value(at: path)?.object ?? [:]).compactMapValues(\.string).sorted { $0.key < $1.key }
        ForEach(items, id: \.key) { item in
            HStack {
                Text(item.key)
                    .fontDesign(.monospaced)
                Spacer()
                Text(item.value)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Button {
                    app.engineConfig.set(nil, at: path + [item.key])
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        HStack {
            TextField(keyPrompt, text: $newKey, prompt: Text(keyPrompt))
                .labelsHidden()
                .fontDesign(.monospaced)
            TextField(valuePrompt, text: $newValue, prompt: Text(valuePrompt))
                .labelsHidden()
                .onSubmit(add)
            Button("Add", action: add)
                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func add() {
        let key = newKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        app.engineConfig.set(.string(newValue), at: path + [key])
        newKey = ""
        newValue = ""
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

/// A tab of settings too long for the window: a grouped form that scrolls. Mark its first
/// section with `settingsTop()`: a form that scrolls opens with its first rows under the
/// window's toolbar, so it's scrolled to that section once it's shown.
struct ScrollingSettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollViewReader { proxy in
            Form { content }
                .formStyle(.grouped)
                .frame(width: SettingsView.width, height: 620)
                .onAppear {
                    Task {
                        await Task.yield()
                        proxy.scrollTo(settingsTopID, anchor: .top)
                    }
                }
        }
    }
}

private let settingsTopID = "settings-top"

extension View {
    /// The first section of a `ScrollingSettingsForm`.
    func settingsTop() -> some View { id(settingsTopID) }
}

/// Signing in to something from Settings (an MCP server, a web search service): the same
/// steps as in Accounts, in a sheet.
struct ConnectSheet: View {
    let integrationID: String
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ConnectView(integrationID: integrationID, onDone: done)
            HStack {
                Spacer()
                Button("Close", action: done)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 560)
    }
}

/// An integration, by its ID, for a sheet.
struct IntegrationRef: Identifiable {
    let id: String
}
