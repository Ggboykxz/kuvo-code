import OpenCodeKit
import SwiftUI

/// Accounts, a page of Settings: what's connected, the popular providers, and every other one
/// the engine knows. The list comes from the engine, so it grows without app updates. Signing
/// in to a provider, or setting up one of your own, opens in the page's place.
struct ProvidersView: View {
    @Environment(Catalog.self) private var catalog
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.settingsInset) private var inset
    @State private var connecting: Integration?
    /// One of your own providers, open in the page's place.
    @State private var editing: ProviderEdit?
    /// What to remove once its editor has closed (and its fields are done saving).
    @State private var removal: [String]?
    @State private var search = ""

    var body: some View {
        list
            // The page's way back is the way out, so no Cancel in the steps.
            .settingsDetail(item: $connecting, title: { _ in nil }) { integration in
                ConnectView(integrationID: integration.id, onDone: {
                    withAnimation(.ui) { connecting = nil }
                })
            }
            .settingsDetail(item: $editing, title: { _ in "New Provider" }, onDismiss: removePending) { edit in
                CustomProviderEditor(id: edit.providerID) { editing = nil } remove: { path in
                    removal = path
                    editing = nil
                }
            }
        #if DEBUG
        .task {
            if let id = ProcessInfo.processInfo.environment["KUVO_DEMO_PROVIDERS"], let provider = catalog.providers.first(where: { $0.id == id }) {
                connecting = provider
            }
        }
        #endif
    }

    private func removePending() {
        guard let removal else { return }
        app.engineConfig.set(nil, at: removal)
        self.removal = nil
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                SearchField(text: $search, prompt: "Search \(catalog.providers.count) providers")

                if search.isEmpty, !catalog.connectedProviders.isEmpty {
                    section("Connected") {
                        VStack(spacing: 0) {
                            ForEach(catalog.connectedProviders) { provider in
                                ConnectedRow(provider: provider) { connecting = provider }
                                if provider.id != catalog.connectedProviders.last?.id {
                                    Divider().padding(.leading, 56)
                                }
                            }
                        }
                        .background(Surface.cardFill(scheme, focused: false), in: .rect(cornerRadius: Metrics.cardRadius))
                        .specularRim(RoundedRectangle(cornerRadius: Metrics.cardRadius))
                    }
                }

                if search.isEmpty, !featured.isEmpty {
                    section("Popular") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                            ForEach(featured) { provider in
                                ProviderTile(provider: provider) { connecting = provider }
                            }
                        }
                    }
                }

                if search.isEmpty {
                    CustomProvidersSection { connecting = $0 } edit: { id in editing = ProviderEdit(id: id) }
                }

                if others.isEmpty, !search.isEmpty {
                    ContentUnavailableView {
                        Label("No Results for “\(search.trimmingCharacters(in: .whitespaces))”", systemImage: "magnifyingglass")
                    } description: {
                        Text("Check the spelling, or search for the company that makes the model.")
                    } actions: {
                        Button("Clear Search") { search = "" }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                } else {
                    section(search.isEmpty ? "All Providers" : "Results") {
                        LazyVStack(spacing: 0) {
                            ForEach(others) { provider in
                                ProviderRow(provider: provider) { connecting = provider }
                            }
                        }
                        .padding(4)
                        .background(Surface.cardFill(scheme, focused: false), in: .rect(cornerRadius: Metrics.cardRadius))
                        .specularRim(RoundedRectangle(cornerRadius: Metrics.cardRadius))
                    }
                }
            }
            // Lined up with the page's title above it.
            .padding(.horizontal, inset)
            .padding(.vertical, 16)
        }
    }

    private var featured: [Integration] {
        Catalog.featured.compactMap { id in catalog.providers.first { $0.id == id && !$0.isConnected } }
    }

    private var others: [Integration] {
        let query = search.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            // Your own are listed in their own section.
            let shown = Set(Catalog.featured).union(app.engineConfig.value(at: CustomProvidersSection.path)?.object?.keys ?? [:].keys)
            return catalog.providers.filter { !shown.contains($0.id) && !$0.isConnected }
        }
        return catalog.providers.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
    }
}

/// A rounded search field that lives in the content, not in a toolbar: a recessed well with no
/// outline, a touch deeper while you type. Also filters the skills in Settings.
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
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
        .font(.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        // Sunken, like the sidebar's search, with no outline; a touch deeper while you type.
        .background((scheme == .dark ? Color.black : Surface.slate).opacity(isFocused ? 0.05 : 0), in: .rect(cornerRadius: 10))
        .background(Surface.well(scheme), in: .rect(cornerRadius: 10))
        .contentShape(.rect)
        .onTapGesture { isFocused = true }
    }
}

/// A big, inviting tile for the providers most people use, with an explicit Connect button.
private struct ProviderTile: View {
    let provider: Integration
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            ProviderLogo(id: provider.id, size: 20)
                .frame(width: 36, height: 36)
                .background(Surface.well(scheme), in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Connect", action: action)
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(12)
        .background(Surface.cardFill(scheme, focused: false), in: .rect(cornerRadius: Metrics.cardRadius))
        .specularRim(RoundedRectangle(cornerRadius: Metrics.cardRadius))
        // Under the pointer, an accent edge: the whole tile connects.
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cardRadius)
                .strokeBorder(.tint, lineWidth: 1.5)
                .opacity(isHovering ? 1 : 0)
        }
        .contentShape(.rect)
        .onTapGesture(perform: action)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering } }
        .pointerStyle(.link)
    }

    /// The headline way in: "Sign in with ChatGPT", "Sign in", "API key".
    /// ("Login with" is the engine's wording for some; one wording reads better side by side.)
    private var hint: String {
        for method in provider.signInMethods {
            if case .oauth(_, let label, _) = method, !label.localizedCaseInsensitiveContains("legacy") {
                // Under the provider's name, its name again ("OpenCode Console account") says nothing.
                if label.localizedCaseInsensitiveContains(provider.name) { return "Sign in" }
                return label.replacingOccurrences(of: "Login with", with: "Sign in with")
            }
        }
        return provider.signInMethods.contains { $0.id == "key" } ? "API key" : "Connect"
    }
}

/// A row in the full list; the whole row is the button, and it highlights under the pointer.
private struct ProviderRow: View {
    let provider: Integration
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ProviderLogo(id: provider.id, size: 18)
                    .frame(width: 28)
                Text(provider.name)
                Spacer()
                if provider.isConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.callout)
                        .foregroundStyle(.green)
                } else {
                    Text("Connect")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(isHovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isHovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct ConnectedRow: View {
    let provider: Integration
    let addAccount: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 12) {
            ProviderLogo(id: provider.id, size: 22)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(needsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            Spacer()
            Button("Add Account", action: addAccount)
                .buttonStyle(.glass)
            if provider.connections.contains(where: { $0.type == "credential" }) {
                Button("Disconnect", role: .destructive, action: disconnect)
                    .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var active: Integration.Connection? { provider.connections.first }

    private var needsAttention: Bool { active?.status?.status == "needs_auth" }

    private var detail: String {
        guard let active else { return "" }
        if let status = active.status { return status.message }
        switch active.type {
        case "env": return "From \(active.name ?? "the environment")"
        default:
            let kind = active.method == "oauth" ? "Signed in" : active.method == "key" ? "API key" : "Connected"
            let count = provider.connections.count
            return count > 1 ? "\(kind) · \(count) accounts" : kind
        }
    }

    private func disconnect() {
        guard let api = app.api else { return }
        let ids = provider.connections.filter { $0.type == "credential" }.compactMap(\.credentialID)
        Task {
            for id in ids { try? await api.removeCredential(id) }
        }
    }
}
