import Foundation

/// Settings' tabs, in the title bar, as the sessions have theirs: each a page of Settings, or a
/// site you're signing in to for the agent (Settings › Integrations). A page you open comes in the
/// preview tab, as VS Code's: the one you haven't done anything in yet, which the next page you
/// open takes the place of; doing something in it (a click, typing) keeps it, and the next page
/// gets a tab of its own. A page that's open already has its tab come forward; ⌘-click, or Open
/// in New Tab, opens one more, kept, even then.
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
        /// The page shown on each machine, by machine.
        var machinePages: [String: String] = [:]
        /// The pages under it, by machine, when a page opened another (a sign-in's popup): the
        /// one to go back to when it closes.
        var machineOpeners: [String: [String]] = [:]
        var opening: String?

        /// A machine's pages changed: a window the page in view opened comes forward, as a
        /// browser shows it, and one that closed gives way to the page that opened it.
        func follow(_ pages: [MachineBrowser.Page], on machine: String) {
            guard let shown = machinePages[machine] else { return }
            let open = Set(pages.map(\.id))
            if let popup = pages.last(where: { $0.opener == shown }) {
                machineOpeners[machine, default: []].append(shown)
                machinePages[machine] = popup.id
            } else if !open.contains(shown), let back = machineOpeners[machine]?.last(where: open.contains) {
                machineOpeners[machine]?.removeAll { $0 == back || !open.contains($0) }
                machinePages[machine] = back
            }
        }

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
    /// The preview tab: the page you opened last, if you haven't done anything in it, which the
    /// next page you open (or searching finds) takes the place of.
    private(set) var previewTab: String?

    private static let tabsKey = "settings.tabs"
    /// Which of the pages' tabs is the preview tab, for the next time: its page, and which of that
    /// page's tabs it is ("general#1", the second General tab).
    private static let previewKey = "settings.previewTab"

    init() {
        let defaults = UserDefaults.standard
        // Only pages Settings still lists (Phone goes while the phone link is off).
        let shown = SettingsPage.shown
        let pages = (defaults.string(forKey: Self.tabsKey) ?? "").split(separator: ",").compactMap { SettingsPage(rawValue: String($0)) }.filter(shown.contains)
        let current = defaults.string(forKey: SettingsPage.storageKey).flatMap(SettingsPage.init).flatMap { shown.contains($0) ? $0 : nil } ?? pages.first ?? .general
        tabs = (pages.isEmpty ? [current] : pages).map { Tab(id: UUID().uuidString, kind: .page($0)) }
        let selected = tabs.first { $0.page == current } ?? tabs[0]
        selectedID = selected.id
        lastPageTab = selected.id
        // The first time, the page Settings opens on is one you've only looked at.
        if pages.isEmpty {
            previewTab = selected.id
        } else if let saved = defaults.string(forKey: Self.previewKey) {
            let parts = saved.split(separator: "#", maxSplits: 1)
            let same = tabs.filter { $0.page == SettingsPage(rawValue: String(parts[0])) }
            let index = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            if index < same.count { previewTab = same[index].id }
        }
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

    /// Shows `page`: its tab, if it's open; else in the preview tab, unless `isBusy` says it has
    /// something open in its page's place (an editor, with what you typed), which stays; else in
    /// a new preview tab, beside the one in view. `inNewTab` (⌘-click) opens one more, kept.
    func show(_ page: SettingsPage, inNewTab: Bool = false, isBusy: (String) -> Bool = { _ in false }) {
        if inNewTab {
            insert(Tab(id: UUID().uuidString, kind: .page(page)))
        } else {
            preview(page, isBusy: isBusy)
        }
        Analytics.shared.track("settings_opened", ["tab": page.rawValue])
    }

    /// `page` as `show` has it, without counting it as opened: what searching finds first.
    func preview(_ page: SettingsPage, isBusy: (String) -> Bool = { _ in false }) {
        if let open = tabs.first(where: { $0.page == page }) {
            select(open.id)
        } else if let id = previewTab, !isBusy(id), let index = tabs.firstIndex(where: { $0.id == id && $0.page != nil }) {
            tabs[index].kind = .page(page)
            select(id)
        } else {
            insert(Tab(id: UUID().uuidString, kind: .page(page)))
            previewTab = selectedID
            save()
        }
    }

    /// Something was done in the tab in view (a click, typing): it's no longer a preview, and
    /// stays when you open another page.
    func keepSelected() {
        guard previewTab == selectedID else { return }
        previewTab = nil
        save()
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
        if previewTab == id { previewTab = nil }
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
        let preview = tabs.first { $0.id == previewTab }?.page.map { page in
            "\(page.rawValue)#\(tabs.prefix { $0.id != previewTab }.count { $0.page == page })"
        }
        defaults.set(preview, forKey: Self.previewKey)
    }
}
