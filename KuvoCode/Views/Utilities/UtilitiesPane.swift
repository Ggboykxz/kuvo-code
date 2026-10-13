import AppKit
import SwiftUI

/// The right panel: a card whose header is a strip of tabs (Changes, files, terminals,
/// browsers), with + for a new tab, then expand. The title bar's button shows and hides it.
struct UtilitiesPane: View {
    @Bindable var utilities: Utilities
    /// The project in view; files and terminals start there.
    let directory: String?
    let model: SessionModel?
    let environment: [String: String]
    @Binding var isExpanded: Bool
    var isFocused = true

    var body: some View {
        Card(title: "", isFocused: isFocused, showsHeader: false) {
            EmptyView()
        } content: {
            VStack(spacing: 0) {
                tabStrip
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Tabs

    private var tabStrip: some View {
        HStack(spacing: 6) {
            // Tabs share the width and shrink as more open, like a browser's.
            HStack(spacing: 4) {
                ForEach(utilities.tabs) { tab in
                    UtilityTabButton(
                        title: title(for: tab),
                        icon: icon(for: tab),
                        isSelected: tab.id == utilities.selected?.id,
                        select: { utilities.selection = tab.id },
                        close: { withAnimation(.ui) { utilities.close(tab.id) } }
                    )
                    .frame(minWidth: 44, maxWidth: 190)
                    .layoutPriority(1)
                    .contextMenu {
                        Button("Close Tab") { withAnimation(.ui) { utilities.close(tab.id) } }
                        Button("Close Other Tabs") {
                            withAnimation(.ui) { for other in utilities.tabs where other.id != tab.id { utilities.close(other.id) } }
                        }
                        .disabled(utilities.tabs.count < 2)
                    }
                }
                Button { withAnimation(.ui) { utilities.newTab() } } label: {
                    Label("New Tab", systemImage: "plus")
                }
                .buttonStyle(PanelIconStyle())
                .help("New Tab")
                Spacer(minLength: 0)
            }
            Button { withAnimation(.ui) { isExpanded.toggle() } } label: {
                Label(isExpanded ? "Restore" : "Expand", systemImage: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(PanelIconStyle())
            .help(isExpanded ? "Restore" : "Expand")
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(height: 44)
    }

    private func title(for tab: Utilities.Tab) -> String {
        switch tab.kind {
        case .changes: "Changes"
        case .file(let url): url?.lastPathComponent ?? "Files"
        case .terminal: utilities.terminals[tab.id]?.title ?? "Terminal"
        case .browser: utilities.browsers[tab.id]?.displayTitle ?? "New Tab"
        }
    }

    private func icon(for tab: Utilities.Tab) -> TabGlyph {
        switch tab.kind {
        case .changes: .symbol("plus.forwardslash.minus")
        case .file(let url): .symbol(url == nil ? "folder" : "doc")
        case .terminal: .symbol("apple.terminal")
        case .browser:
            if let browser = utilities.browsers[tab.id], let host = browser.url?.host()?.replacingOccurrences(of: "www.", with: ""),
               let site = utilities.history.sites.first(where: { $0.host == host }), let image = utilities.history.icon(for: site) {
                .image(image)
            } else {
                .symbol("globe")
            }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let tab = utilities.selected {
            switch tab.kind {
            case .changes:
                if let directory {
                    ChangesPanel(directory: directory, model: model)
                        .id(directory)
                } else {
                    placeholder("No Project", symbol: "plus.forwardslash.minus", detail: "Open a project to see its changes.")
                }
            case .file(let url):
                if let directory {
                    FilesView(root: directory, file: url, showsTree: $utilities.showsTree) { utilities.open($0) }
                        .id(directory)
                } else {
                    placeholder("No Project", symbol: "folder", detail: "Open a project to browse its files.")
                }
            case .terminal:
                if let session = utilities.terminals[tab.id] {
                    TerminalHost(session: session, isFocused: isFocused)
                        .id(tab.id)
                }
            case .browser:
                if let session = utilities.browsers[tab.id] {
                    BrowserPane(session: session) {
                        NewTabPage(utilities: utilities, tabID: tab.id, directory: directory, environment: environment, browser: session)
                    }
                    .id(tab.id)
                }
            }
        }
    }

    private func placeholder(_ title: String, symbol: String, detail: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
            .frame(maxHeight: .infinity)
    }
}

/// What a tab shows before its title: a symbol, or a site's own icon.
enum TabGlyph {
    case symbol(String)
    case image(NSImage)
}

/// A tab in the panel's strip, like a browser's: icon and title in a rounded tab, the
/// selected one filled, and a close button on hover.
private struct UtilityTabButton: View {
    let title: String
    let icon: TabGlyph
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Group {
                switch icon {
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 12))
                case .image(let image):
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .clipShape(.rect(cornerRadius: 3))
                        .frame(width: 14, height: 14)
                }
            }
            .frame(width: 16)
            .foregroundStyle(isSelected ? .primary : .secondary)
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(isHovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 1 : 0)
            .help("Close Tab")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? Color.primary.opacity(0.08) : (isHovering ? Color.primary.opacity(0.04) : .clear))
        }
        .contentShape(.rect(cornerRadius: 9))
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .help(title)
    }
}

/// Icon buttons in the panel's chrome: quiet until hovered, on a rounded square.
struct PanelIconStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 13))
            .foregroundStyle(isHovering ? .primary : .secondary)
            .frame(width: 28, height: 28)
            .background(isHovering ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(.rect)
            .onHover { isHovering = $0 }
    }
}
