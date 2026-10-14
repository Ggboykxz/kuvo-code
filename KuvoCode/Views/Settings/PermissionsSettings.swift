import OpenCodeKit
import SwiftUI

/// What the agent may do without asking: a choice for each kind of action, rules for
/// particular commands or files, approvals saved with "Always", and blocks nothing overrides.
struct PermissionsSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(Workspace.self) private var workspace
    @State private var saved: [SavedPermission] = []

    private var config: EngineConfig { app.engineConfig }
    private static let path = ["permissions"]

    /// The kinds of action, with what they cover; each is a rule for every resource ("*").
    static let actions: [(id: String, title: String, detail: String)] = [
        ("edit", "Edit files", "Changing, creating or deleting files."),
        ("shell", "Run commands", "In the terminal."),
        ("read", "Read files", "Files ending in .env ask first unless you allow this."),
        ("external_directory", "Work outside the project", "In folders that aren't the project's. Asks by default."),
        ("webfetch", "Open web pages", ""),
        ("websearch", "Search the web", ""),
        ("subagent", "Hand work to subagents", ""),
        ("skill", "Use skills", ""),
    ]

    var body: some View {
        ScrollingSettingsForm {
            Section {
                ForEach(Self.actions, id: \.id) { action in
                    Picker(selection: effect(for: action.id)) {
                        Text("Default").tag(PermissionRule.Effect?.none)
                        Text("Allow").tag(Optional(PermissionRule.Effect.allow))
                        Text("Ask First").tag(Optional(PermissionRule.Effect.ask))
                        Text("Don't Allow").tag(Optional(PermissionRule.Effect.deny))
                    } label: {
                        Text(action.title)
                        if !action.detail.isEmpty { Text(action.detail) }
                    }
                }
            } header: {
                Text("When the Agent Wants To")
            } footer: {
                Text("For every session and mode. These come after a mode's own rules, so Allow here also lets Plan mode do it. A session set to Ask First still asks.")
                    .foregroundStyle(.secondary)
            }

            ConfigProblem()

            Section {
                RulesEditor(path: Self.path, hiding: Set(Self.actions.map(\.id)))
            } header: {
                Text("Rules")
            } footer: {
                // Verbatim: as Markdown, the asterisks would turn part of the sentence into italics.
                Text(verbatim: "For particular commands, files or sites, like \"git push *\" or \"*.pem\". * matches anything. When rules overlap, the one lower in the list wins.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if saved.isEmpty {
                    Text("None yet. Choosing Always when the agent asks saves an approval here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(saved) { permission in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Self.title(of: permission.action)): \(permission.resource)")
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Text(projectName(permission.projectID))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task {
                                try? await app.api?.removeSavedPermission(permission.id)
                                await loadSaved()
                            }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(RemoveButtonStyle())
                        .help("Remove")
                    }
                }
            } header: {
                Text("Always Allowed")
            }

            Section {
                RulesEditor(path: ["policies"], actions: Self.policyKinds, effects: [.deny, .allow], prompt: "Like shell:git push *, openrouter or mcp:github", allowsAnything: false)
            } header: {
                Text("Blocks")
            } footer: {
                Text(verbatim: "Blocks win over everything else, including approvals. Block a tool or command as \"shell:git push *\", a provider by its ID, or an MCP server, skill or plugin as \"mcp:name\", \"skill:name\" or \"plugin:name\".")
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            // Engine 2.0.29 moved blocks out of `experimental`; bring any set there along.
            let old = app.engineConfig.items(["experimental", "policies"])
            if !old.isEmpty {
                app.engineConfig.setItems(app.engineConfig.items(["policies"]) + old, at: ["policies"])
                app.engineConfig.set(nil, at: ["experimental", "policies"])
            }
            await loadSaved()
        }
    }

    static let policyKinds: [(id: String, title: String)] = [
        ("tool.use", "Tool or command"),
        ("provider.use", "Provider"),
        ("integration.use", "MCP server, skill or plugin"),
    ]

    private func loadSaved() async {
        saved = (try? await app.api?.savedPermissions()) ?? []
    }

    private func projectName(_ id: String) -> String {
        workspace.sessions.first { $0.projectID == id }.map { workspace.projectName($0.location.directory) } ?? "A project"
    }

    static func title(of action: String) -> String {
        actions.first { $0.id == action }?.title ?? action
    }

    /// The rule for every resource of `action`, kept at the front so specific rules win.
    private func effect(for action: String) -> Binding<PermissionRule.Effect?> {
        Binding {
            config.items(Self.path).compactMap(\.rule).last { $0.action == action && $0.resource == "*" }?.effect
        } set: { effect in
            // Only the rule this sets; the rest, including any written by hand, stay as they are.
            var items = config.items(Self.path).filter { $0.rule.map { !($0.action == action && $0.resource == "*") } ?? true }
            if let effect { items.insert(PermissionRule(action: action, resource: "*", effect: effect).json, at: 0) }
            config.setItems(items, at: Self.path)
        }
    }
}

extension PermissionRule {
    var json: JSONValue {
        .object(["action": .string(action), "resource": .string(resource), "effect": .string(effect.rawValue)])
    }
}

extension JSONValue {
    /// This item of a rules list as a rule, if it is one.
    var rule: PermissionRule? { try? decode(as: PermissionRule.self) }
}

/// An ordered list of `{action, resource, effect}` rules at a path in the settings, each
/// editable in place, with a button to add one. Rules for actions in `hiding`, for everything
/// ("*"), are left out: they have their own controls. Items that aren't rules (written by
/// hand) are kept where they are.
struct RulesEditor: View {
    let path: [String]
    var actions: [(id: String, title: String)] = PermissionsSettings.actions.map { ($0.id, $0.title) }
    var effects: [PermissionRule.Effect] = [.allow, .ask, .deny]
    var hiding: Set<String> = []
    var prompt = "Pattern, like git push *"
    /// Whether an empty pattern means everything ("*"); a block for everything would stop
    /// every tool, so there it stays as it was.
    var allowsAnything = true
    @Environment(AppModel.self) private var app
    /// A rule being added: shown under the others, and saved only once it has a pattern, so a
    /// half-made rule never changes what the agent may do.
    @State private var draft: PermissionRule?

    var body: some View {
        let items = app.engineConfig.items(path)
        let shown = items.indices.filter { index in
            guard let rule = items[index].rule else { return false }
            return !(hiding.contains(rule.action) && rule.resource == "*")
        }
        if shown.isEmpty, draft == nil {
            Text("None yet.")
                .foregroundStyle(.secondary)
        }
        ForEach(shown, id: \.self) { index in
            if let rule = items[index].rule {
                RuleRow(rule: rule, actions: actions, effects: effects, prompt: prompt, allowsAnything: allowsAnything) { changed in
                    var items = app.engineConfig.items(path)
                    guard items.indices.contains(index) else { return }
                    if let changed { items[index] = changed.json } else { items.remove(at: index) }
                    app.engineConfig.setItems(items, at: path)
                }
            }
        }
        if let draft {
            // An empty pattern keeps it a draft here, rather than meaning everything.
            RuleRow(rule: draft, actions: actions, effects: effects, prompt: prompt, allowsAnything: false, focusesOnAppear: true) { changed in
                // Already saved or removed (the row commits again as it goes away).
                guard self.draft != nil else { return }
                guard let changed else {
                    self.draft = nil
                    return
                }
                if changed.resource.isEmpty {
                    self.draft = changed
                } else {
                    app.engineConfig.setItems(app.engineConfig.items(path) + [changed.json], at: path)
                    self.draft = nil
                }
            }
        }
        Button("Add Rule") {
            draft = PermissionRule(action: actions.first?.id ?? "shell", resource: "", effect: effects.first ?? .ask)
        }
        .disabled(draft != nil)
    }
}

/// One rule: what kind of action, which (a pattern), and what happens.
private struct RuleRow: View {
    let rule: PermissionRule
    let actions: [(id: String, title: String)]
    let effects: [PermissionRule.Effect]
    let prompt: String
    let allowsAnything: Bool
    /// For a rule just added: its pattern is what to fill in next.
    var focusesOnAppear = false
    /// The rule as changed, or nil to remove it.
    let change: (PermissionRule?) -> Void
    @State private var resource = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            // A fixed width that long titles truncate in, so the patterns line up.
            Picker("Action", selection: Binding(get: { rule.action }, set: { change(PermissionRule(action: $0, resource: rule.resource, effect: rule.effect)) })) {
                ForEach(actions, id: \.id) { Text($0.title).tag($0.id) }
                if !actions.contains(where: { $0.id == rule.action }) { Text(rule.action).tag(rule.action) }
            }
            .labelsHidden()
            .frame(width: 190, alignment: .leading)
            TextField("Pattern", text: $resource, prompt: Text(prompt))
                .labelsHidden()
                .focused($isFocused)
                .onSubmit(commit)
                .onChange(of: isFocused) { if !isFocused { commit() } }
            Picker("Effect", selection: Binding(get: { rule.effect }, set: { change(PermissionRule(action: rule.action, resource: rule.resource, effect: $0)) })) {
                ForEach(effects, id: \.self) { Text(Self.title(of: $0)).tag($0) }
            }
            .labelsHidden()
            .frame(width: 120)
            Button {
                // Drop what was typed first, so going away doesn't save it back.
                resource = rule.resource
                change(nil)
            } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(RemoveButtonStyle())
            .help("Remove Rule")
        }
        .onAppear {
            resource = rule.resource
            if focusesOnAppear { isFocused = true }
        }
        .onChange(of: rule.resource) { resource = rule.resource }
        // Closing the sheet or switching tabs while typing keeps what you typed.
        .onDisappear(perform: commit)
    }

    private func commit() {
        var value = resource.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            guard allowsAnything else {
                resource = rule.resource
                return
            }
            value = "*"
        }
        guard value != rule.resource else { return }
        change(PermissionRule(action: rule.action, resource: value, effect: rule.effect))
    }

    static func title(of effect: PermissionRule.Effect) -> String {
        switch effect {
        case .allow: "Allow"
        case .ask: "Ask First"
        case .deny: "Don't Allow"
        }
    }
}
