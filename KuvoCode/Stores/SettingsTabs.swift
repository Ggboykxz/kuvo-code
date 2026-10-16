import Foundation

/// Settings' tabs, in the title bar, as the sessions have theirs: each a page of Settings, or a
/// site you're signing in to for the agent (Settings › Integrations). Picking a page in the
/// sidebar shows it in the tab in view; ⌘-click, or Open in New Tab, gives it a tab of its own.
/// The pages' tabs are kept for the next time; the sites' close when you leave Settings.
@MainActor
@Observable
final class SettingsTabs {
    /// Signing in to a service on its site: where (this Mac or a machine), and its pages there.
    @MainActor
    @Observable
    final class Site {
        let service: Integrations.Service
        /// "" for this Mac, else a machine's ID.
        var place = ""
        /// Its tabs on this Mac.
        let pages = SignInPages()
        /// The page opened on each machine, by machine.
        var machinePages: [String: String] = [:]
        var opening: String?

        init(service: Integrations.Service) {
            self.service = service
        }
    }

    struct Tab: Identifiable, Equatable {
        enum Kind: Equatable {
            case page(SettingsPage)
            /// A site, by its service.
            case site(String)
        }

        let id: String
        var kind: Kind

        var page: SettingsPage? {
            if case .page(let page) = kind { return page }
            return nil
        }
    }

    private(set) var tabs: [Tab] = []
    private(set) var selectedID = ""
    private var sites: [String: Site] = [:]
    /// Where the page's card starts in the window, for the tabs to start there too.
    var contentX: CGFloat = 0
    /// The page tab you were on last, for the sidebar while a site's tab is in view.
    private var lastPageTab = ""

    private static let tabsKey = "settings.tabs"

    init() {
        let defaults = UserDefaults.standard
        let pages = (defaults.string(forKey: Self.tabsKey) ?? "").split(separator: ",").compactMap { SettingsPage(rawValue: String($0)) }
        let current = defaults.string(forKey: SettingsPage.storageKey).flatMap(SettingsPage.init) ?? pages.first ?? .general
        tabs = (pages.isEmpty ? [current] : pages).map { Tab(id: UUID().uuidString, kind: .page($0)) }
        let selected = tabs.first { $0.page == current } ?? tabs[0]
        selectedID = selected.id
        lastPageTab = selected.id
    }

    var selected: Tab? { tabs.first { $0.id == selectedID } }

    /// The site of the tab in view, if it's a site's.
    var selectedSite: Site? {
        guard case .site(let id) = selected?.kind else { return nil }
        return sites[id]
    }

    func site(_ id: String) -> Site? { sites[id] }

    /// The page the sidebar shows: the one in view, or the one you were on before a site's tab.
    var page: SettingsPage {
        selected?.page ?? tabs.first { $0.id == lastPageTab }?.page ?? tabs.lazy.compactMap(\.page).first ?? .general
    }

    func select(_ id: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        selectedID = id
        if tab.page != nil { lastPageTab = id }
        save()
    }

    /// Shows `page`: in the page tab in view (or the one you were on), or in a new tab.
    func show(_ page: SettingsPage, inNewTab: Bool = false) {
        if inNewTab {
            insert(Tab(id: UUID().uuidString, kind: .page(page)))
        } else if let open = tabs.first(where: { $0.page == page }) {
            // Open in a tab already: that one.
            select(open.id)
        } else if let index = tabs.firstIndex(where: { $0.id == (selected?.page != nil ? selectedID : lastPageTab) && $0.page != nil }) {
            tabs[index].kind = .page(page)
            select(tabs[index].id)
        } else {
            insert(Tab(id: UUID().uuidString, kind: .page(page)))
        }
        Analytics.shared.track("settings_opened", ["tab": page.rawValue])
    }

    /// Signs in to `service` in a tab of its own (the one there is, if it's open).
    func open(_ service: Integrations.Service) {
        if let tab = tabs.first(where: { $0.kind == .site(service.id) }) {
            select(tab.id)
            return
        }
        let site = Site(service: service)
        site.pages.open(service.site)
        sites[service.id] = site
        insert(Tab(id: UUID().uuidString, kind: .site(service.id)))
    }

    /// After the tab in view, and in view.
    private func insert(_ tab: Tab) {
        let index = tabs.firstIndex { $0.id == selectedID }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: index)
        select(tab.id)
    }

    /// Closes a tab (a site's with its pages, here and on the machines); one is always left.
    func close(_ id: String, machines: Machines) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        if case .site(let service) = tab.kind, let site = sites.removeValue(forKey: service) {
            for (machine, page) in site.machinePages { machines.engine(machine)?.browser.close(page) }
            site.pages.closeAll()
        }
        if selectedID == id {
            // The page you were on, if a site's tab closes; otherwise the neighbor, as browsers do.
            let back = tab.page == nil ? tabs.first { $0.id == lastPageTab } : nil
            select((back ?? tabs[min(index, tabs.count - 1)]).id)
        }
        if lastPageTab == id { lastPageTab = tabs.first { $0.page != nil }?.id ?? "" }
        save()
    }

    func closeOthers(than id: String?, machines: Machines) {
        for tab in tabs where tab.id != id { close(tab.id, machines: machines) }
    }

    /// Leaving Settings: the sites you were signing in to close.
    func closeSites(machines: Machines) {
        if !tabs.contains(where: { $0.page != nil }) { insert(Tab(id: UUID().uuidString, kind: .page(page))) }
        for tab in tabs where tab.page == nil { close(tab.id, machines: machines) }
    }

    func cycle(by offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count].id)
    }

    /// ⌘1 to ⌘8 show that tab, ⌘9 the last.
    func show(number: Int) {
        let index = number == 9 ? tabs.count - 1 : number - 1
        if tabs.indices.contains(index) { select(tabs[index].id) }
    }

    /// The pages' tabs, for the next time, and the page in view, as Settings has always kept it.
    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(tabs.compactMap(\.page?.rawValue).joined(separator: ","), forKey: Self.tabsKey)
        defaults.set(page.rawValue, forKey: SettingsPage.storageKey)
    }
}
