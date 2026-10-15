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
            }
            .font(.callout)
            .foregroundStyle(agent == "plan" ? AnyShapeStyle(.orange) : AnyShapeStyle(.foreground))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .hoverHighlight(in: Capsule(), mutesInk: true)
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

/// "Local ⌄" or "Worktree ⌄", for a new session: whether it works in the project's folder or
/// in a git worktree of its own, on a branch of its own.
struct WorkplaceChip: View {
    let worktree: Bool
    /// How many sessions try the task, each in a worktree of its own.
    var attempts = 1
    let onSelect: (Bool) -> Void
    var onSelectAttempts: (Int) -> Void = { _ in }

    var body: some View {
        NativeMenuButton(name: "workplace", menu: makeMenu) {
            HStack(spacing: 6) {
                Image(systemName: worktree ? "arrow.triangle.branch" : "folder")
                Text(worktree ? (attempts > 1 ? "Worktree ×\(attempts)" : "Worktree") : "Local")
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .hoverHighlight(in: Capsule(), mutesInk: true)
        }
        .help("Where the session works: in the project's folder, or in a worktree of its own")
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionItem("Local", subtitle: "Works in the project's folder", image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil), checked: !worktree) {
            onSelect(false)
        })
        menu.addItem(ActionItem("Worktree", subtitle: "Works in a copy on a branch of its own", image: NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil), checked: worktree) {
            onSelect(true)
        })
        menu.addItem(.separator())
        let counts = NSMenu()
        for count in 1...4 {
            counts.addItem(ActionItem(count == 1 ? "1 Session" : "\(count) Sessions", subtitle: count == 1 ? nil : "Each tries it in a worktree of its own", checked: worktree && count == attempts) {
                onSelect(true)
                onSelectAttempts(count)
            })
        }
        menu.addItem(.chained("Attempts", value: worktree ? "\(attempts)" : nil, image: NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil), submenu: counts))
        return menu
    }
}

/// "GPT-6 Luna · High ⌄": the model and its effort. It opens the model picker, which stays open
/// while you choose both. Elsewhere (a bot's default model) the same picker opens from a label of
/// its own.
struct ModelChip<Label: View>: View {
    @Environment(Catalog.self) private var catalog
    let selection: ModelRef?
    let onSelect: (ModelRef) -> Void
    var opensBelow = false
    /// Drawn with the model in use and its effort.
    @ViewBuilder let label: (Model?, String?) -> Label
    @State private var isOpen = false
    @State private var startsExpanded = false

    private var current: Model? { catalog.model(selection) ?? catalog.defaultModel }
    private var variant: String? { current.flatMap { model in selection?.sameModel(as: model.ref) == true ? selection?.variant : nil } }

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            label(current, variant)
        }
        .buttonStyle(.plain)
        .help("Model and effort")
        .popover(isPresented: $isOpen, arrowEdge: opensBelow ? .bottom : .top) {
            ModelPicker(catalog: catalog, selection: selection, onSelect: onSelect, close: { isOpen = false }, startsExpanded: startsExpanded)
        }
        .onAppear { LogoImages.shared.prefetch(catalog.models.flatMap { [$0.makerLogoID, $0.providerID] }) }
        #if DEBUG
        .task {
            // KUVO_DEMO_MENU=model opens the picker after launch; =models, with every model shown.
            guard let wanted = ProcessInfo.processInfo.environment["KUVO_DEMO_MENU"], wanted == "model" || wanted == "models" else { return }
            try? await Task.sleep(for: .seconds(3))
            startsExpanded = wanted == "models"
            isOpen = true
            // KUVO_DEMO_EFFORT=<level>: with it set, as if picked.
            if let level = ProcessInfo.processInfo.environment["KUVO_DEMO_EFFORT"], let current {
                onSelect(ModelRef(id: current.id, providerID: current.providerID, variant: level))
            }
        }
        #endif
    }
}

extension ModelChip where Label == ModelChipLabel {
    init(selection: ModelRef?, onSelect: @escaping (ModelRef) -> Void) {
        self.init(selection: selection, onSelect: onSelect) { ModelChipLabel(model: $0, variant: $1) }
    }
}

/// The composer's chip: the maker's logo, the model's name and its effort.
struct ModelChipLabel: View {
    let model: Model?
    let variant: String?

    var body: some View {
        HStack(spacing: 6) {
            if let model {
                ProviderLogo(id: model.makerLogoID, size: 14)
            }
            Text(model?.name ?? "Choose a Model")
                .lineLimit(1)
            if let variant {
                Text("· \(EffortLevel.title(variant))")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .hoverHighlight(in: Capsule(), mutesInk: true)
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
