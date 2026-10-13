import AppKit
import OpenCodeKit
import SwiftUI

/// How much the agent may do without asking, for a session.
enum ToolApproval: String, CaseIterable {
    /// The engine's defaults: tools run without asking (reading secrets like .env still asks).
    case approveAll
    /// Edits, writes, shell commands and web fetches wait for an OK.
    case askFirst

    static let key = "toolApproval"

    var title: String {
        switch self {
        case .approveAll: "Approve All"
        case .askFirst: "Ask First"
        }
    }

    var detail: String {
        switch self {
        case .approveAll: "Runs tools without asking"
        case .askFirst: "Asks before editing files or running commands"
        }
    }

    /// The session rules that give this behaviour.
    var rules: [PermissionRule] {
        switch self {
        case .approveAll: []
        case .askFirst: ["edit", "write", "patch", "shell", "webfetch", "external_directory"].map { PermissionRule(action: $0, effect: .ask) }
        }
    }

    init(rules: [PermissionRule]?) {
        self = (rules ?? []).contains { $0.action == "shell" && $0.effect == .ask } ? .askFirst : .approveAll
    }
}

/// "Build ⌄": the mode (agent) and how much it may do on its own.
struct ModeChip: View {
    @Environment(Catalog.self) private var catalog
    let agent: String
    let approval: ToolApproval
    let onSelectAgent: (String) -> Void
    let onSelectApproval: (ToolApproval) -> Void

    var body: some View {
        NativeMenuButton(name: "mode", menu: makeMenu) {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(agent))
                Text(agent.capitalized)
                if approval == .askFirst {
                    Image(systemName: "hand.raised.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(agent == "plan" ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .hoverHighlight(in: Capsule())
        }
        .help("Mode and tool permissions (⌥⌘1 Build, ⌥⌘2 Plan)")
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "Mode"))
        for agent in catalog.primaryAgents {
            menu.addItem(ActionItem(agent.name.capitalized, subtitle: Self.detail(agent), image: NSImage(systemSymbolName: Self.symbol(agent.id), accessibilityDescription: nil), checked: agent.id == self.agent) {
                onSelectAgent(agent.id)
            })
        }
        menu.addItem(.separator())
        let approvals = NSMenu()
        for option in ToolApproval.allCases {
            approvals.addItem(ActionItem(option.title, subtitle: option.detail, checked: option == approval) { onSelectApproval(option) })
        }
        menu.addItem(.chained("Tool Permissions", value: approval.title, image: NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: nil), submenu: approvals))
        return menu
    }

    static func symbol(_ agent: String) -> String {
        switch agent {
        case "build": "hammer"
        case "plan": "list.bullet.clipboard"
        default: "person.crop.circle"
        }
    }

    /// Short, plain descriptions for the built-in modes; custom agents bring their own.
    static func detail(_ agent: Agent) -> String? {
        switch agent.id {
        case "build": "Makes changes and runs commands"
        case "plan": "Explores and plans, without changing files"
        default: agent.description.map { String($0.prefix(60)) }
        }
    }
}

/// "GPT-6 Luna · High ⌄": the model, its effort, and the context it has.
struct ModelChip: View {
    @Environment(Catalog.self) private var catalog
    let selection: ModelRef?
    let onSelect: (ModelRef) -> Void
    @AppStorage("recentModels") private var recentStorage = ""

    private var current: Model? { catalog.model(selection) ?? catalog.defaultModel }
    private var variant: String? { current.flatMap { model in selection?.sameModel(as: model.ref) == true ? selection?.variant : nil } }

    var body: some View {
        NativeMenuButton(name: "model", menu: makeMenu) {
            HStack(spacing: 6) {
                if let current {
                    ProviderLogo(id: current.makerLogoID, size: 14)
                }
                Text(current?.name ?? "Choose a Model")
                    .lineLimit(1)
                if let variant {
                    Text("· \(variant.capitalized)")
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .hoverHighlight(in: Capsule())
        }
        .help("Model and effort")
        .onAppear { LogoImages.shared.prefetch(catalog.models.flatMap { [$0.makerLogoID, $0.providerID] }) }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let logos = LogoImages.shared

        // Model › a short list, then everything by provider.
        let models = NSMenu()
        for model in shortList {
            models.addItem(item(for: model, logos: logos))
        }
        let groups = catalog.modelsByProvider
        if !groups.isEmpty {
            models.addItem(.separator())
            let more = NSMenu()
            if groups.count == 1 {
                for model in groups[0].models { more.addItem(item(for: model, logos: logos)) }
            } else {
                for group in groups {
                    let providerMenu = NSMenu()
                    for model in group.models { providerMenu.addItem(item(for: model, logos: logos)) }
                    let providerID = group.models.first?.providerID ?? ""
                    let row = NSMenuItem.chained(group.provider, value: "\(group.models.count)", image: logos.menuImage(providerID), submenu: providerMenu)
                    more.addItem(row)
                }
            }
            models.addItem(.chained("More Models", value: nil, submenu: more))
        }
        menu.addItem(.chained("Model", value: current?.name ?? "None", image: current.flatMap { logos.menuImage($0.makerLogoID) }, submenu: models))

        // Effort ›, for models that have levels.
        if let current, !current.variants.isEmpty {
            let efforts = NSMenu()
            efforts.addItem(ActionItem("Default", checked: variant == nil) {
                onSelect(ModelRef(id: current.id, providerID: current.providerID))
            })
            for level in current.variants {
                efforts.addItem(ActionItem(level.id.capitalized, checked: variant == level.id) {
                    onSelect(ModelRef(id: current.id, providerID: current.providerID, variant: level.id))
                })
            }
            menu.addItem(.chained("Effort", value: variant?.capitalized ?? "Default", image: NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: nil), submenu: efforts))
        }

        if let current {
            menu.addItem(.separator())
            menu.addItem(.info("Context Window", value: current.limit.context.compactTokens))
        }
        return menu
    }

    private func item(for model: Model, logos: LogoImages) -> NSMenuItem {
        // "Free" only for OpenCode Zen's free models; a $0 subscription model isn't free.
        let free = model.providerID == "opencode" && model.isFree
        let detail = [catalog.providerName(model.providerID), free ? "Free" : nil].compactMap { $0 }.joined(separator: " · ")
        return ActionItem(model.name, subtitle: detail.isEmpty ? nil : detail, image: logos.menuImage(model.makerLogoID), checked: model.ref.sameModel(as: current?.ref)) {
            remember(model)
            onSelect(model.ref)
        }
    }

    /// The current model, then recently used ones, then the newest model of each
    /// family (Claude Opus, GPT Sol, Gemini Flash, …) from each provider, accounts
    /// you connected before the free OpenCode Zen models.
    private var shortList: [Model] {
        let enabled = catalog.models.filter(\.enabled)
        let recent = recentStorage.split(separator: ",").compactMap { key in enabled.first { $0.key == key } }
        var newestByFamily: [String: Model] = [:]
        for model in enabled {
            let family = model.providerID + "/" + (model.family ?? model.id)
            if let existing = newestByFamily[family], existing.time.released >= model.time.released { continue }
            newestByFamily[family] = model
        }
        let perProvider = Dictionary(grouping: newestByFamily.values, by: \.providerID)
            .mapValues { Array($0.sorted { $0.time.released > $1.time.released }.prefix(4)) }
        let providers = perProvider.keys.sorted { lhs, rhs in
            // Free models last: someone who connected an account wants its models first.
            (lhs == "opencode" ? 1 : 0, Catalog.featuredOrder[lhs] ?? 99, lhs) < (rhs == "opencode" ? 1 : 0, Catalog.featuredOrder[rhs] ?? 99, rhs)
        }
        var seen = Set<String>()
        let candidates = [current].compactMap { $0 } + recent + providers.flatMap { perProvider[$0] ?? [] }
        return candidates.filter { seen.insert($0.key).inserted }.prefix(10).map { $0 }
    }

    private func remember(_ model: Model) {
        var keys = recentStorage.split(separator: ",").map(String.init).filter { $0 != model.key }
        keys.insert(model.key, at: 0)
        recentStorage = keys.prefix(4).joined(separator: ",")
    }
}

extension Model {
    /// The logo of who made the model, so a Claude model served through Copilot
    /// still shows Anthropic's mark. Falls back to the provider's logo.
    var makerLogoID: String {
        let family = (family ?? id).lowercased()
        let prefixes: [(String, String)] = [
            ("claude", "anthropic"), ("gpt", "openai"), ("o1", "openai"), ("o3", "openai"), ("o4", "openai"), ("codex", "openai"),
            ("gemini", "google"), ("gemma", "google"), ("grok", "xai"), ("kimi", "moonshotai"), ("deepseek", "deepseek"),
            ("mistral", "mistral"), ("codestral", "mistral"), ("devstral", "mistral"), ("llama", "meta"), ("glm", "zhipuai"), ("minimax", "minimax"),
        ]
        return prefixes.first { family.hasPrefix($0.0) }?.1 ?? providerID
    }
}
