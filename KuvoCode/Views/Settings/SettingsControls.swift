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

    func strings(_ path: [String]) -> [String] {
        value(at: path)?.array?.compactMap(\.string) ?? []
    }

    func setStrings(_ values: [String], at path: [String]) {
        set(values.isEmpty ? nil : .array(values.map(JSONValue.string)), at: path)
    }
}

/// A text setting, saved when you press Return or leave the field.
struct ConfigTextField: View {
    let title: String
    let path: [String]
    var prompt = ""
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { if !isFocused { commit() } }
            .onAppear { text = app.engineConfig.value(at: path)?.string ?? "" }
            .onDisappear(perform: commit)
    }

    private func commit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != (app.engineConfig.value(at: path)?.string ?? "") else { return }
        app.engineConfig.set(value.isEmpty ? nil : .string(value), at: path)
    }
}

/// A whole-number setting; empty means the engine's default.
struct ConfigNumberField: View {
    let title: String
    let path: [String]
    var prompt = "Default"
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .multilineTextAlignment(.trailing)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { if !isFocused { commit() } }
            .onAppear { text = app.engineConfig.value(at: path)?.int.map(String.init) ?? "" }
            .onDisappear(perform: commit)
    }

    private func commit() {
        let value = Int(text.filter(\.isNumber))
        text = value.map(String.init) ?? ""
        guard value != app.engineConfig.value(at: path)?.int else { return }
        app.engineConfig.set(value.map { .number(Double($0)) }, at: path)
    }
}

/// Longer text, like an agent's instructions: saved when you leave it.
struct ConfigTextEditor: View {
    let path: [String]
    var minHeight: CGFloat = 120
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .frame(minHeight: minHeight)
            .focused($isFocused)
            .onChange(of: isFocused) { if !isFocused { commit() } }
            .onAppear { text = app.engineConfig.value(at: path)?.string ?? "" }
            .onDisappear(perform: commit)
    }

    private func commit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != (app.engineConfig.value(at: path)?.string ?? "") else { return }
        app.engineConfig.set(value.isEmpty ? nil : .string(value), at: path)
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

/// A list of strings (paths, patterns, packages): each removable, a field to add one.
struct ConfigStringList: View {
    let path: [String]
    let prompt: String
    @Environment(AppModel.self) private var app
    @State private var newItem = ""

    var body: some View {
        let items = app.engineConfig.strings(path)
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            HStack {
                Text(item)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    var items = items
                    items.remove(at: index)
                    app.engineConfig.setStrings(items, at: path)
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
                guard !item.isEmpty, !items.contains(item) else { return }
                app.engineConfig.setStrings(items + [item], at: path)
                newItem = ""
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
