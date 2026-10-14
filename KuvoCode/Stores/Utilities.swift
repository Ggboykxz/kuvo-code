import AppKit
import Foundation
import WebKit

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
    /// Sites the browser visits, for the new tab page.
    let history = BrowserHistory()
    /// Goes up when something (the agent's browsing) needs the panel in view.
    private(set) var revealRequest = 0
    /// Puts text in the composer of the session in view, for Add to Message on a selection
    /// in a file or a terminal. The window sets it.
    @ObservationIgnored var addToMessage: ((String) -> Void)?

    var selected: Tab? { tabs.first { $0.id == selection } ?? tabs.first }

    init() {
        // Settings › Panel can start the panel on a new tab instead of Changes.
        if UserDefaults.standard.string(forKey: PanelSettings.startsWith) == PanelSettings.Start.newTab.rawValue {
            tabs = []
            newTab()
        }
    }

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
        let terminal = TerminalSession(directory: directory ?? NSHomeDirectory(), environment: environment)
        terminal.addToMessage = { [weak self] text in self?.addToMessage?(text) }
        terminals[tab.id] = terminal
        add(tab)
    }

    /// A browser tab at `address`; or, given WebKit's configuration, a window a page opened, placed
    /// right after the page's tab. When that window closes itself, its page's tab comes back.
    @discardableResult
    func newBrowser(_ address: String? = nil, configuration: WKWebViewConfiguration? = nil, openedFrom opener: UUID? = nil) -> BrowserSession {
        let tab = Tab(kind: .browser)
        let browser = BrowserSession(configuration: configuration)
        browser.onVisit = { [weak history] url, title, icon in history?.record(url, title: title, iconURL: icon) }
        browser.openWindow = { [weak self] configuration in
            self?.newBrowser(configuration: configuration, openedFrom: tab.id).webView
        }
        browser.onClose = { [weak self] in
            guard let self else { return }
            close(tab.id)
            if let opener, tabs.contains(where: { $0.id == opener }) { selection = opener }
        }
        browsers[tab.id] = browser
        if let address { browser.load(address) }
        add(tab, at: opener.flatMap { id in tabs.firstIndex { $0.id == id }.map { $0 + 1 } })
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

    /// A new tab: an empty browser, which shows the tools and suggested sites until you go
    /// somewhere.
    func newTab() {
        newBrowser()
    }

    /// Swaps a tab for another tool, in its place: what picking a tool on a new tab page does.
    func replace(_ id: UUID, with open: () -> Void) {
        let before = Set(tabs.map(\.id))
        open()
        // Put a tab the tool added where this one was (it may have reused an existing tab instead).
        if let added = tabs.first(where: { !before.contains($0.id) }), let from = tabs.firstIndex(of: added) {
            tabs.remove(at: from)
            tabs.insert(added, at: tabs.firstIndex(where: { $0.id == id }) ?? tabs.count)
        }
        close(id)
    }

    /// Shows the Changes tab and brings the panel into view: you asked to see it.
    func revealChanges() {
        showChanges()
        revealRequest += 1
    }

    /// Opens `url` in a file tab and brings the panel into view: you asked to see it.
    func show(_ url: URL) {
        open(url)
        revealRequest += 1
    }

    /// Brings the panel into view, on `browser`'s tab if given.
    func reveal(_ browser: BrowserSession? = nil) {
        if let browser, let id = browsers.first(where: { $0.value === browser })?.key { selection = id }
        if PanelSettings.isOn(PanelSettings.revealsForAgent) { revealRequest += 1 }
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
        // The panel always has a tab: closing the last one leaves a new tab in its place.
        if tabs.isEmpty { newTab() }
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
