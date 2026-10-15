import AppKit
import Foundation
import WebKit

/// The window's right panel: Changes, files, terminals and browsers, as tabs. Terminals
/// and pages keep running while their tab is out of view, and close with it.
///
/// The browser is the place's where the session in view runs: this Mac's, or a machine's. A
/// machine's browser runs there (its agents browse with it), and each of its pages is a tab; this
/// Mac's browser tabs don't show for a session on a machine, nor a machine's for one here.
@Observable
final class Utilities {
    enum Kind: Hashable {
        case changes
        /// A file, or the file tree when there isn't one yet.
        case file(URL?)
        case terminal
        case browser
        /// A page of a machine's browser; nil for a new tab that hasn't gone anywhere yet.
        case machinePage(String, String?)
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
    /// The terminals Run runs a project's command in, by the folder they run in.
    private var runs: [String: UUID] = [:]
    private(set) var browsers: [UUID: BrowserSession] = [:]
    /// Sites the browser visits, for the new tab page.
    let history = BrowserHistory()
    /// Goes up when something (the agent's browsing) needs the panel in view.
    private(set) var revealRequest = 0
    /// Puts text in the composer of the session in view, for Add to Message on a selection
    /// in a file or a terminal. The window sets it.
    @ObservationIgnored var addToMessage: ((String) -> Void)?
    /// Attaches files to that message, like a screenshot of a page.
    @ObservationIgnored var attachToMessage: (([URL]) -> Void)?
    /// A machine's browser, by the machine's ID.
    @ObservationIgnored var machineBrowser: ((String) -> MachineBrowser?)?

    /// The machine the session in view runs on, nil for this Mac: the browser tabs are its, and
    /// new ones open there. The window sets it.
    var place: String? {
        didSet { if place != oldValue { placeChanged(from: oldValue) } }
    }

    /// The session in view; an agent elsewhere browsing doesn't bring its page forward. The window
    /// sets it.
    var sessionInView: String?

    /// The tab chosen in each place, to come back to.
    @ObservationIgnored private var chosen: [String: UUID] = [:]

    /// The tabs in the strip: every tool's, and the browser tabs of the place in view.
    var visibleTabs: [Tab] { tabs.filter(isVisible) }

    var selected: Tab? { visibleTabs.first { $0.id == selection } ?? visibleTabs.first }

    func isVisible(_ tab: Tab) -> Bool {
        switch tab.kind {
        case .browser: place == nil
        case .machinePage(let machine, _): place == machine
        default: true
        }
    }

    init() {
        startOver()
    }

    /// The panel as it opens: on Changes, or on a new tab if Settings › Panel says so.
    private func startOver() {
        tabs = [Tab(kind: .changes)]
        selection = nil
        if UserDefaults.standard.string(forKey: PanelSettings.startsWith) == PanelSettings.Start.newTab.rawValue {
            tabs = []
            newTab()
        }
    }

    /// Another place in view: its browser tabs in the strip, and the tab you had there.
    private func placeChanged(from old: String?) {
        chosen[old ?? ""] = selection
        if let old { machineBrowser?(old)?.keep(false) }
        if let place, let browser = machineBrowser?(place) {
            browser.keep(true)
            syncMachinePages(place, browser.pages)
        }
        let visible = visibleTabs
        let isVisible = { (id: UUID?) in id.flatMap { id in visible.contains { $0.id == id } ? id : nil } }
        // The tab you had there, else the one in view if it's there too (a tool's, or a new tab
        // opened as the place changed).
        selection = isVisible(chosen[place ?? ""]) ?? isVisible(selection) ?? visible.first?.id
        if visible.isEmpty { showChanges() }
    }

    /// Shows the Changes tab, opening it again if it was closed.
    func showChanges() {
        Analytics.shared.track("panel_opened", ["tool": "changes"])
        if let tab = tabs.first(where: { $0.kind == .changes }) {
            selection = tab.id
        } else {
            add(Tab(kind: .changes), at: 0)
        }
    }

    func newTerminal(in directory: String?, environment: [String: String]) {
        Analytics.shared.track("panel_opened", ["tool": "terminal"])
        let tab = Tab(kind: .terminal)
        let terminal = TerminalSession(directory: directory ?? NSHomeDirectory(), environment: environment)
        terminal.addToMessage = { [weak self] text in self?.addToMessage?(text) }
        terminals[tab.id] = terminal
        add(tab)
    }

    /// Runs a project's run command in `directory`, in a terminal of its own. Run again, it
    /// stops what's still running there and starts the command over.
    func run(_ command: String, in directory: String, environment: [String: String]) {
        Analytics.shared.track("project_run")
        if let id = runs[directory], let terminal = terminals[id], terminal.isRunning {
            terminal.run(command)
            selection = id
            return
        }
        let tab = Tab(kind: .terminal)
        let terminal = TerminalSession(directory: directory, environment: environment, command: command)
        terminal.addToMessage = { [weak self] text in self?.addToMessage?(text) }
        terminals[tab.id] = terminal
        runs[directory] = tab.id
        add(tab)
    }

    /// A browser tab at `address`; or, given WebKit's configuration, a window a page opened, placed
    /// right after the page's tab. When that window closes itself, its page's tab comes back.
    @discardableResult
    func newBrowser(_ address: String? = nil, configuration: WKWebViewConfiguration? = nil, openedFrom opener: UUID? = nil, byAgent: Bool = false) -> BrowserSession {
        // Yours only: not the agent's tabs, nor windows a page opened.
        if !byAgent, configuration == nil { Analytics.shared.track("panel_opened", ["tool": "browser"]) }
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

    // MARK: Machines' browsers

    /// A new tab in a machine's browser: it opens a page there once you go somewhere (at
    /// `address` at once, if given).
    func newMachinePage(_ machine: String, address: String? = nil) {
        Analytics.shared.track("panel_opened", ["tool": "machine_browser"])
        let tab = Tab(kind: .machinePage(machine, nil))
        add(tab)
        if let address { open(address, inTab: tab.id) }
    }

    /// Opens `address` in a machine's new tab: a page there, which the tab then shows.
    func open(_ address: String, inTab id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }), case .machinePage(let machine, nil) = tab.kind,
              let browser = machineBrowser?(machine) else { return }
        Task {
            guard let page = await browser.newPage(address) else { return }
            bind(id, to: page, on: machine)
        }
    }

    /// A new tab's page is open: the tab shows it, in its own place in the strip.
    private func bind(_ id: UUID, to page: String, on machine: String) {
        // The page may have made a tab of its own on the way (its browser said it opened).
        if let other = tabs.firstIndex(where: { $0.kind == .machinePage(machine, page) && $0.id != id }) {
            tabs.remove(at: other)
        }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            // The tab closed meanwhile: so does its page.
            machineBrowser?(machine)?.close(page)
            return
        }
        tabs[index].kind = .machinePage(machine, page)
    }

    /// Keeps a machine's tabs in step with its browser's pages: a tab for each page (one the agent
    /// opened included), and none for a page that closed.
    func syncMachinePages(_ machine: String, _ pages: [MachineBrowser.Page]) {
        let open = Set(pages.map(\.id))
        for tab in tabs {
            if case .machinePage(machine, let page?) = tab.kind, !open.contains(page) { remove(tab.id) }
        }
        let tabbed = Set(tabs.compactMap { tab -> String? in
            if case .machinePage(machine, let page?) = tab.kind { return page }
            return nil
        })
        for page in pages where !tabbed.contains(page.id) {
            let last = tabs.lastIndex { if case .machinePage(machine, _) = $0.kind { true } else { false } }
            tabs.insert(Tab(kind: .machinePage(machine, page.id)), at: last.map { $0 + 1 } ?? tabs.count)
        }
    }

    /// The agent on a machine went to another page (or opened one): its tab comes forward, as the
    /// panel's browser does for the agent here.
    func machinePageActive(_ machine: String, page: String, byAgent: Bool, session: String? = nil) {
        guard byAgent, session == nil || session == sessionInView, let tab = tabs.first(where: { $0.kind == .machinePage(machine, page) }) else { return }
        if place == machine {
            selection = tab.id
            if PanelSettings.isOn(PanelSettings.revealsForAgent) { revealRequest += 1 }
        } else {
            chosen[machine] = tab.id
        }
    }

    /// An agent on a machine started browsing: with a session there in view, the panel shows the
    /// page it uses.
    func revealMachineBrowser(_ machine: String, for session: String? = nil) {
        guard place == machine, session == nil || session == sessionInView else { return }
        let browser = machineBrowser?(machine)
        let tab = tabs.first { $0.kind == .machinePage(machine, browser?.activeID) }
            ?? tabs.last { if case .machinePage(machine, _) = $0.kind { true } else { false } }
        if let tab { selection = tab.id }
        if PanelSettings.isOn(PanelSettings.revealsForAgent) { revealRequest += 1 }
    }

    /// Brings the panel into view on the browser of the place in view, at the page in use: you
    /// asked to see it.
    func revealBrowser() {
        if let place {
            let tab = tabs.first { $0.kind == .machinePage(place, machineBrowser?(place)?.activeID) }
                ?? tabs.last { if case .machinePage(place, _) = $0.kind { true } else { false } }
            if let tab { selection = tab.id }
        } else if let browser = activeBrowser, let id = browsers.first(where: { $0.value === browser })?.key {
            selection = id
        }
        revealRequest += 1
    }

    /// Closes a machine's tabs: the machine was removed or disconnected.
    func closeMachineBrowser(_ machine: String) {
        for tab in tabs {
            if case .machinePage(machine, _) = tab.kind { remove(tab.id) }
        }
    }

    // MARK: Files

    /// The file tree, in a tab of its own.
    func showFiles() {
        Analytics.shared.track("panel_opened", ["tool": "files"])
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

    /// A new tab: an empty browser tab of the place in view, which shows the tools and suggested
    /// sites until you go somewhere.
    func newTab() {
        if let place {
            newMachinePage(place)
        } else {
            newBrowser()
        }
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

    /// Closes a tab, and what it shows: its terminal, its page (on a machine too).
    func close(_ id: UUID) {
        if let tab = tabs.first(where: { $0.id == id }), case .machinePage(let machine, let page?) = tab.kind {
            machineBrowser?(machine)?.close(page)
        }
        remove(id)
    }

    /// Takes a tab out of the strip; the tab beside it takes its place.
    private func remove(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let at = visibleTabs.firstIndex { $0.id == id }
        let wasSelected = selected?.id == id
        tabs.remove(at: index)
        terminals.removeValue(forKey: id)?.terminate()
        browsers.removeValue(forKey: id)?.close()
        if wasSelected {
            let rest = visibleTabs
            selection = at.flatMap { rest.indices.contains($0) ? rest[$0].id : nil } ?? rest.last?.id
        }
        // The panel always has a tab: closing the last one leaves a new tab in its place.
        if visibleTabs.isEmpty { newTab() }
    }

    /// Ends every terminal and page, and starts the panel over: the window is closing, and its
    /// tabs go with what they showed (a tab left without its terminal or page would show nothing).
    /// A machine's pages keep running there, and come back as tabs.
    func closeAll() {
        for terminal in terminals.values { terminal.terminate() }
        for browser in browsers.values { browser.close() }
        terminals = [:]
        browsers = [:]
        runs = [:]
        let place = place
        self.place = nil
        startOver()
        self.place = place
    }

    private func add(_ tab: Tab, at index: Int? = nil) {
        tabs.insert(tab, at: index ?? tabs.count)
        selection = tab.id
    }
}
