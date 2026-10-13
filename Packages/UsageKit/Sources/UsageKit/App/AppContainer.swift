import Foundation
import KeyboardShortcuts
import Observation

/// Composition root: owns the (constant) registry and the (mutable) stores, injected
/// into the SwiftUI environment.
@MainActor
@Observable
final class AppContainer {
    let registry: WidgetRegistry
    let layout: LayoutStore
    let dataStore: WidgetDataStore
    /// Single source of truth for which providers the user has turned off. Both stores consult it (via
    /// injected closures) and the Customize provider list drives it.
    let enablement: ProviderEnablementStore
    /// Providers that need a user-supplied API key (currently OpenRouter and Z.ai), conforming to
    /// `APIKeyManaging`. Each matching Customize provider detail shows an API Key section and writes
    /// changes through the capability. Empty when no installed provider needs a user key.
    let apiKeyProviders: [any APIKeyManaging]
    /// Quota pace notification preferences (three independent triggers). Drives the Settings section
    /// and is read by `WidgetDataStore.evaluateNotifications`.
    let notificationSettings: NotificationSettingsStore
    /// Source of truth for the popover's transparency: the persisted Increase Transparency toggle, the
    /// ephemeral secret-code easter-egg state, and the system accessibility flags it yields to. Read by both
    /// the SwiftUI surface and the AppKit panel (`StatusItemController`).
    let transparency: PopoverTransparencyStore
    /// The menu bar's screen-share privacy mode: the persisted Hide From Screen Share toggle
    /// plus the live capture signal. Read by `StatusItemImageUpdater` to swap the strip for the
    /// wordmark while the screen is shared or recorded.
    let privacy: MenuBarPrivacyStore
    /// One-time onboarding state (the first-run Customize hint card). Only ever marked pending by
    /// `FirstRunSeeder` on a fresh install, so existing installs never see the card.
    let onboarding: OnboardingStore
    /// Claims Codex rate-limit reset credits from the resets popover (the app's only provider-API
    /// write). Each service shares its card's auth store and usage client. The view tree selects
    /// the matching service from `\.codexResetClaims` for each card's resets popover.
    let codexResetClaims: [String: CodexResetClaimService]
    /// The provider runtimes, kept so on-demand credential detection (the welcome screen and the
    /// Customize "Reset All" reseed) can re-probe `hasLocalCredentials()` on every card.
    let providers: [ProviderRuntime]
    /// `nil` until `startRefreshing()`, which the welcome screen delays until the user has picked providers.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// The new-provider credential-detection pass (see `NewProviderSeeder`); `nil` unless this launch is
    /// the first with a provider the install has never seen.
    private let newProviderTask: Task<Void, Never>?
    /// Persists a fresh `ShellEnvironmentSnapshot` once the login-shell capture completes, so the next
    /// launch can read shell-exported facts (provider home overrides) even when its own capture is slow.
    private let shellEnvironmentSnapshotTask: Task<Void, Never>

    /// `isFreshInstall` must be captured by the caller BEFORE `SettingsMigrator.migrate()` runs (the
    /// migrator's schema stamp makes the defaults domain non-empty). See `AppDelegate`.
    init(isFreshInstall: Bool = false) async {
        // Capture the user's login-shell environment off-main so provider keys exported in a shell
        // profile (e.g. OPENROUTER_API_KEY) resolve in a Finder/Dock-launched build, not only when
        // run from a terminal. Warmed here so the first refresh finds the cache ready.
        LoginShellEnvironment.shared.prewarm()
        // Once the capture lands, persist its identity-relevant facts so the NEXT launch has them
        // even if that launch's own capture is slow (see `ShellEnvironmentSnapshot`).
        self.shellEnvironmentSnapshotTask = ShellEnvironmentSnapshotStore(defaults: .standard).startRefreshTask()
        // The launch account pass: which account is signed in at each family's default home. Feeds
        // the snapshot cache's account stamp and reconciles the account registry.
        let accountAssembly = await ProviderAccountAssembly.make(waitsForLoginShell: true)

        let providers = ProviderCatalog.make(
            claudeCards: accountAssembly.claudeCards,
            codex: accountAssembly.codex,
            claudeIdentityKeys: accountAssembly.identityKeysByCard
        )
        let registry = WidgetRegistry.from(providers)
        let apiKeyProviders = providers.compactMap { $0 as? any APIKeyManaging }
        let enablement = ProviderEnablementStore()
        let notificationSettings = NotificationSettingsStore()
        let accountDefaults: ([String]) -> [String] = { metricIDs in
            DefaultLayout.expandingAccounts(metricIDs, providerIDs: registry.providers.map(\.id))
        }
        let layout = LayoutStore(
            registry: registry,
            defaultMetricIDs: accountDefaults(DefaultLayout.metricIDs),
            defaultPinnedMetricIDs: accountDefaults(DefaultLayout.pinnedMetricIDs),
            defaultExpandedMetricIDs: accountDefaults(DefaultLayout.expandedMetricIDs),
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) }
        )
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: providers,
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) },
            orderedDescriptors: { [layout] in layout.visiblePlaced.compactMap { layout.descriptor(for: $0) } },
            notificationSettings: { notificationSettings },
            providerIdentityKeys: accountAssembly.identityKeysByCard
        )
        // Re-enabling a provider should fetch it promptly, so clear any leftover failure backoff before
        // the enablement wake refreshes. `weak` breaks the cycle (dataStore already captures enablement).
        enablement.onProviderEnabled = { [weak dataStore] id in dataStore?.clearFailureBackoff(for: id) }
        enablement.onChange = { [weak dataStore] in
            dataStore?.providerEnablementDidChange()
        }
        // Fresh installs start with nothing on; the welcome screen turns on the user's picks. No-op on
        // every later launch.
        let onboarding = OnboardingStore()
        FirstRunSeeder.seedIfNeeded(
            isFreshInstall: isFreshInstall,
            providers: providers,
            enablement: enablement,
            onboarding: onboarding
        )
        // Providers added by an update get the same credential detection on their first launch — enabled
        // only when the user actually has the tool. Runs every launch; a no-op unless the registry has a
        // provider this install has never seen (fresh installs were just baselined by FirstRunSeeder).
        self.newProviderTask = NewProviderSeeder.reconcileIfNeeded(
            providers: providers,
            enablement: enablement
        )
        self.providers = providers
        self.onboarding = onboarding
        self.registry = registry
        self.enablement = enablement
        self.apiKeyProviders = apiKeyProviders
        self.notificationSettings = notificationSettings
        self.layout = layout
        self.dataStore = dataStore

        // The resets popover's claim service, sharing the Codex provider's credential loading and HTTP
        // client so the claim's auth can't drift from the provider's. A successful claim forces a Codex
        // refresh so the meters and credit count reconcile before the popover shows its result. The
        // forced refresh returns `.skipped` when another refresh already owns the provider — and that
        // in-flight probe may carry *pre-claim* usage — so retry until this refresh actually runs
        // (bounded; the racing probe finishes in seconds).
        self.codexResetClaims = Dictionary(uniqueKeysWithValues: providers.compactMap { $0 as? CodexProvider }.map { codex in
            (codex.provider.id, CodexResetClaimService(
                authStore: codex.authStore,
                usageClient: codex.usageClient,
                refreshAfterClaim: { [weak dataStore] in
                    // The bound must outlast the provider's slowest refresh: usage fetch (10s timeout)
                    // + token refresh (15s) + usage retry (10s) + reset-credit fetch (10s) ≈ 45s. The
                    // common race (the periodic timer's probe) clears in a couple of seconds; the
                    // pathological one keeps the popover's honest "Resetting…" up rather than showing
                    // a success banner over pre-claim meters. A `.failed` probe is retried a few times
                    // too — a transient flake right after the claim must not strand pre-claim meters
                    // behind a success banner — before giving up loudly (the provider error already
                    // shows on the card, so the staleness isn't silent).
                    var failures = 0
                    for attempt in 0..<45 {
                        guard let dataStore else { return }
                        switch await dataStore.refresh(providerID: codex.provider.id, force: true) {
                        case .refreshed, .cacheHit, .backedOff:
                            return
                        case .failed:
                            failures += 1
                            guard failures < 3 else {
                                AppLog.error(LogTag.plugin("codex"), "post-claim refresh failed \(failures) times; meters may lag until the next cycle")
                                return
                            }
                            try? await Task.sleep(for: .seconds(2))
                        case .skipped:
                            AppLog.info(LogTag.plugin("codex"), "post-claim refresh waiting out an in-flight refresh (attempt \(attempt + 1))")
                            try? await Task.sleep(for: .seconds(1))
                        }
                    }
                    AppLog.error(LogTag.plugin("codex"), "post-claim refresh kept being skipped; meters may lag until the next cycle")
                }
            ))
        })

        self.transparency = PopoverTransparencyStore()
        self.privacy = MenuBarPrivacyStore()
        // Become the notification-center delegate so banners show while frontmost — a menu-bar accessory
        // effectively always is. Notification authorization is requested the first time a trigger is
        // turned on in Settings, not at launch — triggers default off. No-op under tests.
        AppNotifications.shared.registerAsDelegate()
    }

    deinit {
        refreshTask?.cancel()
        newProviderTask?.cancel()
        shellEnvironmentSnapshotTask.cancel()
    }

    func startRefreshing() {
        guard refreshTask == nil else { return }
        refreshTask = Self.startPeriodicRefresh(dataStore: dataStore)
    }

    /// Re-runs first-launch credential detection on demand — the enablement half of the Customize
    /// "Reset All" action (`LayoutStore.resetToDefault` handles metrics, order, pins, and expansion).
    /// Delegates to `FirstRunSeeder.reseed`; returns its detection task so callers can await it.
    @discardableResult
    func reseedEnabledProviders() -> Task<Void, Never> {
        FirstRunSeeder.reseed(providers: providers, enablement: enablement)
    }

    /// The Settings "Reset All Settings" action: restores every user preference the container owns to
    /// its default. Composes the Customize reset (`resetToDefault` + provider reseed) with the
    /// Settings-only preferences. Deliberately untouched: provider credentials and cached usage
    /// snapshots. Launch at Login lives outside the container; the Settings screen resets it alongside
    /// this call.
    func resetAllSettings() {
        layout.resetToDefault()
        // The menu-bar Icon Style is a Settings preference, not part of the Customize layout reset.
        layout.menuBarStyle = .text
        reseedEnabledProviders()
        dataStore.resetDisplaySettings()
        notificationSettings.resetToDefaults()
        transparency.resetToDefaults()
        privacy.hideUsageWhileScreenSharing = false
        // Removing an `@AppStorage` key restores its declared default; the Settings screen's
        // `@AppStorage` properties observe the change. New settings must be added here.
        for key in [
            AppearanceSetting.key, TimeFormatSetting.key, DensitySetting.key,
            ReduceAnimationsSetting.key, LogLevelSetting.key, TotalSpendSetting.key,
            TotalSpendSetting.periodKey, TotalSpendSetting.metricKey,
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        KeyboardShortcuts.reset(.togglePopover)
        AppearanceSetting.applyCurrent()
        AppLog.reloadLevel()
        AppLog.info(.config, "All settings reset to defaults")
    }

    /// Drives live updates: refresh on launch, then again every refresh interval. Each pass honors the
    /// cache, so it only hits the network once a snapshot has actually expired. `@Observable` propagates
    /// the resulting snapshot changes to the menu-bar label and any open widgets, so the UI refreshes on
    /// its own instead of only when the popover opens.
    ///
    /// Between passes the loop sleeps via `RefreshWakeSignal`, which wakes it early when the user
    /// enables/disables a provider so a newly-enabled provider is fetched promptly instead of waiting out
    /// the full interval. The signal subscribes BEFORE the first pass and buffers, so an enablement change
    /// landing while a pass is still running (`NewProviderSeeder`, the Customize "Reset All" reseed —
    /// both of which typically finish faster than the network fetches) is
    /// never lost. Each pass still honors the cache (and the per-provider failure backoff), so an early
    /// wake only hits the network for a provider whose snapshot has actually expired.
    ///
    /// The wake is deliberately scoped to `ProviderEnablementStore.didChangeNotification` — NOT the
    /// firehose `UserDefaults.didChangeNotification`, which fires for the app's own snapshot-cache writes
    /// and unrelated global-domain changes from other processes. Waking on
    /// that, with no minimum interval before re-refreshing, collapsed the fixed 5-minute cadence into a
    /// refresh storm.
    private static func startPeriodicRefresh(dataStore: WidgetDataStore) -> Task<Void, Never> {
        Task {
            let wakeSignal = RefreshWakeSignal()
            while !Task.isCancelled {
                await dataStore.refreshAll()
                // Re-evaluate quota pace milestones every tick — after the refresh so it sees fresh data,
                // and on every loop (not just on a fetch) so pace worsening from elapsed time alone still
                // alerts even with the popover closed.
                await dataStore.evaluateNotifications()
                await wakeSignal.waitForWake(timeout: RefreshSetting.interval)
            }
        }
    }
}
