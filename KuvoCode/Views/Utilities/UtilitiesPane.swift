import AppKit
import SwiftUI

/// The right panel: a card whose header is a strip of tabs (Changes, files, terminals,
/// browsers) with a + menu for new ones.
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
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Tabs

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(utilities.tabs) { tab in
                        UtilityTabButton(
                            title: title(for: tab),
                            symbol: symbol(for: tab),
                            isSelected: tab.id == utilities.selected?.id,
                            select: { utilities.selection = tab.id },
                            close: { withAnimation(.ui) { utilities.close(tab.id) } }
                        )
                    }
                }
            }
            .scrollIndicators(.never)
            Menu {
                Button("Terminal", systemImage: "terminal") { utilities.newTerminal(in: directory, environment: environment) }
                Button("Browser", systemImage: "globe") { utilities.newBrowser() }
                Button("Files", systemImage: "folder") { utilities.showFiles() }
                Button("Changes", systemImage: "plus.forwardslash.minus") { utilities.showChanges() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(CardActionStyle())
            .fixedSize()
            .help("New Tab")
            Button { withAnimation(.ui) { isExpanded.toggle() } } label: {
                Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(CardActionStyle())
            .help(isExpanded ? "Restore" : "Expand")
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: 40)
    }

    private func title(for tab: Utilities.Tab) -> String {
        switch tab.kind {
        case .changes: "Changes"
        case .file(let url): url?.lastPathComponent ?? "Files"
        case .terminal: utilities.terminals[tab.id]?.title ?? "Terminal"
        case .browser: utilities.browsers[tab.id]?.displayTitle ?? "Browser"
        }
    }

    private func symbol(for tab: Utilities.Tab) -> String {
        switch tab.kind {
        case .changes: "plus.forwardslash.minus"
        case .file(let url): url == nil ? "folder" : "doc"
        case .terminal: "terminal"
        case .browser: "globe"
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
                    TerminalHost(session: session)
                        .padding(.leading, 10)
                        .padding(.top, 6)
                        .id(tab.id)
                }
            case .browser:
                if let session = utilities.browsers[tab.id] {
                    BrowserPane(session: session)
                        .id(tab.id)
                }
            }
        } else {
            VStack(spacing: 14) {
                Text("Open a Tool")
                    .font(.headline)
                HStack(spacing: 10) {
                    Button("Terminal", systemImage: "terminal") { utilities.newTerminal(in: directory, environment: environment) }
                    Button("Browser", systemImage: "globe") { utilities.newBrowser() }
                    Button("Files", systemImage: "folder") { utilities.showFiles() }
                    Button("Changes", systemImage: "plus.forwardslash.minus") { utilities.showChanges() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholder(_ title: String, symbol: String, detail: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
            .frame(maxHeight: .infinity)
    }
}

/// A tab in the panel's strip: icon and title, and a close button on hover.
private struct UtilityTabButton: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? .primary : .secondary)
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 1 : 0)
            .help("Close Tab")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(isSelected ? Color.primary.opacity(0.08) : (isHovering ? Color.primary.opacity(0.04) : .clear), in: .rect(cornerRadius: 8))
        .contentShape(.rect(cornerRadius: 8))
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .help(title)
    }
}
