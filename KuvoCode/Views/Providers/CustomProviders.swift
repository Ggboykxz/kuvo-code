import OpenCodeKit
import SwiftUI

/// Providers you add yourself: a company proxy, a self-hosted server, any service that speaks
/// OpenAI's or Anthropic's API. Each is set up in the engine's settings file; its key is added
/// like any other provider's, so it never goes in the file.
struct CustomProvidersSection: View {
    /// Opens a provider's sign-in, to add its key.
    let connect: (Integration) -> Void
    @Environment(AppModel.self) private var app
    @Environment(Catalog.self) private var catalog
    @State private var editing: ProviderEdit?
    /// What to remove once its sheet has closed (and its fields are done saving).
    @State private var removal: [String]?

    static let path = ["providers"]

    private var ids: [String] { (app.engineConfig.value(at: Self.path)?.object?.keys).map { $0.sorted() } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your Own").font(.headline)
                Spacer()
                Button("Add a Provider…") { editing = ProviderEdit(id: nil) }
            }
            if ids.isEmpty {
                Text("For a company proxy, a self-hosted server or any service with an OpenAI- or Anthropic-compatible API.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(ids, id: \.self) { id in
                        let integration = catalog.providers.first { $0.id == id }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.engineConfig.value(at: Self.path + [id, "name"])?.string ?? id)
                                Text(app.engineConfig.value(at: Self.path + [id, "settings", "baseURL"])?.string ?? "No address yet")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if let integration {
                                Button(integration.isConnected ? "Key Added" : "Add Key") { connect(integration) }
                                    .disabled(integration.isConnected)
                            }
                            Button("Edit…") { editing = ProviderEdit(id: id) }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        if id != ids.last { Divider().padding(.leading, 14) }
                    }
                }
                .background(.background, in: .rect(cornerRadius: Metrics.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(.separator))
            }
        }
        .sheet(item: $editing, onDismiss: removePending) { edit in
            CustomProviderEditor(id: edit.providerID) { editing = nil } remove: { path in
                removal = path
                editing = nil
            }
        }
    }

    private func removePending() {
        guard let removal else { return }
        app.engineConfig.set(nil, at: removal)
        self.removal = nil
    }
}

private struct ProviderEdit: Identifiable {
    /// Nil for a new one.
    var providerID: String?

    init(id: String?) { providerID = id }

    var id: String { providerID ?? "new" }
}

/// One provider's settings. A new one is named first; after that, changes are saved as you
/// make them.
private struct CustomProviderEditor: View {
    @State var id: String?
    let done: () -> Void
    /// Removes this entry, once the sheet has closed.
    let remove: ([String]) -> Void
    @Environment(AppModel.self) private var app
    @Environment(Catalog.self) private var catalog
    @State private var name = ""
    @State private var newModel = ""
    @State private var problem: String?
    @State private var confirmsRemoval = false

    private var config: EngineConfig { app.engineConfig }

    /// Which of the engine's built-in API kinds it speaks.
    static let kinds: [(package: String, title: String)] = [
        ("@opencode/ai/providers/openai-compatible", "OpenAI-compatible (Chat Completions)"),
        ("@opencode/ai/providers/openai-compatible/responses", "OpenAI-compatible (Responses)"),
        ("@opencode/ai/providers/anthropic-compatible", "Anthropic-compatible (Messages)"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Text(id.flatMap { config.value(at: CustomProvidersSection.path + [$0, "name"])?.string } ?? "New Provider")
                .font(.headline)
                .padding(.top, 16)
            if let id {
                editor(id)
            } else {
                Form {
                    TextField("Name", text: $name, prompt: Text("Like My Company or Local Server"))
                        .onSubmit(create)
                    if let problem {
                        Text(problem).foregroundStyle(.red)
                    }
                }
                .formStyle(.grouped)
            }
            HStack {
                if id != nil {
                    Button("Remove Provider…", role: .destructive) { confirmsRemoval = true }
                }
                Spacer()
                if id == nil {
                    Button("Cancel", action: done)
                    Button("Create", action: create)
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Button("Done", action: done)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 620, height: id == nil ? 220 : 620)
        .confirmationDialog("Remove this provider?", isPresented: $confirmsRemoval) {
            Button("Remove", role: .destructive) {
                remove(CustomProvidersSection.path + [id ?? ""])
            }
        } message: {
            Text("Its models go away from the model menu. Sessions that used them need another model.")
        }
    }

    @ViewBuilder private func editor(_ id: String) -> some View {
        let path = CustomProvidersSection.path + [id]
        Form {
            Section {
                ConfigTextField(title: "Name", path: path + ["name"], prompt: id)
                Picker("Speaks", selection: Binding(
                    get: { config.value(at: path + ["package"])?.string ?? Self.kinds[0].package },
                    set: { config.set(.string($0), at: path + ["package"]) }
                )) {
                    ForEach(Self.kinds, id: \.package) { Text($0.title).tag($0.package) }
                }
                ConfigTextField(title: "Address", path: path + ["settings", "baseURL"], prompt: "https://api.example.com/v1")
            } footer: {
                Text("Add its API key in Accounts once it's set up; it's kept with your other credentials, not in the settings file.")
                    .foregroundStyle(.secondary)
            }
            Section {
                let models = (config.value(at: path + ["models"])?.object?.keys).map { $0.sorted() } ?? []
                ForEach(models, id: \.self) { model in
                    HStack {
                        Text(model)
                            .fontDesign(.monospaced)
                            .frame(width: 170, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        ConfigTextField(title: "Name", path: path + ["models", model, "name"], prompt: "Name")
                            .labelsHidden()
                        ConfigNumberField(title: "Context", path: path + ["models", model, "limit", "context"], prompt: "Context")
                            .labelsHidden()
                            .frame(width: 90)
                        ConfigNumberField(title: "Output", path: path + ["models", model, "limit", "output"], prompt: "Output")
                            .labelsHidden()
                            .frame(width: 80)
                        Button {
                            config.set(nil, at: path + ["models", model])
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove Model")
                    }
                }
                HStack {
                    TextField("Model ID", text: $newModel, prompt: Text("A model's ID, as the service names it"))
                        .labelsHidden()
                        .onSubmit(addModel)
                    Button("Add", action: addModel)
                        .disabled(newModel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Models")
            } footer: {
                Text("Context and output are the most tokens a model takes in and writes; empty means 200,000 and 32,000.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ConfigKeyValueList(path: path + ["headers"], keyPrompt: "Header", valuePrompt: "Value")
            } header: {
                Text("Headers")
            } footer: {
                Text("Sent with every request, if the service needs more than a key. Write {env:NAME} to use an environment variable.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func create() {
        let title = name.trimmingCharacters(in: .whitespaces)
        let slug = title.lowercased().replacingOccurrences(of: " ", with: "-").filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !slug.isEmpty else { return }
        // Not one the engine already has: that would change it instead.
        guard config.value(at: CustomProvidersSection.path + [slug]) == nil, !catalog.providers.contains(where: { $0.id == slug }) else {
            problem = "There's already a provider called that."
            return
        }
        config.set(.object([
            "name": .string(title),
            "package": .string(Self.kinds[0].package),
            "models": .object([:]),
        ]), at: CustomProvidersSection.path + [slug])
        id = slug
    }

    private func addModel() {
        guard let id else { return }
        let model = newModel.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return }
        config.set(.object(["name": .string(model)]), at: CustomProvidersSection.path + [id, "models", model])
        newModel = ""
    }
}
