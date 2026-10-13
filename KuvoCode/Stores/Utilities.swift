import AppKit
import Foundation

/// The window's right panel: Changes, files, terminals and browsers, as tabs. Terminals
/// and pages keep running while their tab is out of view, and close with it.
@Observable
final class Utilities {
    enum Kind: Hashable {
        case changes
        /// A file, or the file tree when there isn't one yet.
        case file(URL?)
        case terminal
        case browser
    }

    struct Tab: Identifiable, Hashable {
        var id = UUID()
        var kind: Kind
    }

    private(set) var tabs: [Tab] = [Tab(kind: .changes)]
    var selection: UUID?
    /// Whether file tabs show the tree beside the file.
    var showsTree = true
    private(set) var terminals: [UUID: TerminalSession] = [:]
    private(set) var browsers: [UUID: BrowserSession] = [:]

    var selected: Tab? { tabs.first { $0.id == selection } ?? tabs.first }

    /// Shows the Changes tab, opening it again if it was closed.
    func showChanges() {
        if let tab = tabs.first(where: { $0.kind == .changes }) {
            selection = tab.id
        } else {
            add(Tab(kind: .changes), at: 0)
        }
    }

    func newTerminal(in directory: String?, environment: [String: String]) {
        let tab = Tab(kind: .terminal)
        terminals[tab.id] = TerminalSession(directory: directory ?? NSHomeDirectory(), environment: environment)
        add(tab)
    }

    @discardableResult
    func newBrowser(_ address: String? = nil) -> BrowserSession {
        let tab = Tab(kind: .browser)
        let browser = BrowserSession()
        browsers[tab.id] = browser
        if let address { browser.load(address) }
        add(tab)
        return browser
    }

    /// The file tree, in a tab of its own.
    func showFiles() {
        if let tab = tabs.first(where: { $0.kind == .file(nil) }) {
            selection = tab.id
        } else {
            add(Tab(kind: .file(nil)))
        }
    }

    /// Opens `url` in a file tab: its own if it has one, else the file tab in view.
    func open(_ url: URL) {
        if let tab = tabs.first(where: { $0.kind == .file(url) }) {
            selection = tab.id
        } else if let current = selected, case .file = current.kind, let index = tabs.firstIndex(of: current) {
            tabs[index].kind = .file(url)
        } else {
            add(Tab(kind: .file(url)))
        }
    }

    /// The browser in view, or the most recent one.
    var activeBrowser: BrowserSession? {
        if let selected, let browser = browsers[selected.id] { return browser }
        return tabs.reversed().lazy.compactMap { self.browsers[$0.id] }.first
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        terminals.removeValue(forKey: id)?.terminate()
        browsers.removeValue(forKey: id)?.close()
        if selection == id {
            selection = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    /// Ends every terminal (the window is closing).
    func closeAll() {
        for terminal in terminals.values { terminal.terminate() }
        for browser in browsers.values { browser.close() }
        terminals = [:]
        browsers = [:]
    }

    private func add(_ tab: Tab, at index: Int? = nil) {
        tabs.insert(tab, at: index ?? tabs.count)
        selection = tab.id
    }
}
