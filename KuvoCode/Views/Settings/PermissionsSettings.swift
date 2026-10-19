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
                ActionChoices(path: Self.path)
            } header: {
                Text("When the Agent Wants To")
            } footer: {
                Text("For every session and mode, so Allow here also lets Plan mode do it. A session set to Approve All does what's set to Ask First here without asking, and one set to Ask First still asks; Don't Allow holds for all of them.")
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
                RulesEditor(path: ["policies"], actions: Self.policyKinds, effects: [.deny, .allow], prompt: "Like shell:git push *, openrouter or mcp:github")
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
        // Sessions' rules hold these too (see ToolApproval.rules(settings:)): open ones follow now.
        .onChange(of: app.engineConfig.settings["permissions"]) { workspace.syncPermissions() }
    }

    static let policyKinds: [(id: String, title: String)] = [
        ("tool.use", "Tool or command"),
        ("provider.use", "Provider"),
        ("integration.use", "MCP server, skill or plugin"),
    ]

    private func loadSaved() async {
        guard let api = app.api else { return saved = [] }
        // The engine lists one project's at a time: the folders outside any, then each project's.
        var found = (try? await api.savedPermissions()) ?? []
        for project in Set(workspace.sessions.map(\.projectID)).sorted() {
            for permission in (try? await api.savedPermissions(projectID: project)) ?? [] where !found.contains(where: { $0.id == permission.id }) {
                found.append(permission)
            }
        }
        saved = found
    }

    private func projectName(_ id: String) -> String {
        workspace.sessions.first { $0.projectID == id }.map { workspace.projectName($0.location.directory) } ?? "A project"
    }

    static func title(of action: String) -> String {
        actions.first { $0.id == action }?.title ?? action
    }
}

/// A choice for each kind of action (Default, Allow, Ask First, Don't Allow): a rule for every
/// resource ("*") in the rules list at `path`, kept at its front so rules for particular
/// commands or files, after it, win.
struct ActionChoices: View {
    let path: [String]
    @Environment(AppModel.self) private var app
    @Environment(\.editedConfig) private var edited

    private var config: EngineConfig { edited ?? app.engineConfig }

    var body: some View {
        ForEach(PermissionsSettings.actions, id: \.id) { action in
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
    }

    private func effect(for action: String) -> Binding<PermissionRule.Effect?> {
        Binding {
            config.items(path).compactMap(\.rule).last { $0.action == action && $0.resource == "*" }?.effect
        } set: { effect in
            // Only the rule this sets; the rest, including any written by hand, stay as they are.
            var items = config.items(path).filter { $0.rule.map { !($0.action == action && $0.resource == "*") } ?? true }
            if let effect { items.insert(PermissionRule(action: action, resource: "*", effect: effect).json, at: 0) }
            config.setItems(items, at: path)
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
/// ("*"), are left out: they have their own controls (`ActionChoices`). Items that aren't rules
/// (written by hand) are kept where they are.
///
/// Every rule here is for particular commands, files or sites, so each needs a pattern: a new one
/// is saved once it has one (as you type, in a draft; else on Return, on leaving it, or with the
/// page), and a pattern can't be emptied.
struct RulesEditor: View {
    let path: [String]
    var actions: [(id: String, title: String)] = PermissionsSettings.actions.map { ($0.id, $0.title) }
    var effects: [PermissionRule.Effect] = [.allow, .ask, .deny]
    var hiding: Set<String> = []
    /// What a new rule's pattern field says while it's empty; nil for the action's own example.
    var prompt: String?
    @Environment(AppModel.self) private var app
    @Environment(\.editedConfig) private var edited
    /// A rule being added, under the others, until it has a pattern: a half-made rule never
    /// changes what the agent may do.
    @State private var draft: PermissionRule?
    /// Goes up to put the cursor in the new rule's pattern.
    @State private var draftFocus = 0

    private var config: EngineConfig { edited ?? app.engineConfig }

    var body: some View {
        let items = config.items(path)
        let shown = items.indices.filter { index in
            guard let rule = items[index].rule else { return false }
            return !(hiding.contains(rule.action) && rule.resource == "*")
        }
        // The new rule's row has the place the rule takes once it's saved (the end of the list),
        // so it stays the same row, with the cursor in it, as it's saved.
        let rows = shown.map { (id: $0, rule: items[$0].rule!, isDraft: false) } + (draft.map { [(id: items.count, rule: $0, isDraft: true)] } ?? [])
        Group {
            if rows.isEmpty {
                Text("None yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.id) { row in
                RuleRow(rule: row.rule, actions: actions, effects: effects, prompt: prompt ?? Self.example(for: row.rule.action),
                        focusRequest: row.isDraft ? draftFocus : 0) { changed in
                    row.isDraft ? changeDraft(changed) : change(row.id, to: changed)
                } typed: { text in
                    if row.isDraft, var rule = draft {
                        rule.resource = text
                        draft = rule
                        if config.isDraft { saveDraft(trimming: false) }
                    } else if config.isDraft, !row.isDraft, !text.trimmingCharacters(in: .whitespaces).isEmpty, text != row.rule.resource {
                        // A draft keeps up with every key, for its Create.
                        change(row.id, to: PermissionRule(action: row.rule.action, resource: text, effect: row.rule.effect))
                    }
                }
            }
            Button("Add Rule", action: add)
                .onDisappear { saveDraft() }
        }
    }

    /// For the pattern field: what one looks like for this kind of action.
    static func example(for action: String) -> String {
        switch action {
        case "shell": "Like git push * or npm run *"
        case "edit", "read": "Like *.env or docs/*"
        case "external_directory": "Like ~/Downloads/*"
        default: "A pattern; * matches anything"
        }
    }

    private func change(_ index: Int, to changed: PermissionRule?) {
        var items = config.items(path)
        guard items.indices.contains(index) else { return }
        if let changed { items[index] = changed.json } else { items.remove(at: index) }
        config.setItems(items, at: path)
    }

    private func changeDraft(_ changed: PermissionRule?) {
        guard let changed else {
            draft = nil
            return
        }
        draft = changed
        saveDraft()
    }

    /// Saves the new rule, once it has a pattern. As it's typed, it's kept as it is (a space
    /// you just typed stays); otherwise without spaces around it.
    private func saveDraft(trimming: Bool = true) {
        guard var rule = draft else { return }
        if trimming { rule.resource = rule.resource.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !rule.resource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = nil
        config.setItems(config.items(path) + [rule.json], at: path)
    }

    /// Another rule: the one being added is saved first, if it has a pattern; if it hasn't, the
    /// cursor goes there, as that's what's missing.
    private func add() {
        saveDraft()
        if draft != nil {
            draftFocus += 1
            return
        }
        // Most rules are for commands ("git push *"), when there are some.
        let action = actions.contains { $0.id == "shell" } ? "shell" : actions.first?.id ?? "shell"
        draft = PermissionRule(action: action, resource: "", effect: effects.first ?? .ask)
        draftFocus += 1
    }
}

/// One rule: what kind of action, which (a pattern), and what happens.
private struct RuleRow: View {
    let rule: PermissionRule
    let actions: [(id: String, title: String)]
    let effects: [PermissionRule.Effect]
    let prompt: String
    /// Goes up to put the cursor in its pattern (a rule just added).
    var focusRequest = 0
    /// The rule as changed, or nil to remove it.
    let change: (PermissionRule?) -> Void
    /// Each change to the pattern as it's typed, before it's saved.
    let typed: (String) -> Void
    @State private var resource = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            // A fixed width that long titles truncate in, so the patterns line up.
            Picker("Action", selection: Binding(get: { rule.action }, set: { change(PermissionRule(action: $0, resource: resource, effect: rule.effect)) })) {
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
                .onChange(of: resource) { typed(resource) }
            Picker("Effect", selection: Binding(get: { rule.effect }, set: { change(PermissionRule(action: rule.action, resource: resource, effect: $0)) })) {
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
            if focusRequest > 0 { isFocused = true }
        }
        .onChange(of: rule.resource) { if rule.resource != resource { resource = rule.resource } }
        .onChange(of: focusRequest) { isFocused = true }
        // Closing the page or switching tabs while typing keeps what you typed.
        .onDisappear(perform: commit)
    }

    private func commit() {
        let value = resource.trimmingCharacters(in: .whitespacesAndNewlines)
        // A pattern can't be emptied: "everything" has its own choice, above the rules.
        guard !value.isEmpty else {
            if !rule.resource.isEmpty { resource = rule.resource }
            return
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
