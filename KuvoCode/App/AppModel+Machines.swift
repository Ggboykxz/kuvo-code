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
        BrowserTools.isInView = { [weak self] session in self?.utilities.isInView(session) ?? false }
        // Agents writing to each other, here and on machines.
        AgentMail.shared.app = self
        BrowserTools.mail = { name, arguments, caller in await AgentMail.shared.call(name, arguments: arguments, caller: caller) }
        // The browser sends agents from the sites of integrations you added to their tools.
        BrowserTools.integrationSites = { [weak self] in self.map { Integrations.sites(Integrations.added(in: $0.engineConfig)) } ?? [] }
        // An agent on a machine left a message for one elsewhere: on its way at once.
        workspace.onAgentMessage = { [weak self] machine in
            guard let engine = self?.machines.engine(machine) else { return }
            Task { await AgentMail.shared.collect(from: engine) }
        }
        // An agent showing you a file or folder: in the panel, beside its conversation.
        workspace.onShowInPanel = { [weak self] session, machine, path, isFolder in
            let url = machine.map { RemoteFolder.url(RemoteFolder.folder(path, on: $0)) } ?? URL(filePath: path, directoryHint: isFolder ? .isDirectory : .notDirectory)
            self?.utilities.showInPanel(url, isFolder: isFolder, for: session)
        }
        // An agent asks you for something in its browser: who's asking, and on a machine, the
        // connection that brings the ask here.
        browserAsks.onChange = { [weak self] sessions in self?.workspace.askingInBrowser = sessions }
        workspace.botName = { [weak self] session in self?.bots.bot(forSession: session)?.name }
        workspace.onRunEnded = { [weak self] session in
            self?.bots.runEnded(session: session)
            // An ask its agent left in this Mac's browser has no one waiting for it now.
            self?.browserAsks.runEnded(session)
        }
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
        // A subagent shows in the session that started it, a group chat's seat in its chat.
        utilities.shownIn = { [weak self] session in
            guard let self else { return session }
            if let group = groups.group(seat: session) { return BotGroups.tabKey(group.id) }
            return workspace.root(of: session)
        }
        // A machine whose connection dropped while the Mac slept, and that gave up trying, gets
        // another go once it's awake and the network is back. (NSWorkspace says so on its own
        // notification center; watched once, though this runs with each start of the engine.)
        if wakeWatch == nil {
            wakeWatch = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wakeMachines() }
            }
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

    /// Starts engines again, so they take new settings (an integration's key, an integration a
    /// machine gets only when its engine starts): this Mac's with `mac`, and the machines'
    /// connected now. Each as soon as nothing's at work in it, now or when that's done, so no
    /// one's work is cut off and nothing waits for you to remember.
    func renewEngines(mac: Bool) {
        if mac { renewals.insert("") }
        for engine in machines.engines.values where engine.isReady { renewals.insert(engine.machine.id) }
        guard renewing == nil else { return }
        renewing = Task { [weak self] in
            while let self, !self.renewals.isEmpty, !Task.isCancelled {
                for id in self.renewals {
                    if id.isEmpty {
                        let busy = self.workspace.running.contains { session in !RemoteFolder.isRemote(self.workspace.session(session)?.location.directory ?? "") }
                        // One that stopped (it fell over reloading, say) starts again too; one
                        // that's on its way up is waited for.
                        let failed = if case .failed = self.engine { true } else { false }
                        guard !busy, self.api != nil || failed else { continue }
                        self.renewals.remove(id)
                        await self.restart()
                    } else if let engine = self.machines.engine(id) {
                        guard !self.workspace.isRunning(on: id) else { continue }
                        self.renewals.remove(id)
                        // Not connected now: it takes them when it connects.
                        if engine.isReady { self.reconnectNow(engine) }
                    } else {
                        self.renewals.remove(id)
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
            self?.renewing = nil
        }
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
        engine.onEvent = { [weak self] event in
            self?.workspace.handle(event, machine: machine)
            // It signed in again, or a sign-in ran out and was renewed there: here too.
            if event.type == "credential.updated" { self?.nudgeSignIns(engine) }
        }
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
        await engine.start(machineLaunch(), cache: AppInfo.supportDirectory.appending(path: "engine-linux"))
        // Its sessions, once it's up: tried again a few times, as they're what makes them live.
        for wait in [0, 2, 5, 10, 20] where engine.isReady {
            try? await Task.sleep(for: .seconds(wait))
            guard engine.isReady else { break }
            if await workspace.refresh(engine) { break }
        }
        // Phones you've paired reach it directly, through its own bridge.
        if engine.isReady { await phoneLink.sync(engine) }
        // Its bots' keys of their own, which may have changed while it was away.
        if engine.isReady { await BotKeys.applyAll(on: engine.machine.id, app: self) }
        // What you signed in to here works there too, kept in step while it's connected.
        engine.signInSync?.cancel()
        if engine.isReady {
            await syncSignIns(with: engine)
            await syncSignInFiles(with: engine)
            await AgentMail.shared.share(with: engine)
            await AgentMail.shared.collect(from: engine)
            await AgentMail.shared.deliverWaiting(to: engine)
            engine.signInSync = Task { [weak self, weak engine] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(600))
                    guard let engine, engine.isReady, !Task.isCancelled else { return }
                    await self?.syncSignIns(with: engine)
                    await self?.syncSignInFiles(with: engine)
                }
            }
            engine.agentSync?.cancel()
            engine.agentSync = Task { [weak engine] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard let engine, engine.isReady, !Task.isCancelled else { return }
                    await AgentMail.shared.share(with: engine)
                    await AgentMail.shared.collect(from: engine)
                }
            }
            // An account changed here while it connected, after it took the ones it has.
            keepAccountsCurrent(engine)
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
        phoneLink.forget(machine: id)
        workspace.machines = Set(machines.list.map(\.id))
        workspace.forget(id, forGood: true)
    }

    /// When the app quits: each machine's engine stops, unless a session there is still working,
    /// which carries on there while this Mac is off, or a bot there has a wake-up waiting. Its
    /// phone link bridge tells your phones what happens there from now on.
    func stopMachines() {
        let leaving = PhoneLink.isEnabled ? RemoteServer.leavingScript(MachineEngine.macID) : ""
        var left = Set<String>()
        for engine in machines.engines.values where engine.isReady {
            let busy = workspace.isRunning(on: engine.machine.id)
            engine.disconnect()
            if !busy {
                RemoteServer.stopNow(on: engine.machine.connection, unlessWaking: true, first: leaving)
            } else if !leaving.isEmpty {
                RemoteServer.runNow(leaving, on: engine.machine.connection)
            }
            left.insert(engine.machine.id)
        }
        // One reconnecting just now (after a sleep, say) that still takes this Mac to be there.
        guard !leaving.isEmpty else { return }
        for id in phoneLink.presentOn where !left.contains(id) {
            RemoteServer.runNow(leaving, on: Machine(destination: id).connection, timeout: 2)
        }
    }

    /// What a machine's engine starts with: this Mac's accounts and settings, and the browser tools
    /// with the machine's own browser.
    private func machineLaunch() async -> MachineEngine.Launch {
        var environment = await machineEnvironment().environment
        let sites = Integrations.sites(Integrations.added(in: engineConfig).filter { !Integrations.macOnly.contains($0) })
        environment["OPENCODE_CONFIG_CONTENT"] = AppModel.merged(MachineBrowserInstaller.engineConfig(sites: sites), into: environment["OPENCODE_CONFIG_CONTENT"])
        return MachineEngine.Launch(environment: environment, helper: MachineBrowserInstaller.helper)
    }

    /// This Mac's accounts changed (one connected, signed out of or switched): a machine's engine
    /// has the ones it started with, so its models would stay the old ones. Each connected one
    /// takes the new ones as soon as nothing runs there; one still connecting is checked once
    /// it's up (`start`).
    func updateMachineAccounts() {
        // A change comes as a few events in a row.
        for engine in machines.engines.values where engine.isReady { keepAccountsCurrent(engine, after: .seconds(2)) }
    }

    /// Starts `engine` over with this Mac's accounts and settings as they are now, if it has
    /// older ones, as soon as nothing runs there: checked again while something does, less often
    /// the longer it takes, for as long as it stays connected. (Disconnected, it's checked again
    /// when it connects.)
    func keepAccountsCurrent(_ engine: MachineEngine, after delay: Duration = .zero) {
        engine.accountsUpdate?.cancel()
        engine.accountsUpdate = Task { [weak self, weak engine] in
            try? await Task.sleep(for: delay)
            var wait = 30
            while !Task.isCancelled {
                guard let self, let engine, engine.isReady else { return }
                guard engine.isBehind(await self.machineLaunch()) else { return }
                if !self.workspace.isRunning(on: engine.machine.id), (try? await engine.api?.activeSessions())?.isEmpty == true {
                    await engine.stopEngine()
                    // Apart from this task, which connecting replaces.
                    Task { await self.start(engine) }
                    return
                }
                try? await Task.sleep(for: .seconds(wait))
                wait = min(wait * 2, 120)
            }
        }
    }

    /// What a machine's engine gets from this Mac: the accounts that can go as environment
    /// variables (API keys, a GitHub Copilot sign-in), held in its memory and never written to its
    /// disk, and this Mac's engine settings, minus what only makes sense here (web search goes in
    /// its settings file, as here). `staysHere` names the accounts that can't go, like a ChatGPT
    /// sign-in.
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
        // Web search that works, as on this Mac, unless the file chose otherwise.
        engineConfig.addDefaults()
        // What goes in the settings file of the machine's engine, in `~/.kuvo-code`, rather than in
        // its memory with the rest, which outranks a project's own settings: web search, so a
        // project there can choose otherwise, as here, and integrations (below). Only which
        // provider, or none: a choice with more in it (a key, say) stays off its disk.
        var global: [String: JSONValue] = [:]
        if let data = try? Data(contentsOf: engineConfig.file),
           var settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            // A shell or a worktree folder on this Mac means nothing on the machine, nor do
            // integrations that use this Mac's apps.
            for key in ["$schema", "shell", "worktree"] { settings.removeValue(forKey: key) }
            if let search = (try? JSONDecoder().decode([String: JSONValue].self, from: data))?["websearch"] {
                let isPlain = switch search {
                case .bool: true
                case .object(let choice): choice.count == 1 && choice["provider"]?.string != nil
                default: false
                }
                if isPlain {
                    settings.removeValue(forKey: "websearch")
                    global["websearch"] = search
                }
            }
            if var mcp = settings["mcp"] as? [String: Any], var servers = mcp["servers"] as? [String: Any] {
                for id in Integrations.macOnly { servers.removeValue(forKey: id) }
                // Keys there come in files of their own on the machine, not this Mac's.
                servers = Integrations.keyVariables(in: servers) as? [String: Any] ?? servers
                // Integrations go in its settings file, as here, so a folder's own outrank them:
                // a bot with a key of its own names its server there (`BotKeys`). They name their
                // keys' files, never the keys.
                let integrations = servers.filter { Integrations.service($0.key) != nil }
                if !integrations.isEmpty,
                   let data = try? JSONSerialization.data(withJSONObject: integrations, options: [.withoutEscapingSlashes]),
                   let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                    for id in integrations.keys { servers.removeValue(forKey: id) }
                    global["mcp"] = .object(["servers": value])
                }
                mcp["servers"] = servers
                settings["mcp"] = mcp
            }
            // Slashes as they are: the engine finds `{file:…}` in the text before it reads it.
            if let json = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes]) {
                environment["OPENCODE_CONFIG_CONTENT"] = String(decoding: json, as: UTF8.self)
            }
        }
        // Always, so a choice taken back here is taken back there.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        environment["KUVO_SETTINGS"] = (try? encoder.encode(global)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        // Keys you brought for the integrations machines run, which go in files of their own
        // there as the engine starts (see `RemoteServer.launchScript`): not those that stay on
        // this Mac (an app's secret for a sign-in, say), nor bots' own, which reach only their
        // bot's machine (`BotKeys`).
        let here = Set(Integrations.macOnly.map { IntegrationKeys.variable($0, "") })
        let keys = await Task.detached { IntegrationKeys.environment }.value.filter { name, _ in !here.contains { name.hasPrefix($0) } && !IntegrationKeys.isBots(name) }
        environment.merge(keys) { _, key in key }
        // What some providers need until opencode handles it, as on this Mac.
        let compatibility = ProviderCompatibility.config
        if !compatibility.isEmpty {
            environment["OPENCODE_CONFIG_CONTENT"] = AppModel.merged(compatibility, into: environment["OPENCODE_CONFIG_CONTENT"])
        }
        return (environment, staysHere)
    }
}
