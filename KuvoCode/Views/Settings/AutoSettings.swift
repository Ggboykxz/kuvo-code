import OpenCodeKit
import SwiftUI

/// Auto: your lists of models (any coding agent's or provider's, each with its effort), one for
/// bugfixes, one for features, each to go through in order when one reaches a usage limit. A
/// session on Auto runs each message on the first of its list that isn't held back, and goes on
/// with the next, with what was done, when one reaches its limit partway.
struct AutoSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(Catalog.self) private var catalog
    @State private var failure: String?
    @State private var isClearing = false
    /// Names as you type them, by list, saved once you're done with one.
    @State private var names: [String: String] = [:]
    @FocusState private var naming: String?

    private var agents: OutsideAgents { app.agents }
    private var lists: [AutoList.Named] { agents.auto.all }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollingSettingsForm {
                if agents.api == nil {
                    Section {
                        Text(agents.failure.map { "Custom Auto runs with the coding agents, which couldn't start: \($0)" } ?? "Custom Auto runs with the coding agents, which are still starting.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(lists) { list in
                        listSection(list)
                    }
                    Section {
                        HStack {
                            Button { newList() } label: {
                                Label("New List", systemImage: "plus")
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .hoverHighlight(in: Capsule(), mutesInk: true)
                            }
                            .buttonStyle(.plain)
                            .clickablePointer()
                            Spacer()
                        }
                    } footer: {
                        Text("When one reaches a limit on your whole account (a plan's 5-hour window), Custom Auto skips all of that account's models, in every list; when one model reaches its own limit, only that model. Each comes back once its limit resets.")
                    }
                }
                if !agents.auto.limits.isEmpty {
                    Section {
                        LabeledContent {
                            Button("Try All Again") { clearLimits() }
                                .disabled(isClearing)
                        } label: {
                            Text("Held back at a limit")
                            Text("If a limit has reset sooner than its agent said, Custom Auto can try them all again.")
                        }
                    }
                }
            }
            // The list picked to edit (or just made) in view, a new one's name ready to type.
            .onChange(of: agents.autoFocus, initial: true) { _, focus in
                guard let focus else { return }
                Task {
                    for _ in 0..<20 where !lists.contains(where: { $0.id == focus }) { try? await Task.sleep(for: .milliseconds(100)) }
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation(.ui) { proxy.scrollTo(focus, anchor: .top) }
                    if lists.first(where: { $0.id == focus })?.entries.isEmpty == true { naming = focus }
                    agents.autoFocus = nil
                }
            }
        }
        .task { await agents.loadAuto() }
        .onChange(of: naming) { old, _ in
            if let old { rename(old) }
        }
        .alert("Couldn't Save Custom Auto", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    /// One list: its name (typed in place), its models in order, a way to add one, and a menu to
    /// move or delete it.
    private func listSection(_ list: AutoList.Named) -> some View {
        Section {
            if list.entries.isEmpty {
                Text("Add the models to go through, in the order you want them. Pick this list in a session's model picker to use it.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(list.entries.enumerated()), id: \.element.id) { index, entry in
                AutoEntryRow(
                    index: index,
                    count: list.entries.count,
                    entry: entry,
                    limit: agents.auto.limits.first { $0.holds(entry) },
                    replace: { ref in change(list.id) { $0[index] = AutoEntry(ref) } },
                    move: { offset in change(list.id) { $0.swapAt(index, index + offset) } },
                    remove: { change(list.id) { $0.remove(at: index) } }
                )
            }
            HStack {
                ModelChip(selection: nil, onSelect: { ref in change(list.id) { $0.append(AutoEntry(ref)) } }, scope: .all, offersAuto: false) { _, _ in
                    Label("Add Model", systemImage: "plus")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .hoverHighlight(in: Capsule(), mutesInk: true)
                }
                Spacer()
            }
        } header: {
            HStack(spacing: 8) {
                TextField("Name", text: Binding(get: { names[list.id] ?? list.name }, set: { names[list.id] = $0 }))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .font(.system(size: 13, weight: .semibold))
                    .focused($naming, equals: list.id)
                    .onSubmit { naming = nil }
                    .help("Its name, as the model picker shows it")
                Menu {
                    let index = lists.firstIndex { $0.id == list.id } ?? 0
                    Button("Move Up") { moveList(list.id, by: -1) }
                        .disabled(index == 0)
                    Button("Move Down") { moveList(list.id, by: 1) }
                        .disabled(index == lists.count - 1)
                    Divider()
                    Button("Delete List", role: .destructive) { deleteList(list.id) }
                        .disabled(lists.count == 1)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
            .id(list.id)
        }
    }

    /// One list's models, changed, saved.
    private func change(_ id: String, _ edit: (inout [AutoEntry]) -> Void) {
        save { lists in
            guard let index = lists.firstIndex(where: { $0.id == id }) else { return }
            var entries = lists[index].entries
            edit(&entries)
            // The same model at the same effort twice would only be tried once.
            var seen = Set<String>()
            lists[index].entries = entries.filter { seen.insert($0.id).inserted }
        }
    }

    private func rename(_ id: String) {
        guard let typed = names.removeValue(forKey: id)?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty else { return }
        save { lists in
            if let index = lists.firstIndex(where: { $0.id == id }), lists[index].name != typed { lists[index].name = typed }
        }
    }

    private func newList() {
        let list = AutoList.Named(id: "auto-" + UUID().uuidString.prefix(8).lowercased(), name: "New List", entries: [])
        agents.autoFocus = list.id
        save { $0.append(list) }
    }

    private func moveList(_ id: String, by offset: Int) {
        save { lists in
            guard let index = lists.firstIndex(where: { $0.id == id }), lists.indices.contains(index + offset) else { return }
            lists.swapAt(index, index + offset)
        }
    }

    private func deleteList(_ id: String) {
        save { lists in
            guard lists.count > 1 else { return }
            lists.removeAll { $0.id == id }
        }
    }

    /// Your lists, changed, saved.
    private func save(_ edit: (inout [AutoList.Named]) -> Void) {
        var all = lists
        let before = all
        edit(&all)
        guard all != before else { return }
        Task {
            do { try await agents.saveAuto(all) } catch { failure = error.localizedDescription }
        }
    }

    private func clearLimits() {
        isClearing = true
        Task {
            defer { isClearing = false }
            do { try await agents.clearAutoLimits() } catch { failure = error.localizedDescription }
        }
    }
}

/// One model in your list: its place, the model and its effort (which open the picker to change
/// them), whether it's held back and until when, and a menu to move or remove it.
private struct AutoEntryRow: View {
    let index: Int
    let count: Int
    let entry: AutoEntry
    let limit: AutoLimit?
    let replace: (ModelRef) -> Void
    let move: (Int) -> Void
    let remove: () -> Void
    @Environment(Catalog.self) private var catalog

    private var model: Model? { catalog.model(entry.ref) }

    /// Why Auto passes it by now, if it does.
    private var status: String? {
        if let limit {
            let when = limit.resets.formatted(Calendar.current.isDateInToday(limit.resets) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute())
            let until = limit.known ? "until \(when)" : "for now (until about \(when))"
            return limit.isWholeAccount ? "Its account is at its limit \(until)" : "At its limit \(until)"
        }
        if catalog.isLoaded, catalog.offeredModel(entry.ref) == nil {
            // Its account signed in but the model gone, or the account signed out.
            let signedIn = catalog.integrations.first { $0.id == entry.providerID }?.isConnected ?? false
            return OutsideAgents.isAgent(entry.providerID) && !signedIn ? "Not signed in: Custom Auto passes it by" : "Not available now: Custom Auto passes it by"
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .trailing)
            ModelChip(selection: entry.ref, onSelect: replace, scope: .all, offersAuto: false) { _, _ in
                HStack(spacing: 8) {
                    ProviderLogo(id: model?.makerLogoID ?? OutsideAgents.logo(entry.providerID), size: 16)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(model?.name ?? entry.modelID)
                                .lineLimit(1)
                            if let variant = entry.variant {
                                Text(EffortLevel.title(variant))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(catalog.providerName(entry.providerID))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .hoverHighlight(in: RoundedRectangle(cornerRadius: 8))
            }
            .help("Change the model or its effort")
            Spacer(minLength: 8)
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(limit == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
            Menu {
                Button("Move Up") { move(-1) }
                    .disabled(index == 0)
                Button("Move Down") { move(1) }
                    .disabled(index == count - 1)
                Divider()
                Button("Remove", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .opacity(status == nil ? 1 : 0.75)
    }
}
