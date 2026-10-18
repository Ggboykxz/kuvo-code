import AppKit
import OpenCodeKit
import os

/// Owns the engine (the opencode server) and the stores fed by it.
@Observable
final class AppModel {
    enum EngineState: Equatable {
        case preparing
        case downloading(progress: Double)
        case starting
        case ready
        case failed(String)
    }

    private(set) var engine = EngineState.preparing
    private(set) var api: OpenCodeAPI?
    /// False while the live event feed is down (the UI shows it, and re-syncs after).
    private(set) var isLive = false

    /// The login shell's environment (PATH and the like), for the engine and terminals.
    private(set) var shellEnvironment = ProcessInfo.processInfo.environment

    let catalog = Catalog()
    /// The right panel's tools; one window, so one set.
    let utilities = Utilities()
    /// What the agent asks you for while it browses: sign-ins, codes, steps only you can do.
    let browserAsks = BrowserAsks()
    /// The panel's browser as MCP tools for the agent.
    @ObservationIgnored private(set) lazy var browserTools = BrowserToolServer(agent: BrowserAgent(utilities: utilities, asks: browserAsks))
    let workspace = Workspace()
    /// Other computers whose engines run over SSH, next to this Mac's.
    let machines = Machines()
    let usage = UsageAccounts()
    /// Bots: named agents with one job each, on this Mac or a machine.
    let bots = Bots()
    let groups = BotGroups()
    /// Kuvo Code for iPhone's way in (off until it's switched on; see PhoneLink).
    let phoneLink = PhoneLink()
    /// The engine's settings file, for Settings.
    @ObservationIgnored private(set) lazy var engineConfig = EngineConfig(file: engineFolders.configFile)
    /// Engines to start again with new settings once nothing's at work in them: "" for this Mac's,
    /// else a machine's ID (see `renewEngines`).
    @ObservationIgnored var renewals: Set<String> = []
    @ObservationIgnored var renewing: Task<Void, Never>?
    /// Skills added in Settings, beside the settings file: the engine reads them for every project.
    var skillsFolder: URL { engineFolders.configFile.deletingLastPathComponent().appending(path: "skills") }
    /// Brings the main window back (set by the window itself; the usage menu's "Open Kuvo Code").
    var openMainWindow: (() -> Void)?
    /// Settings fill the main window in place of the sessions while this is on.
    var showsSettings = false
    /// Settings' tabs: the page, and the sites you're signing in to.
    let settingsTabs = SettingsTabs()

    /// Shows Settings in the main window, on `page` if one is given (otherwise the last one open).
    func openSettings(_ page: SettingsPage? = nil) {
        if let page { settingsTabs.show(page) }
        if page == .accounts { Analytics.shared.onboardingStep("accounts") }
        #if DEBUG
        let background = ProcessInfo.processInfo.environment["KUVO_DEMO_BACKGROUND"] != nil
        #else
        let background = false
        #endif
        if !background {
            openMainWindow?()
            NSApp.activate()
        }
        showsSettings = true
    }

    /// Something to open from outside the window: a folder dropped on the Dock icon or opened with
    /// Kuvo Code, or a pick from the Dock menu. The main window takes it when it's there.
    enum Request: Equatable {
        case folder(String)
        case session(String)
        case newSession
        /// A shared bot's file, opened in Finder: New Bot, from it.
        case bot(BotRecipe)
    }
    var request: Request?

    /// Shows the main window and hands it `request`.
    func open(_ request: Request) {
        #if DEBUG
        // A demo copy launched with KUVO_DEMO_BACKGROUND stays behind, so it never takes the keyboard
        // (opening the window activates the app too).
        let background = ProcessInfo.processInfo.environment["KUVO_DEMO_BACKGROUND"] != nil
        #else
        let background = false
        #endif
        if !background {
            openMainWindow?()
            NSApp.activate()
        }
        self.request = request
    }

    private var server: ServerProcess?
    private var eventTask: Task<Void, Never>?
    /// When the engine was last started again on its own, after stopping while it ran.
    private var automaticRestarts: [Date] = []
    /// The engine had been running when it failed (it stopped, rather than couldn't start).
    private(set) var engineStoppedWhileRunning = false
    /// This start of the engine, new with each start and each stop: an earlier engine's exit,
    /// coming in late as it stops, isn't taken for this one's, and a start that was stopped or
    /// started over while it waited gives up.
    private var launch = UUID()
    /// The Mac waking from sleep, watched once for the machines (see `startMachines`).
    @ObservationIgnored var wakeWatch: (any NSObjectProtocol)?
    private let log = Logger(subsystem: "run.kuvo.code", category: "engine")

    private var engineFolders: EngineFolders {
        EngineFolders(root: AppInfo.supportDirectory.appending(path: "opencode"))
    }

    /// Puts the usage panel in the menu bar. It reads the engine's database for spend, so it
    /// starts with the app, not with the engine.
    func startUsage() {
        usage.start(engineData: engineFolders.dataDirectory) { [weak self] in
            self?.openMainWindow?()
        }
    }

    /// The engine this Mac runs (KUVO_OPENCODE_BINARY's, or the one installed), once there is one.
    var engineBinary: URL? {
        if let override = ProcessInfo.processInfo.environment["KUVO_OPENCODE_BINARY"] { return URL(filePath: override) }
        return installer.installed()
    }

    private var installer: EngineInstaller {
        EngineInstaller(root: AppInfo.supportDirectory.appending(path: "engine"))
    }

    /// Downloads the engine if needed, starts it, and connects the stores.
    func start() async {
        // Already on its way (restart stops it first).
        switch engine {
        case .ready, .starting, .downloading: return
        case .preparing, .failed: break
        }
        let launch = UUID()
        self.launch = launch
        engineStoppedWhileRunning = false
        // How far it got, for analytics when it fails: the download, the launch, or the connection.
        var stage = "download"
        let began = SuspendingClock.now
        var downloaded = false
        do {
            // Set KUVO_OPENCODE_BINARY to run a local opencode build instead of the pinned download.
            async let environment = ShellEnvironment.load()
            let binary: URL
            if let override = ProcessInfo.processInfo.environment["KUVO_OPENCODE_BINARY"] {
                binary = URL(filePath: override)
            } else if let installed = installer.installed() {
                binary = installed
            } else {
                engine = .downloading(progress: 0)
                downloaded = true
                binary = try await installer.install { progress in
                    Task { @MainActor in
                        if case .downloading = self.engine { self.engine = .downloading(progress: progress) }
                    }
                }
                // Stopped, or started over, while it waited: the newer start carries on.
                guard launch == self.launch else { return }
            }

            engine = .starting
            stage = "launch"
            var shell = await environment
            guard launch == self.launch else { return }
            shellEnvironment = shell
            // Bots' wake-up command, by name, and where their folders are; and the launcher
            // integrations' servers run with.
            try? Launcher.install(in: Bots.command.deletingLastPathComponent(), engine: binary)
            shell["PATH"] = Bots.command.deletingLastPathComponent().path + ":" + (shell["PATH"] ?? "/usr/bin:/bin")
            shell["KUVO_BOTS"] = Bots.root.path
            // Keys you brought for integrations, in the files their settings name with {file:…}
            // (not the engine's environment, where the agent's commands would see them), and a
            // folder for what their servers keep (a sign-in).
            #if DEBUG
            // KUVO_DEMO_INTEGRATION_KEY=<id>|<NAME>|<value>: saves that key as Add Key… does
            // (no value removes it).
            if let spec = ProcessInfo.processInfo.environment["KUVO_DEMO_INTEGRATION_KEY"] {
                let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                if parts.count == 3 { IntegrationKeys.set(parts[2], for: IntegrationKeys.variable(parts[0], parts[1])) }
            }
            #endif
            // Read off the main thread: the keychain can wait on you (a prompt to allow it).
            await Task.detached { IntegrationKeys.writeFiles() }.value
            let integrations = AppInfo.supportDirectory.appending(path: "integrations")
            try? FileManager.default.createDirectory(at: integrations, withIntermediateDirectories: true)
            shell["KUVO_INTEGRATIONS"] = integrations.path
            // The settings file as it is now (it can change while the engine is down), with web
            // search that works unless it chose otherwise.
            engineConfig.addDefaults()
            Integrations.upgrade(engineConfig)
            MCPSettings.upgrade(engineConfig)
            // What some providers need until opencode handles it (see ProviderCompatibility).
            let compatibility = ProviderCompatibility.config
            if !compatibility.isEmpty { shell["OPENCODE_CONFIG_CONTENT"] = Self.merged(compatibility, into: shell["OPENCODE_CONFIG_CONTENT"]) }
            // The browser tools, for the engine to connect to. Without them the agent
            // still works, just without the browser.
            do {
                _ = try await browserTools.start()
                if let config = browserTools.engineConfig { shell["OPENCODE_CONFIG_CONTENT"] = Self.merged(config, into: shell["OPENCODE_CONFIG_CONTENT"]) }
            } catch {
                log.error("Browser tools didn't start: \(error.localizedDescription, privacy: .public)")
            }
            guard launch == self.launch else { return }
            let server = try await ServerProcess.start(
                executable: binary,
                folders: engineFolders,
                environment: shell,
                onExit: { status in Task { @MainActor in self.engineExited(status: status, launch: launch) } }
            )
            guard launch == self.launch else {
                server.stop()
                return
            }
            self.server = server
            stage = "connect"
            let api = OpenCodeAPI(endpoint: server.endpoint)
            try await waitUntilReady(api)
            // It stopped (and said why), or was stopped, while it loaded.
            guard launch == self.launch else { return }
            self.api = api
            catalog.api = api
            Analytics.shared.catalog = catalog
            workspace.api = api
            workspace.machineAPI = { [weak self] machine in self?.machines.engine(machine)?.api }
            bots.app = self
            groups.app = self
            workspace.botSessions = bots.sessionIDs
            workspace.seats = groups.seatIDs
            usage.api = api
            engine = .ready
            #if DEBUG
            E2E.note(server.endpoint)
            #endif
            phoneLink.readyMachines = { [weak self] in self?.machines.engines.values.filter(\.isReady) ?? [] }
            phoneLink.bots = bots
            phoneLink.browserAsks = browserAsks
            phoneLink.groups = groups
            phoneLink.machineName = { [weak self] id in self?.machines.list.first { $0.id == id }?.name }
            phoneLink.start(endpoint: server.endpoint)
            Analytics.shared.trackOnce("engine_ready", ["seconds": Int((SuspendingClock.now - began).components.seconds), "downloaded": downloaded])
            listen(to: api)
            Task { await usage.sync() }
            // In parallel: the catalog can wait on the engine's plugins (and they on a
            // macOS permission prompt); sessions shouldn't wait with it.
            async let catalogLoaded: Void = catalog.refresh()
            async let workspaceLoaded: Void = workspace.refresh()
            // Machines start once this Mac's engine is up (they get its accounts and settings),
            // without waiting on its catalog.
            await workspaceLoaded
            guard launch == self.launch else { return }
            startMachines()
            bots.startWaking()
            groups.startMeetings()
            groups.resumeWork()
            await catalogLoaded
        } catch {
            // Stopped, or started over, meanwhile.
            guard launch == self.launch else { return }
            // One that stopped while it loaded says so, with what it wrote, rather than that it
            // can't be reached.
            var reason = error.localizedDescription
            if let server {
                let output = String(server.recentOutput.trimmingCharacters(in: .whitespacesAndNewlines).suffix(600))
                if let status = server.exitStatus {
                    reason = ServerProcessError.exited(status: status, output: output).localizedDescription
                } else if !output.isEmpty {
                    reason += "\n\n" + output
                }
            }
            log.error("Engine failed to start: \(reason, privacy: .public)")
            Analytics.shared.track("engine_failed", ["reason": stage])
            // Nothing is left running (a server that never got ready is stopped). A start after an
            // automatic restart failing means the engine stopped.
            stop()
            automaticRestarts.removeAll { $0 < .now.addingTimeInterval(-300) }
            engineStoppedWhileRunning = !automaticRestarts.isEmpty
            engine = .failed(reason)
        }
    }

    /// `config` merged over any inline config already in the environment.
    static func merged(_ config: [String: Any], into existing: String?) -> String {
        var base = existing.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
        func merge(_ new: [String: Any], into old: inout [String: Any]) {
            for (key, value) in new {
                if let value = value as? [String: Any], var current = old[key] as? [String: Any] {
                    merge(value, into: &current)
                    old[key] = current
                } else {
                    old[key] = value
                }
            }
        }
        merge(config, into: &base)
        // Sorted, so the same settings read the same each time (a machine's engine is started
        // over when what it started with reads differently).
        let data = (try? JSONSerialization.data(withJSONObject: base, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    func restart() async {
        stop()
        engine = .preparing
        await start()
    }

    func stop() {
        // A start still on its way gives up, and the stopped engine's exit is expected.
        launch = UUID()
        #if DEBUG
        E2E.forget()
        #endif
        eventTask?.cancel()
        eventTask = nil
        server?.stop()
        server = nil
        api = nil
        isLive = false
        phoneLink.stop()
    }

    /// The server answers 503 until it has loaded.
    private func waitUntilReady(_ api: OpenCodeAPI) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while true {
            do {
                _ = try await api.info()
                return
            } catch let error as ServerError where error.status == 503 {
                if ContinuousClock.now > deadline { throw error }
                try await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func listen(to api: OpenCodeAPI) {
        eventTask = Task { [weak self] in
            for await update in api.events.updates() {
                guard let self else { return }
                switch update {
                case .connected:
                    // Missed events aren't replayed: re-read everything on screen.
                    let wasLive = isLive
                    isLive = true
                    if !wasLive {
                        await catalog.refresh()
                        await workspace.resync()
                    }
                case .disconnected:
                    isLive = false
                case .event(let event):
                    // The file changed, here or elsewhere: show what it says now.
                    if event.type == "config.updated" { engineConfig.reload() }
                    // A sign-in made or renewed here reaches the machines, and an account
                    // connected, signed out of or switched reaches their engines.
                    if event.type == "credential.updated" { syncSignIns() }
                    if event.type == "credential.updated" || event.type == "credential.switched" { updateMachineAccounts() }
                    catalog.handle(event)
                    workspace.handle(event)
                    usage.handle(event)
                }
            }
        }
    }

    private func engineExited(status: Int32, launch: UUID) {
        // One stopped (for a restart, or as the app quits) exits a moment later, after the stop.
        guard launch == self.launch else { return }
        // One still starting fails `start` as it stops (its handshake or first call does), which
        // says why with what it wrote.
        guard engine == .ready else { return }
        let output = server?.recentOutput.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        log.error("Engine exited with status \(status): \(output, privacy: .public)")
        stop()
        // It's started again, as it was, unless it has stopped like this a few times in the last
        // minutes: then it's for you to see why.
        automaticRestarts.removeAll { $0 < .now.addingTimeInterval(-300) }
        if automaticRestarts.count < 3 {
            automaticRestarts.append(.now)
            Task { await restart() }
            return
        }
        engineStoppedWhileRunning = true
        engine = .failed("It stopped unexpectedly (exit code \(status)), and again after starting over.\(output.isEmpty ? "" : "\n\n" + String(output.suffix(600)))")
    }
}

