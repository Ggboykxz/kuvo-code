import Foundation

/// Settings' tabs, in the title bar: the page you're on, then each site you're signing in to for
/// the agent (Settings › Integrations), kept open as you go back and forth between them, until
/// you close them or leave Settings.
@MainActor
@Observable
final class SettingsTabs {
    /// Signing in to a service on its site: where (this Mac or a machine), and its pages there.
    @MainActor
    @Observable
    final class Site: Identifiable {
        let service: Integrations.Service
        /// "" for this Mac, else a machine's ID.
        var place = ""
        /// Its tabs on this Mac.
        let pages = SignInPages()
        /// The page opened on each machine, by machine.
        var machinePages: [String: String] = [:]
        var opening: String?

        var id: String { service.id }

        init(service: Integrations.Service) {
            self.service = service
        }
    }

    private(set) var sites: [Site] = []
    /// The site in view; nil for the page.
    var selected: String?
    /// Where the page's card starts in the window, for the tabs to start there too.
    var contentX: CGFloat = 0

    var selectedSite: Site? { sites.first { $0.id == selected } }

    /// Signs in to `service` in a tab of its own (the one there is, if it's open).
    func open(_ service: Integrations.Service) {
        if !sites.contains(where: { $0.id == service.id }) {
            let site = Site(service: service)
            site.pages.open(service.site)
            sites.append(site)
        }
        selected = service.id
    }

    /// Closes a site's tab, and its pages on this Mac and the machines.
    func close(_ id: String, machines: Machines) {
        guard let index = sites.firstIndex(where: { $0.id == id }) else { return }
        let site = sites.remove(at: index)
        for (machine, page) in site.machinePages { machines.engine(machine)?.browser.close(page) }
        site.pages.closeAll()
        if selected == id { selected = sites.indices.contains(index) ? sites[index].id : sites.last?.id }
    }

    func closeAll(machines: Machines) {
        for site in sites { close(site.id, machines: machines) }
        selected = nil
    }
}
