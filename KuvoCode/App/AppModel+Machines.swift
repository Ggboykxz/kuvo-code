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
        workspace.onMachineBrowsing = { [weak self] machine in self?.utilities.showMachineBrowser(machine, byAgent: true) }
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

    /// Installs and starts a machine's engine over SSH, with what it gets from this Mac, and
    /// feeds its sessions into the workspace.
    func connect(_ engine: MachineEngine) {
        let machine = engine.machine.id
        engine.onEvent = { [weak self] event in self?.workspace.handle(event, machine: machine) }
        engine.onReconnect = { [weak self] in await self?.workspace.refresh(engine) }
        engine.onExit = { [weak self] in
            self?.workspace.forget(machine)
            Task { await self?.reconnect(engine) }
        }
        Task { await start(engine) }
    }

    /// After a dropped connection (the Mac slept, the machine restarted): a few tries, further
    /// apart each time, while its sessions wait.
    private func reconnect(_ engine: MachineEngine) async {
        engine.isRetrying = true
        defer { engine.isRetrying = false }
        for delay in [3, 15, 60] {
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
        if engine.isReady { await workspace.refresh(engine) }
    }

    /// Closes the connection to a machine. Its engine stops too, unless a session there is still
    /// working: then it carries on, and its work is there when you connect again.
    func disconnect(_ engine: MachineEngine) {
        engine.browser.reset()
        let busy = workspace.isRunning(on: engine.machine.id)
        if busy { engine.disconnect() } else { Task { await engine.stopEngine() } }
        workspace.forget(engine.machine.id)
    }

    /// Stops a machine's engine and forgets the machine, and its sessions' tabs with it. Its
    /// sessions stay on the machine, for when it's added again.
    func removeMachine(_ id: String) {
        machines.engine(id)?.browser.reset()
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
            // A shell or a worktree folder on this Mac means nothing on the machine.
            for key in ["$schema", "shell", "worktree"] { settings.removeValue(forKey: key) }
            if let json = try? JSONSerialization.data(withJSONObject: settings) {
                environment["OPENCODE_CONFIG_CONTENT"] = String(decoding: json, as: UTF8.self)
            }
        }
        // What some providers need until opencode handles it, as on this Mac.
        let compatibility = ProviderCompatibility.config
        if !compatibility.isEmpty {
            environment["OPENCODE_CONFIG_CONTENT"] = AppModel.merged(compatibility, into: environment["OPENCODE_CONFIG_CONTENT"])
        }
        return (environment, staysHere)
    }
}
