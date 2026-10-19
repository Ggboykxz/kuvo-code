import AppKit

/// Runs the usage dashboard in the host app's menu bar. (Fork addition: it takes the place of
/// OpenUsage's app delegate, without the parts that belong to a standalone menu-bar app — the
/// single-instance lock, updates, analytics, the local API and activation-policy changes.)
///
/// On first run the welcome screen waits until the user clicks the menu bar item, so Kuvo Code's own
/// first launch isn't interrupted and nothing asks for Keychain access before the user picks providers.
@MainActor
public final class UsageMenuBar {
    public static let shared = UsageMenuBar()

    private(set) var container: AppContainer?
    private var statusItemController: StatusItemController?
    private var welcome: FirstLaunchWindowController?
    private var openHost: (@MainActor () -> Void)?
    private var started = false

    private init() {}

    /// Puts the item in the menu bar and starts refreshing. `openHostApp` brings the host's main
    /// window forward (the menus' "Open Kuvo Code").
    public func start(openHostApp: @escaping @MainActor () -> Void) {
        guard !started else { return }
        started = true
        openHost = openHostApp
        AppLog.bootstrap()
        // Snapshots refreshed during a pass are saved together at its end; save what's pending when
        // the host quits mid-pass (upstream does this in its app delegate's `applicationWillTerminate`).
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { UsageMenuBar.shared.container?.dataStore.flushPendingSnapshotWork() }
        }

        // The host's settings domain is never empty, so a missing schema stamp is what marks a first
        // run. Stamp it directly: the migrations convert old OpenUsage installs and must not run here.
        let defaults = UserDefaults.standard
        let isFreshInstall = defaults.object(forKey: SettingsMigrator.schemaVersionKey) == nil
        if isFreshInstall {
            defaults.set(SettingsSchema.current, forKey: SettingsMigrator.schemaVersionKey)
            FirstLaunchSetup.markPending()
        } else {
            SettingsMigrator.migrate()
        }
        AppearanceSetting.applyCurrent()

        Task {
            if ShellEnvironmentSnapshotStore.launchSnapshot == nil,
               !LoginShellEnvironment.shared.capturedSuccessfully {
                await Task.detached(priority: .userInitiated) {
                    _ = LoginShellEnvironment.shared.ensureCaptured()
                }.value
            }
            await finishLaunching(isFreshInstall: isFreshInstall)
        }
    }

    /// Refreshes the given providers now, skipping the cache: the host's accounts changed. Providers
    /// that are off stay off.
    func refresh(providerIDs: [String]) {
        guard let container, !FirstLaunchSetup.isPending() else { return }
        Task {
            for id in providerIDs where container.enablement.isEnabled(id) {
                await container.dataStore.refresh(providerID: id, force: true)
            }
        }
    }

    /// The host's accounts, by provider: the panel follows only these, and turns on the ones
    /// newly connected. Before the panel is up, they're kept for when it is.
    func connectedProvidersDidChange(_ providers: Set<String>) {
        guard let container else {
            pendingConnected = providers
            return
        }
        let added = container.availability.setConnected(providers)
        for card in container.providers.map(\.provider.id) where added.contains(ProviderAccountID.family(of: card)) {
            container.enablement.setEnabled(true, for: card)
        }
        // Ones turned on before their account was connected, refreshed now that it is.
        if !added.isEmpty { Task { await container.dataStore.refreshAll() } }
    }

    private var pendingConnected: Set<String>?

    /// Called each time the panel opens, for the host's own records.
    public var onPanelShown: (() -> Void)?

    /// True once the menu bar item is up.
    public var isRunning: Bool { statusItemController != nil }

    /// Where the panel can open.
    public enum Screen: Sendable {
        case dashboard, customize, settings
    }

    /// Opens the panel on `screen`, or the welcome while it's pending.
    public func open(_ screen: Screen) {
        let target: PopoverScreen = switch screen {
        case .dashboard: .dashboard
        case .customize: .customize
        case .settings: .settings
        }
        statusItemController?.open(target)
    }

    /// The menus' "Open <host>" action.
    static func openHostApp() {
        shared.openHost?()
        NSApp.activate()
    }

    private func finishLaunching(isFreshInstall: Bool) async {
        let showsWelcome = FirstLaunchSetup.isPending()
        // Nothing asks for Keychain access before the user picks providers on the welcome screen.
        if showsWelcome { KeychainAccessGuard.holdPopups() }
        let container = await AppContainer(isFreshInstall: isFreshInstall || showsWelcome)
        self.container = container
        if let pendingConnected {
            self.pendingConnected = nil
            connectedProvidersDidChange(pendingConnected)
        }
        let controller = StatusItemController(container: container)
        controller.onShow = { [weak self] in self?.onPanelShown?() }
        statusItemController = controller
        if showsWelcome {
            controller.clickInterceptor = { [weak self] in self?.showWelcome() ?? false }
        } else {
            container.startRefreshing()
        }
    }

    /// While the welcome is pending, a click on the menu bar item opens it instead of the panel.
    private func showWelcome() -> Bool {
        guard let container, FirstLaunchSetup.isPending() else { return false }
        if welcome == nil {
            let setup = FirstLaunchSetup(
                providers: ProviderCatalog.make().map(\.provider),
                cards: container.providers,
                enablement: container.enablement,
                dataStore: container.dataStore,
                isConnected: { [availability = container.availability] in availability.isConnected($0) }
            )
            // The hop lets the clicked button's action return before its window is torn down.
            welcome = FirstLaunchWindowController(setup: setup) { [weak self] in
                Task { self?.finishWelcome(container) }
            } onClose: { [weak self] in
                self?.welcome = nil
            }
        }
        welcome?.show()
        return true
    }

    private func finishWelcome(_ container: AppContainer) {
        welcome?.finish()
        welcome = nil
        KeychainAccessGuard.allowPopups()
        FirstLaunchSetup.clearPending()
        statusItemController?.clickInterceptor = nil
        // With nothing on, the empty dashboard already points to Customize.
        if container.enablement.enabledIDs?.isEmpty == true {
            container.onboarding.dismissCustomizeHint()
        }
        container.startRefreshing()
        MenuBarPopover.showHandler?()
    }
}
