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

        /// The tile peeking out behind the front one.
        var color: Color? {
            switch self {
            case .idle: nil
            case .working: .green
            case .waiting: .orange
            case .failed: .red
            case .unread: .accentColor
            }
        }

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

    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                let isActive = tab.id == selection
                TabButton(tab: tab, isActive: isActive, close: { close(tab.id) }) {
                    withAnimation(.ui) { selection = tab.id }
                }
                .contextMenu {
                    Button("Close Tab") { close(tab.id) }
                    Button("Close Other Tabs") { closeAll(tab.id) }
                        .disabled(tabs.count < 2)
                    Divider()
                    Button("Close All Tabs") { closeAll(nil) }
                }
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
/// tightly in a white rim. How the session is doing shows as colored tiles peeking
/// out behind it: two greens while the agent works, orange while it waits for you,
/// red after a failed run, the accent color when a run finished out of sight.
struct TabIcon: View {
    let logo: String?
    /// Shown when there's no logo: a pencil for a draft, a bubble for a session.
    var symbol = "bubble.left"
    let status: TabItem.Status

    static let tileSize = CGSize(width: 25, height: 20)
    /// How far each tile behind peeks out.
    static let peek: CGFloat = 7

    private var behind: [Color] {
        switch status {
        case .working: [Color(red: 0.2, green: 0.55, blue: 0.27), .green]
        default: status.color.map { [$0] } ?? []
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(behind.enumerated()), id: \.offset) { index, color in
                StatusTile(color: color)
                    .offset(x: Self.peek * CGFloat(behind.count - index))
                    .transition(.offset(x: -Self.peek).combined(with: .opacity))
            }
            FrontTile(logo: logo, symbol: symbol)
        }
        .frame(width: Self.tileSize.width + Self.peek * CGFloat(behind.count), height: Self.tileSize.height, alignment: .leading)
        .animation(.ui, value: status)
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

private struct StatusTile: View {
    let color: Color

    var body: some View {
        Rectangle()
            .fill(color.gradient)
            .frame(width: TabIcon.tileSize.width, height: TabIcon.tileSize.height)
            .modifier(TileRim())
    }
}

/// The project the active tab belongs to, and its git branch, at the left of
/// the title bar (where Rex shows the session and its host).
struct ProjectIdentity: View {
    let name: String?
    let branch: String?
    @Binding var showsSidebar: Bool

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
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 50, alignment: .leading)
            }
        }
    }
}
