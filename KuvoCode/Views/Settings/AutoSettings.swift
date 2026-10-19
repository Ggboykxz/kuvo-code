import OpenCodeKit
import SwiftUI

/// Auto: your own order of models (any coding agent's or provider's, each with its effort) to go
/// through when one reaches a usage limit. A session on Auto runs each message on the first one
/// that isn't held back, and goes on with the next, with what was done, when one reaches its limit
/// partway.
struct AutoSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(Catalog.self) private var catalog
    @State private var failure: String?
    @State private var isClearing = false

    private var agents: OutsideAgents { app.agents }
    private var list: AutoList { agents.auto }

    var body: some View {
        ScrollingSettingsForm {
            Section {
                if agents.api == nil {
                    Text(agents.failure.map { "Auto runs with the coding agents, which couldn't start: \($0)" } ?? "Auto runs with the coding agents, which are still starting.")
                        .foregroundStyle(.secondary)
                } else {
                    if list.entries.isEmpty {
                        Text("Add the models to go through, in the order you want them. Pick Auto in a new session's model picker to use it.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(list.entries.enumerated()), id: \.element.id) { index, entry in
                        AutoEntryRow(
                            index: index,
                            count: list.entries.count,
                            entry: entry,
                            limit: list.limits.first { $0.holds(entry) },
                            replace: { ref in change { $0[index] = AutoEntry(ref) } },
                            move: { offset in change { $0.swapAt(index, index + offset) } },
                            remove: { change { $0.remove(at: index) } }
                        )
                    }
                    HStack {
                        ModelChip(selection: nil, onSelect: { ref in change { $0.append(AutoEntry(ref)) } }, scope: .all, offersAuto: false) { _, _ in
                            Label("Add Model", systemImage: "plus")
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .hoverHighlight(in: Capsule(), mutesInk: true)
                        }
                        Spacer()
                    }
                }
            } header: {
                Text("Your Order")
            } footer: {
                Text("When one reaches a limit on your whole account (a plan's 5-hour window), Auto skips all of that account's models; when one model reaches its own limit, only that model. Each comes back once its limit resets.")
            }
            if !list.limits.isEmpty {
                Section {
                    LabeledContent {
                        Button("Try All Again") { clearLimits() }
                            .disabled(isClearing)
                    } label: {
                        Text("Held back at a limit")
                        Text("If a limit has reset sooner than its agent said, Auto can try them all again.")
                    }
                }
            }
        }
        .task { await agents.loadAuto() }
        .alert("Couldn't Save Your Auto List", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    /// Your list, changed, saved.
    private func change(_ edit: (inout [AutoEntry]) -> Void) {
        var entries = list.entries
        edit(&entries)
        // The same model at the same effort twice would only be tried once.
        var seen = Set<String>()
        entries = entries.filter { seen.insert($0.id).inserted }
        Task {
            do { try await agents.saveAuto(entries) } catch { failure = error.localizedDescription }
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
            return OutsideAgents.isAgent(entry.providerID) && !signedIn ? "Not signed in: Auto passes it by" : "Not available now: Auto passes it by"
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
