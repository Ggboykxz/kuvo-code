import OpenCodeKit
import SwiftUI

/// An open tab: a session, or a new one being written (`draft:<folder>`).
struct TabItem: Identifiable, Equatable {
    var id: String
    var title: String
    /// The model maker's logo (Anthropic, OpenAI, …) for the tab's front tile.
    var logo: String?
    var status: Status

    enum Status {
        case idle, working, waiting, failed, unread

        var help: String? {
            switch self {
            case .idle: nil
            case .working: "Working"
            case .waiting: "Waiting for you"
            case .failed: "The last run failed"
            case .unread: "Finished"
            }
        }
    }
}

/// Open sessions as tabs in one glass track; the active tab is a raised pill
/// that slides to whichever tab you pick.
struct TabStrip: View {
    let tabs: [TabItem]
    @Binding var selection: String?
    let close: (String) -> Void
    /// Closes every tab except the given one, or all of them when it's nil.
    let closeAll: (_ except: String?) -> Void
    /// Renames a session's tab (a new session's has no title to change yet).
    var rename: ((String) -> Void)?

    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                let isActive = tab.id == selection
                TabButton(tab: tab, isActive: isActive, close: { close(tab.id) }) {
                    withAnimation(.ui) { selection = tab.id }
                }
                .rightClickMenu { menu(for: tab) }
                .background {
                    if isActive {
                        ActivePill()
                            .matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
                // Hairlines between inactive neighbours, like Rex; none next to the pill.
                if index < tabs.count - 1, !isActive, tabs[index + 1].id != selection {
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1, height: 16)
                }
            }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
        .animation(.ui, value: tabs.map(\.id))
    }

    private func menu(for tab: TabItem) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let rename, SidebarView.draftDirectory(from: tab.id) == nil {
            items += [ActionItem("Rename…") { rename(tab.id) }, .separator()]
        }
        let others = ActionItem("Close Other Tabs") { closeAll(tab.id) }
        others.isEnabled = tabs.count > 1
        return items + [
            ActionItem("Close Tab") { close(tab.id) },
            others,
            .separator(),
            ActionItem("Close All Tabs") { closeAll(nil) },
        ]
    }
}

private struct ActivePill: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Capsule()
            .fill(scheme == .dark ? Color.white.opacity(0.17) : Color.white)
            .overlay(Capsule().strokeBorder(.white.opacity(scheme == .dark ? 0.12 : 0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.12), radius: 3, y: 1)
    }
}

private struct TabButton: View {
    let tab: TabItem
    let isActive: Bool
    let close: () -> Void
    let select: () -> Void

    @State private var isHovering = false
    @State private var textWidth: CGFloat = 0
    @State private var shownWidth: CGFloat = 0
    private let maxTitleWidth: CGFloat = 190

    var body: some View {
        HStack(spacing: 8) {
            TabIcon(logo: tab.logo, symbol: SidebarView.draftDirectory(from: tab.id) == nil ? "bubble.left" : "square.and.pencil", status: tab.status)
            Text(tab.title)
                .font(.system(size: 13, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { textWidth = $0 }
                // Titles shrink when the window is narrow (rather than the whole
                // strip being pushed into the toolbar's overflow menu).
                .frame(minWidth: 28, maxWidth: min(max(textWidth, 28), maxTitleWidth), alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { shownWidth = $0 }
                .clipped()
                // Long titles fade out instead of ending in "…".
                .mask {
                    if textWidth > shownWidth + 0.5 {
                        LinearGradient(stops: [.init(color: .black, location: 0.82), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                    } else {
                        Color.black
                    }
                }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(.fill.tertiary, in: .circle)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .help("Close Tab")
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: 30)
        .contentShape(.capsule)
        .onTapGesture(perform: select)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering } }
        .help(tab.status.help.map { "\(tab.title) — \($0)" } ?? tab.title)
    }
}

/// An app-icon tile, like Rex: the model maker's logo large on a soft tile, wrapped
/// tightly in a white rim. How the session is doing shows as a badge in its corner,
/// with the sidebar's marks: a spinner while the agent works, a hand while it waits
/// for you, a red mark after a failed run, a dot when a run finished out of sight.
struct TabIcon: View {
    let logo: String?
    /// Shown when there's no logo: a pencil for a draft, a bubble for a session.
    var symbol = "bubble.left"
    let status: TabItem.Status

    static let tileSize = CGSize(width: 25, height: 20)

    var body: some View {
        FrontTile(logo: logo, symbol: symbol)
            .overlay(alignment: .bottomTrailing) {
                if status != .idle {
                    StatusBadge(status: status)
                        .offset(x: 5, y: 4)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.ui, value: status)
    }
}

/// How the session is doing, in the tile's corner: the same marks the sidebar uses.
private struct StatusBadge: View {
    let status: TabItem.Status
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Circle().fill(scheme == .dark ? Color(white: 0.2) : .white)
            switch status {
            case .working:
                Spinner(size: 9)
            case .waiting:
                mark("hand.raised.fill", on: .orange)
            case .failed:
                mark("exclamationmark", on: .red)
            case .unread:
                Circle().fill(.tint).padding(3)
            case .idle:
                EmptyView()
            }
        }
        .frame(width: 14, height: 14)
        .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.2), radius: 1, y: 0.5)
    }

    private func mark(_ symbol: String, on color: Color) -> some View {
        Circle().fill(color.gradient)
            .padding(1.5)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(.white)
            }
    }
}

/// The white rim around every tile, with a soft shadow so it holds on a white pill.
private struct TileRim: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .clipShape(.rect(cornerRadius: 5.5))
            .overlay(RoundedRectangle(cornerRadius: 5.5).strokeBorder(scheme == .dark ? Color(white: 0.62) : .white, lineWidth: 1.5))
            .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.22), radius: 1.2, y: 0.5)
    }
}

private struct FrontTile: View {
    let logo: String?
    let symbol: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: scheme == .dark ? [Color(white: 0.3), Color(white: 0.22)] : [Color(white: 0.97), Color(white: 0.9)],
                startPoint: .top, endPoint: .bottom
            )
            Group {
                if let logo {
                    ProviderLogo(id: logo, size: 13)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                }
            }
            .foregroundStyle(scheme == .dark ? Color.white : Color(white: 0.18))
        }
        .frame(width: TabIcon.tileSize.width, height: TabIcon.tileSize.height)
        .modifier(TileRim())
    }
}

/// The project the active tab belongs to, and its git branch, at the left of
/// the title bar (where Rex shows the session and its host).
struct ProjectIdentity: View {
    let name: String?
    let branch: String?
    /// Where the session runs, for switching its branch.
    var directory: String?
    /// A session's own worktree keeps its branch.
    var isWorktree = false
    var environment: [String: String] = [:]
    @Binding var showsSidebar: Bool
    /// After switching branches.
    var switched: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.ui) { showsSidebar.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14))
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(showsSidebar ? "Hide Sessions (⌘0)" : "Show Sessions (⌘0)")

            if let name {
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                    if let branch {
                        if let directory, !isWorktree {
                            BranchSwitcher(branch: branch, directory: directory, environment: environment, switched: switched)
                        } else {
                            BranchLabel(branch: branch)
                                .help(isWorktree ? "This session's own branch, in its worktree" : "")
                        }
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                // A long branch name (a worktree's is its session's title) leaves the tabs room.
                .frame(minWidth: 50, maxWidth: 220, alignment: .leading)
            }
        }
    }
}

private struct BranchLabel: View {
    let branch: String

    var body: some View {
        Label(branch, systemImage: "arrow.triangle.branch")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .imageScale(.small)
    }
}

/// The branch under the project's name, as a menu: switch to another of the repository's
/// branches (the latest first), or start a new one.
private struct BranchSwitcher: View {
    let branch: String
    let directory: String
    let environment: [String: String]
    let switched: () -> Void
    @State private var branches: [String] = []
    @State private var isNaming = false
    @State private var newName = ""
    @State private var failure: String?

    var body: some View {
        Menu {
            if branches.count > 1 {
                Section("Switch To") {
                    ForEach(branches.filter { $0 != branch }.prefix(15), id: \.self) { name in
                        Button(name) { run(["switch", name], created: false) }
                    }
                }
            }
            Button("New Branch…") {
                newName = ""
                isNaming = true
            }
        } label: {
            BranchLabel(branch: branch)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Switch branches, or start a new one")
        .task(id: directory + "\n" + branch) { await load() }
        // Branches made elsewhere show up the next time the pointer comes by.
        .onHover { if $0 { Task { await load() } } }
        .alert("New Branch", isPresented: $isNaming) {
            TextField("Name", text: $newName)
            Button("Create") { run(["switch", "-c", newName.trimmingCharacters(in: .whitespaces)], created: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It starts from \(branch), and changes you haven't committed come along.")
        }
        .alert("Couldn't Switch Branches", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func load() async {
        let directory = directory
        let list = await Task.detached {
            Git.run(["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads"], in: directory) ?? ""
        }.value
        branches = list.split(separator: "\n").map(String.init)
    }

    private func run(_ arguments: [String], created: Bool) {
        guard arguments.last?.isEmpty == false else { return }
        let directory = directory, environment = environment
        Task {
            failure = await Task.detached { Git.report(arguments, in: directory, environment: environment) }.value
            if failure == nil { Analytics.shared.track("branch_switched", ["created": created]) }
            switched()
        }
    }
}
