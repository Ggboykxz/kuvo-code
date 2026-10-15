import OpenCodeKit
import SwiftUI

/// Settings: a sidebar of pages in groups, with a search field, on the window's glass, and the
/// open page in a card beside it, under its title, the way the main window shows a session.
struct SettingsView: View {
    /// Every sheet a page opens (an agent, a server, a command, a skill, a sign-in) is this
    /// wide, and this tall unless it's short.
    static let sheetWidth: CGFloat = 620
    static let sheetHeight: CGFloat = 600

    /// Which page is open; other places (the menu bar's "Accounts…", the browser) can set it.
    @AppStorage("settings.tab") private var tab = SettingsPage.general.rawValue
    @State private var search = ""
    @Environment(\.colorScheme) private var scheme

    private var page: SettingsPage { SettingsPage(rawValue: tab) ?? .general }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: Binding(get: { page }, set: { tab = $0.rawValue }), search: $search)
                .frame(width: 232)
            VStack(alignment: .leading, spacing: 0) {
                SettingsPageHeader(page: page)
                page.content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Surface.cardFill(scheme, focused: true), in: .rect(cornerRadius: Metrics.cardRadius))
            .clipShape(.rect(cornerRadius: Metrics.cardRadius))
            .specularRim(RoundedRectangle(cornerRadius: Metrics.cardRadius))
            .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.06), radius: 6, y: 1)
            .padding([.trailing, .bottom], Metrics.paneGap)
            .id(page)
        }
        .frame(minWidth: 860, idealWidth: 1040, minHeight: 600, idealHeight: 760)
        .windowGlass()
        .appLook()
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onAppear { Analytics.shared.track("settings_opened", ["tab": tab]) }
        .onChange(of: tab) { Analytics.shared.track("settings_opened", ["tab": tab]) }
    }
}

/// A page of Settings: where it sits in the sidebar, what it's called, and what it shows.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, notifications, shortcuts, privacy, storage
    case accounts, usage
    case agents, permissions, commands, skills, mcp, engine
    case git, worktrees, archived, machines
    case panel, browser, passwords

    var id: String { rawValue }

    enum Group: String, CaseIterable {
        case app = "Kuvo Code"
        case models = "Models"
        case agent = "Agent"
        case projects = "Projects"
        case panel = "Side Panel"
    }

    var group: Group {
        switch self {
        case .general, .appearance, .notifications, .shortcuts, .privacy, .storage: .app
        case .accounts, .usage: .models
        case .agents, .permissions, .commands, .skills, .mcp, .engine: .agent
        case .git, .worktrees, .archived, .machines: .projects
        case .panel, .browser, .passwords: .panel
        }
    }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .notifications: "Notifications"
        case .shortcuts: "Keyboard Shortcuts"
        case .privacy: "Privacy"
        case .storage: "Storage"
        case .accounts: "Accounts"
        case .usage: "Usage"
        case .agents: "Agents"
        case .permissions: "Permissions"
        case .commands: "Commands"
        case .skills: "Skills"
        case .mcp: "MCP Servers"
        case .engine: "Engine"
        case .git: "Git"
        case .worktrees: "Worktrees"
        case .archived: "Archived Sessions"
        case .machines: "Machines"
        case .panel: "Panel"
        case .browser: "Browser"
        case .passwords: "Passwords"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .notifications: "bell"
        case .shortcuts: "command"
        case .privacy: "hand.raised"
        case .storage: "internaldrive"
        case .accounts: "person.crop.circle"
        case .usage: "gauge.with.dots.needle.50percent"
        case .agents: "person.2"
        case .permissions: "checkmark.shield"
        case .commands: "slash.circle"
        case .skills: "graduationcap"
        case .mcp: "puzzlepiece.extension"
        case .engine: "cpu"
        case .git: "arrow.triangle.branch"
        case .worktrees: "square.stack.3d.up"
        case .archived: "archivebox"
        case .machines: "server.rack"
        case .panel: "sidebar.right"
        case .browser: "safari"
        case .passwords: "key"
        }
    }

    /// The line under the page's title.
    var subtitle: String? {
        switch self {
        case .general: nil
        case .appearance: "How Kuvo Code looks, and how conversations read."
        case .notifications: "What Kuvo Code tells you while you're in another app."
        case .shortcuts: "Every keyboard shortcut in Kuvo Code."
        case .privacy: "What Kuvo Code shares, and what stays on this Mac."
        case .storage: "What Kuvo Code keeps on this Mac, and room you can get back."
        case .accounts: "Sign in with a subscription you already have, or add an API key. Credentials stay on this Mac."
        case .usage: nil
        case .agents: "The agents you pick in the composer, and the subagents they hand work to."
        case .permissions: "What the agent may do without asking you first."
        case .commands: "Prompts you use often, run by typing / and their name."
        case .skills: "Instructions and scripts the agent loads when a task calls for them."
        case .mcp: "Programs and services that give the agent more tools."
        case .engine: nil
        case .git: "Branches, commits and pull requests made from Kuvo Code."
        case .worktrees: "Folders of their own for sessions that work on a branch."
        case .archived: "Sessions you put away: still searchable, out of the sidebar."
        case .machines: "Linux servers whose sessions run there, over SSH."
        case .panel: "What the side panel starts with, and its new tab page."
        case .browser: "The panel's browser: search, history and the sites that keep data."
        case .passwords: "Sign-ins the panel's browser saved, kept in your Keychain."
        }
    }

    /// More words search finds the page by.
    var keywords: String {
        switch self {
        case .general: "tab bar updates editor open files with startup"
        case .appearance: "dark light mode theme accent color font text size glass solid window"
        case .notifications: "alerts sound dock badge"
        case .shortcuts: "keys keyboard hotkeys"
        case .privacy: "analytics anonymous usage data"
        case .storage: "disk space size clean up delete old sessions logs cache"
        case .accounts: "providers sign in api key login models openai anthropic copilot"
        case .usage: "limits spend menu bar plan"
        case .agents: "modes build plan subagents default model title"
        case .permissions: "allow ask deny approve rules"
        case .commands: "slash prompts"
        case .skills: "skills github library"
        case .mcp: "servers tools model context protocol"
        case .engine: "opencode shell web search plugins summarize formatter limits settings file"
        case .git: "branch prefix commit message pull request pr"
        case .worktrees: "worktree branches folders"
        case .archived: "archive restore unarchive delete"
        case .machines: "remote ssh server vps linux"
        case .panel: "side panel new tab page tools suggestions"
        case .browser: "search engine history cookies website data sites"
        case .passwords: "logins sign in keychain autofill"
        }
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return "\(title) \(subtitle ?? "") \(keywords)".localizedCaseInsensitiveContains(query)
    }

    @MainActor @ViewBuilder var content: some View {
        switch self {
        case .general: GeneralSettings()
        case .appearance: AppearanceSettings()
        case .notifications: NotificationSettings()
        case .shortcuts: ShortcutsSettings()
        case .privacy: PrivacySettings()
        case .storage: StorageSettings()
        case .accounts: ProvidersView(context: .settings)
        case .usage: UsageSettings()
        case .agents: AgentsSettings()
        case .permissions: PermissionsSettings()
        case .commands: CommandsSettings()
        case .skills: SkillsSettings()
        case .mcp: MCPSettings()
        case .engine: EngineSettings()
        case .git: GitSettings()
        case .worktrees: WorktreesSettings()
        case .archived: ArchivedSessionsSettings()
        case .machines: MachinesSettings()
        case .panel: PanelSettingsView()
        case .browser: BrowserSettings()
        case .passwords: PasswordsSettings()
        }
    }
}

/// The pages, by group, with a search field that narrows them down.
private struct SettingsSidebar: View {
    @Binding var selection: SettingsPage
    @Binding var search: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SearchField(text: $search, prompt: "Search")
                .padding(.horizontal, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let pages = SettingsPage.allCases.filter { $0.matches(search) }
                    if pages.isEmpty {
                        Text("No Results")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                    ForEach(SettingsPage.Group.allCases, id: \.self) { group in
                        let members = pages.filter { $0.group == group }
                        if !members.isEmpty {
                            Text(group.rawValue)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, group == pages.first?.group ? 4 : 16)
                                .padding(.bottom, 4)
                            ForEach(members) { page in
                                Button {
                                    selection = page
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: page.symbol)
                                            .font(.system(size: 14))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 18)
                                        Text(page.title)
                                            .font(.system(size: 14))
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(height: 30)
                                    .modifier(RowHighlight(isSelected: page == selection))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            // Searching opens the first page it finds.
            .onChange(of: search) {
                let pages = SettingsPage.allCases.filter { $0.matches(search) }
                if !search.isEmpty, !pages.contains(selection), let first = pages.first { selection = first }
            }
        }
        .padding(.top, 4)
    }
}

/// A page's title, large, and the line under it.
private struct SettingsPageHeader: View {
    let page: SettingsPage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(page.title)
                .font(.system(size: 26, weight: .bold))
            if let subtitle = page.subtitle {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsMetrics.inset)
        .padding(.top, 26)
        .padding(.bottom, 4)
    }
}

enum SettingsMetrics {
    /// Where a page's title lines up with its groups' edges (a grouped form's own margin).
    static let inset: CGFloat = 49
}
