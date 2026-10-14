import OpenCodeKit
import SwiftUI

/// Skills: instructions and scripts the agent loads when a task calls for them. The ones it
/// has, each can be turned off; popular collections on GitHub to add more from; other folders
/// and catalogs to read them from.
struct SkillsSettings: View {
    @Environment(AppModel.self) private var app
    @State private var skills: [Skill] = []
    @State private var installed: [String: SkillLibrary.Source] = [:]
    @State private var browsing: SkillLibrary.Repository?
    @State private var repositoryName = ""
    @State private var failure: String?

    private var config: EngineConfig { app.engineConfig }
    private var folder: URL { app.skillsFolder }

    var body: some View {
        ScrollingSettingsForm {
            Section {
                if skills.isEmpty {
                    Text("Loading…").foregroundStyle(.secondary)
                }
                ForEach(skills) { skill in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(skill.name)
                                Text(source(of: skill))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let description = skill.description {
                                Text(description)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        if installed[skill.id] != nil {
                            Button("Remove") { remove(skill.id) }
                        }
                        Toggle("Use \(skill.name)", isOn: isOn(skill.id))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("Skills the Agent Can Use")
            } footer: {
                Text("The agent loads a skill when a task calls for it. Skills in ~/.claude/skills and ~/.agents/skills, and in a project's .opencode/skills, are found on their own.")
                    .foregroundStyle(.secondary)
            }
            .settingsTop()

            ConfigProblem()

            Section {
                ForEach(SkillLibrary.repositories) { repository in
                    Button {
                        browsing = repository
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(repository.title)
                                    Text(repository.id)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(repository.summary)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                HStack {
                    TextField("Repository", text: $repositoryName, prompt: Text("Another repository on GitHub, like owner/skills"))
                        .labelsHidden()
                        .onSubmit(openRepository)
                    Button("Open", action: openRepository)
                        .disabled(repositoryName.isEmpty)
                }
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
            } header: {
                Text("Get Skills")
            } footer: {
                Text("These come from their authors on GitHub, not from Kuvo Code. A skill can include scripts the agent may run, so look at what's in one before you add it.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ConfigStringList(path: ["skills"], prompt: "A folder, or the address of a skill catalog")
            } header: {
                Text("Other Places")
            } footer: {
                Text("A catalog is a web address with an index.json listing its skills.")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: config.settings) { await refresh() }
        .sheet(item: $browsing) { repository in
            RepositorySkills(repository: repository, folder: folder) {
                Task { await refresh() }
            } done: {
                browsing = nil
            }
        }
    }

    private func refresh() async {
        installed = SkillLibrary.installed(in: folder)
        // The engine notices a new folder within a moment.
        try? await Task.sleep(for: .milliseconds(500))
        skills = ((try? await app.api?.skills()) ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func source(of skill: Skill) -> String {
        if let source = installed[skill.id] { return source.repository }
        guard let path = skill.path else { return "" }
        if path.hasPrefix("/builtin/") { return "Built in" }
        if path.hasPrefix(folder.path + "/") { return "Added here" }
        return (path as NSString).abbreviatingWithTildeInPath
            .components(separatedBy: "/").dropLast(2).joined(separator: "/")
    }

    /// Off is a rule that denies the skill; turning it on takes that rule out, and leaves any
    /// other rule for it alone.
    private func isOn(_ id: String) -> Binding<Bool> {
        Binding {
            !config.items(["permissions"]).compactMap(\.rule).contains { $0.action == "skill" && $0.resource == id && $0.effect == .deny }
        } set: { on in
            var items = config.items(["permissions"]).filter { item in
                guard let rule = item.rule else { return true }
                return !(rule.action == "skill" && rule.resource == id && rule.effect == .deny)
            }
            if !on { items.append(PermissionRule(action: "skill", resource: id, effect: .deny).json) }
            config.setItems(items, at: ["permissions"])
        }
    }

    private func remove(_ id: String) {
        try? FileManager.default.trashItem(at: folder.appending(path: id), resultingItemURL: nil)
        Task { await refresh() }
    }

    private func openRepository() {
        let name = repositoryName
        failure = nil
        Task {
            do {
                browsing = try await SkillLibrary.repository(named: name)
                repositoryName = ""
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// A repository's skills, each with what it says it does, to add or remove.
private struct RepositorySkills: View {
    let repository: SkillLibrary.Repository
    let folder: URL
    let changed: () -> Void
    let done: () -> Void
    @State private var skills: [SkillLibrary.RemoteSkill]?
    @State private var isPartial = false
    @State private var installed: [String: SkillLibrary.Source] = [:]
    @State private var query = ""
    /// Why the list couldn't be loaded.
    @State private var failure: String?
    /// Why a skill couldn't be added: the list stays.
    @State private var installFailure: String?
    @State private var confirming: SkillLibrary.RemoteSkill?
    @State private var working: String?

    private var shown: [SkillLibrary.RemoteSkill] {
        guard let skills else { return [] }
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty ? skills : skills.filter { $0.path.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(repository.title).font(.headline)
                Link(repository.id, destination: repository.webURL).font(.callout)
            }
            .padding(.top, 16)
            .padding(.bottom, 8)
            TextField("Filter", text: $query, prompt: Text("Filter skills"))
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)
            Group {
                if let failure {
                    ContentUnavailableView("Couldn't Load the Skills", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else if skills == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if shown.isEmpty {
                    ContentUnavailableView("No Skills", systemImage: "magnifyingglass")
                } else {
                    List {
                        ForEach(shown) { skill in
                            RemoteSkillRow(skill: skill, installed: installed[skill.name], isWorking: working == skill.id) {
                                confirming = skill
                            } remove: {
                                try? FileManager.default.trashItem(at: folder.appending(path: skill.name), resultingItemURL: nil)
                                reload()
                            }
                        }
                        if isPartial {
                            Text("This collection is too big for GitHub to list in full, so some of its skills aren't here.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 600, height: 600)
        .task {
            reload()
            do {
                let listing = try await SkillLibrary.skills(in: repository)
                skills = listing.skills
                isPartial = listing.isPartial
            } catch {
                failure = error.localizedDescription
            }
        }
        .alert("Couldn't Add the Skill", isPresented: Binding(get: { installFailure != nil }, set: { if !$0 { installFailure = nil } })) {
            Button("OK") {}
        } message: {
            Text(installFailure ?? "")
        }
        .confirmationDialog("Add \(confirming?.name ?? "")?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { skill in
            Button("Add Skill") { install(skill) }
            Button("Cancel", role: .cancel) {}
        } message: { skill in
            Text(Self.summary(of: skill))
        }
    }

    /// Its files, saying so when some are scripts.
    static func summary(of skill: SkillLibrary.RemoteSkill) -> String {
        let names = skill.files.map { String($0.dropFirst(skill.path.count + 1)) }
        let scripts = names.filter { ["sh", "py", "js", "ts", "rb", "pl", "bash", "zsh"].contains(($0 as NSString).pathExtension.lowercased()) }
        var lines = names.prefix(12).map { "• " + $0 }
        if names.count > 12 { lines.append("and \(names.count - 12) more") }
        let note = scripts.isEmpty ? "" : "\n\nIt has \(scripts.count == 1 ? "a script" : "\(scripts.count) scripts") the agent may run."
        return "From \(skill.repository.id):\n\n" + lines.joined(separator: "\n") + note
    }

    private func reload() {
        installed = SkillLibrary.installed(in: folder)
        changed()
    }

    private func install(_ skill: SkillLibrary.RemoteSkill) {
        working = skill.id
        Task {
            defer { working = nil }
            do {
                try await SkillLibrary.install(skill, into: folder)
                reload()
            } catch {
                installFailure = error.localizedDescription
            }
        }
    }
}

private struct RemoteSkillRow: View {
    let skill: SkillLibrary.RemoteSkill
    /// The skill installed under this one's name, from wherever it came.
    let installed: SkillLibrary.Source?
    let isWorking: Bool
    let add: () -> Void
    let remove: () -> Void
    @State private var about: SkillLibrary.About?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(about?.name ?? skill.name)
                Text(about?.description ?? " ")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer()
            if isWorking {
                ProgressView().controlSize(.small)
            } else if let installed {
                if installed.repository == skill.repository.id, installed.path == skill.path {
                    Button("Remove", action: remove)
                } else {
                    // Another skill by this name is installed (they'd share a folder).
                    Text("\(skill.name) from \(installed.repository) is added")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Add", action: add)
            }
        }
        .padding(.vertical, 4)
        .task { about = await SkillLibrary.about(skill) }
    }
}
