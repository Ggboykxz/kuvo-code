import AppKit
import OpenCodeKit

extension AppModel {
    /// Connects every machine you've added, each in the background on its own.
    func startMachines() {
        #if DEBUG
        // KUVO_DEMO_MACHINE_ROOT: a folder of its own on machines (like .kuvo-code-demo), so a demo
        // copy's engine and browser there never touch the ones your own copy of the app runs.
        if let root = ProcessInfo.processInfo.environment["KUVO_DEMO_MACHINE_ROOT"], !root.isEmpty { RemoteEngineInstaller.root = root }
        #endif
        workspace.machines = Set(machines.list.map(\.id))
        // An agent on a machine browses with the machine's browser: the panel shows it, as it
        // shows its own browser for an agent here.
        workspace.onMachineBrowsing = { [weak self] machine, session in self?.utilities.revealMachineBrowser(machine, for: session) }
        BrowserTools.sessionFolder = { [weak self] session in self?.workspace.session(session)?.location.directory }
        // An agent showing you a file or folder: in the panel, beside its conversation.
        workspace.onShowInPanel = { [weak self] session, machine, path, isFolder in
            let url = machine.map { RemoteFolder.url(RemoteFolder.folder(path, on: $0)) } ?? URL(filePath: path, directoryHint: isFolder ? .isDirectory : .notDirectory)
            self?.utilities.showInPanel(url, isFolder: isFolder, for: session)
        }
        // An agent asks you for something in its browser: who's asking, and on a machine, the
        // connection that brings the ask here.
        browserAsks.onChange = { [weak self] sessions in self?.workspace.askingInBrowser = sessions }
        workspace.botName = { [weak self] session in self?.bots.bot(forSession: session)?.name }
        // A bot on this Mac browses in tabs of its own.
        BrowserAgent.botOwner = { [weak self] session in
            self?.bots.bot(actingAs: session).flatMap { $0.machine == nil ? $0.id : nil }
        }
        browserAsks.askerName = { [weak self] session in
            self?.bots.bot(forSession: session)?.name ?? self?.workspace.session(session)?.title
        }
        browserAsks.tab = { [weak self] ask in
            guard let session = ask.session else { return nil }
            return self?.groups.group(seat: session).map { BotGroups.tabKey($0.id) } ?? session
        }
        workspace.onBrowserAsk = { [weak self] session, machine in
            guard let self else { return }
            let name = bots.bot(forSession: session)?.name ?? workspace.session(session)?.title ?? "The agent"
            browserAsks.noteAsker(name, session: session, machine: machine)
            if let machine { machines.engine(machine)?.browser.expectAsk() }
        }
        utilities.machineBrowser = { [weak self] machine in self?.machines.engine(machine)?.browser }
        // A machine whose connection dropped while the Mac slept, and that gave up trying, gets
        // another go once it's awake and the network is back.
        NotificationCenter.default.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wakeMachines() }
        }
        for engine in machines.engines.values { connect(engine) }
    }

    private func wakeMachines() {
        for engine in machines.engines.values where !engine.isRetrying {
            if case .failed = engine.state { Task { await reconnect(engine) } }
        }
    }

    /// Adds a machine (a host from `~/.ssh/config`, or `user@host`) and connects to it.
    @discardableResult
    func addMachine(_ destination: String) -> MachineEngine {
        let engine = machines.add(destination)
        workspace.machines = Set(machines.list.map(\.id))
        connect(engine)
        return engine
    }

    /// Connects again now, rather than waiting for the connection to come back by itself.
    func reconnectNow(_ engine: MachineEngine) {
        // Already connecting.
        switch engine.state {
        case .starting, .downloading: return
        default: break
        }
        engine.disconnect()
        workspace.forget(engine.machine.id)
        connect(engine)
    }

    /// Installs and starts a machine's engine over SSH, with what it gets from this Mac, and
    /// feeds its sessions into the workspace.
    func connect(_ engine: MachineEngine) {
        let machine = engine.machine.id
        // Its pages are the panel's browser tabs while a session there is in view.
        engine.browser.onPages = { [weak self] pages in self?.utilities.syncMachinePages(machine, pages) }
        engine.browser.onActive = { [weak self] page, byAgent, session in self?.utilities.machinePageActive(machine, page: page, byAgent: byAgent, session: session) }
        engine.browser.sessionInView = { [weak self] in self?.utilities.sessionInView }
        // What its agents ask you for, answered in the window, filled in there.
        engine.browser.onAsk = { [weak self, weak browser = engine.browser] ask in
            self?.browserAsks.add(ask) { answer in browser?.answer(ask.id, answer) }
        }
        engine.browser.onAskClosed = { [weak self] id in self?.browserAsks.closed(id) }
        engine.onEvent = { [weak self] event in self?.workspace.handle(event, machine: machine) }
        engine.onReconnect = { [weak self] in _ = await self?.workspace.refresh(engine) }
        engine.onExit = { [weak self] in
            self?.workspace.forget(machine)
            Task { await self?.reconnect(engine) }
        }
        Task { await start(engine) }
    }

    /// After a dropped connection (the Mac slept, the machine restarted): tries further apart
    /// each time, for half an hour, while its sessions wait.
    private func reconnect(_ engine: MachineEngine) async {
        engine.isRetrying = true
        defer { engine.isRetrying = false }
        for delay in [3, 10, 30, 60, 120, 120, 300, 300, 300, 300, 300] {
            try? await Task.sleep(for: .seconds(delay))
            // Removed, or connected again some other way (Try Again).
            guard machines.engine(engine.machine.id) === engine, case .failed = engine.state else { return }
            await start(engine)
            if engine.isReady { return }
        }
    }

    private func start(_ engine: MachineEngine) async {
        // It takes this Mac's accounts and settings, so this Mac's engine comes first.
        for _ in 0..<240 where api == nil { try? await Task.sleep(for: .milliseconds(250)) }
        var environment = await machineEnvironment().environment
        // The browser tools, with the machine's own browser.
        environment["OPENCODE_CONFIG_CONTENT"] = AppModel.merged(MachineBrowserInstaller.engineConfig, into: environment["OPENCODE_CONFIG_CONTENT"])
        let launch = MachineEngine.Launch(environment: environment, helper: MachineBrowserInstaller.helper)
        await engine.start(launch, cache: AppInfo.supportDirectory.appending(path: "engine-linux"))
        // Its sessions, once it's up: tried again a few times, as they're what makes them live.
        for wait in [0, 2, 5, 10, 20] where engine.isReady {
            try? await Task.sleep(for: .seconds(wait))
            guard engine.isReady else { break }
            if await workspace.refresh(engine) { break }
        }
    }

    /// Closes the connection to a machine. Its engine stops too, unless a session there is still
    /// working: then it carries on, and its work is there when you connect again.
    func disconnect(_ engine: MachineEngine) {
        engine.browser.reset()
        utilities.closeMachineBrowser(engine.machine.id)
        let busy = workspace.isRunning(on: engine.machine.id)
        if busy { engine.disconnect() } else { Task { await engine.stopEngine() } }
        workspace.forget(engine.machine.id)
    }

    /// Stops a machine's engine and forgets the machine, and its sessions' tabs with it. Its
    /// sessions stay on the machine, for when it's added again.
    func removeMachine(_ id: String) {
        machines.engine(id)?.browser.reset()
        browserAsks.closeAll(on: id)
        utilities.closeMachineBrowser(id)
        machines.remove(id)
        workspace.machines = Set(machines.list.map(\.id))
        workspace.forget(id, forGood: true)
    }

    /// When the app quits: each machine's engine stops, unless a session there is still working,
    /// which carries on there while this Mac is off, or a bot there has a wake-up waiting.
    func stopMachines() {
        for engine in machines.engines.values where engine.isReady {
            let busy = workspace.isRunning(on: engine.machine.id)
            engine.disconnect()
            if !busy { RemoteServer.stopNow(on: engine.machine.connection, unlessWaking: true) }
        }
    }

    /// What a machine's engine gets from this Mac: the accounts that can go as environment
    /// variables (API keys, a GitHub Copilot sign-in), held in its memory and never written to its
    /// disk, and this Mac's engine settings, minus what only makes sense here. `staysHere` names
    /// the accounts that can't go, like a ChatGPT sign-in.
    func machineEnvironment() async -> (environment: [String: String], staysHere: [String]) {
        var environment: [String: String] = [:]
        var staysHere: [String] = []
        if let api, let credentials = try? await api.credentialSecrets() {
            // The catalog's, or, while it's still loading (its plugins can be slow), asked for
            // here, for a few seconds at most.
            var integrations = catalog.integrations
            if integrations.isEmpty {
                integrations = await withTaskGroup(of: [Integration]?.self) { group in
                    group.addTask { try? await api.integrations() }
                    group.addTask { try? await Task.sleep(for: .seconds(8)); return nil }
                    let first = await group.next() ?? nil
                    group.cancelAll()
                    return first ?? []
                }
            }
            for credential in credentials where credential.active {
                let integration = integrations.first { $0.id == credential.integrationID }
                let name = integration?.name ?? credential.integrationID
                guard let variable = integration?.environmentVariables.first else {
                    staysHere.append(name)
                    continue
                }
                if let key = credential.value.key, !key.isEmpty {
                    environment[variable] = key
                } else if credential.integrationID == "github-copilot", let token = credential.value.access, !token.isEmpty {
                    environment[variable] = token
                } else {
                    staysHere.append(name)
                }
            }
        }
        if let data = try? Data(contentsOf: engineConfig.file),
           var settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            // A shell or a worktree folder on this Mac means nothing on the machine, nor do
            // integrations that use this Mac's apps.
            for key in ["$schema", "shell", "worktree"] { settings.removeValue(forKey: key) }
            if var mcp = settings["mcp"] as? [String: Any], var servers = mcp["servers"] as? [String: Any] {
                for id in Integrations.macOnly { servers.removeValue(forKey: id) }
                mcp["servers"] = servers
                settings["mcp"] = mcp
            }
            if let json = try? JSONSerialization.data(withJSONObject: settings) {
                environment["OPENCODE_CONFIG_CONTENT"] = String(decoding: json, as: UTF8.self)
            }
        }
        // Keys you brought for the integrations machines run, in memory as on this Mac: not
        // those that stay on this Mac (an app's secret for a sign-in, say).
        let here = Set(Integrations.macOnly.map { IntegrationKeys.variable($0, "") })
        let keys = await Task.detached { IntegrationKeys.environment }.value.filter { name, _ in !here.contains { name.hasPrefix($0) } }
        environment.merge(keys) { _, key in key }
        // What some providers need until opencode handles it, as on this Mac.
        let compatibility = ProviderCompatibility.config
        if !compatibility.isEmpty {
            environment["OPENCODE_CONFIG_CONTENT"] = AppModel.merged(compatibility, into: environment["OPENCODE_CONFIG_CONTENT"])
        }
        return (environment, staysHere)
    }
}
