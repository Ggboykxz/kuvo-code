import CryptoKit
import Foundation
import OpenCodeKit
import os

/// Another computer whose engine Kuvo Code runs over SSH (a home server, a VPS), next to this
/// Mac's: a host from `~/.ssh/config` or `user@host`. Its projects are folders on it.
nonisolated struct Machine: Codable, Hashable, Identifiable {
    var destination: String

    var id: String { destination }
    var name: String { destination }
    var connection: SSHConnection { SSHConnection(destination: destination) }
}

/// One machine's engine: installed and started over SSH when Kuvo Code connects (or found still
/// running there from before), with its own catalog (agents, commands and models can differ
/// there), and its live events.
@Observable
final class MachineEngine {
    let machine: Machine
    private(set) var state = AppModel.EngineState.preparing
    private(set) var api: OpenCodeAPI?
    /// False while the live event feed is down.
    private(set) var isLive = false
    /// Waiting to try again by itself, after the connection dropped.
    var isRetrying = false
    let catalog = Catalog()
    /// Its browser, which its agents browse with, shown live in the panel.
    let browser: MachineBrowser

    @ObservationIgnored private var server: RemoteServer?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var isStopping = false
    /// Events for the stores that span every machine (sessions); the catalog takes its own.
    @ObservationIgnored var onEvent: (ServerEvent) -> Void = { _ in }
    /// The feed came back after a gap: whatever it missed has to be read again.
    @ObservationIgnored var onReconnect: () async -> Void = {}
    /// The connection closed without being asked to (the machine restarted, the network went).
    @ObservationIgnored var onExit: () -> Void = {}
    private let log = Logger(subsystem: "run.kuvo.code", category: "machine")

    init(machine: Machine) {
        self.machine = machine
        browser = MachineBrowser(machine: machine)
    }

    var isReady: Bool { state == .ready }

    /// Where its engine is, in a few words, for menus and lists.
    var statusText: String {
        switch state {
        case .preparing: "Not connected"
        case .downloading: "Installing the engine…"
        case .starting: "Connecting…"
        case .ready: isLive ? "Connected" : "Reconnecting…"
        case .failed: isRetrying ? "Reconnecting…" : "Couldn’t connect"
        }
    }

    /// What a new engine on the machine gets from this Mac.
    struct Launch {
        /// Accounts and settings (the browser tools' among them), as environment variables.
        var environment: [String: String]
        /// The browser helper the engine runs for the browser tools (`kuvo-browser.js`).
        var helper: (text: String, hash: String)

        /// Changes when the accounts or settings do, so an engine started with older ones is known.
        /// The launch script's, the watchdog's and the browser helper's versions count too: an
        /// engine running older ones is started over the next time it's idle. (The launch script's
        /// goes up when what it sets up changes: its folders, `kuvo-npx`.)
        var fingerprint: String {
            let text = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") + "\nlaunch=2\nwatchdog=wakes\nbrowser=\(helper.hash)"
            return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// This Mac, as the engines it starts on machines note it.
    static let macID: String = {
        let key = "machineClientID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    /// Whether another Mac started this engine (engines from before Macs were noted count as
    /// this one's).
    private func isAnotherMacs(_ engine: RemoteServer.Engine) -> Bool {
        engine.notes["mac"].map { $0 != Self.macID } ?? false
    }

    /// Connects to the machine's engine: the one already running there (from an earlier launch,
    /// maybe still working on something), or a new one, installed first if needed. One this Mac
    /// started with an older version, or older accounts and settings while nothing is running, is
    /// replaced. One another Mac started is used as it is, unless it's an older version: two Macs
    /// with different settings would otherwise take turns starting it over, each dropping the
    /// other's connection, and an older app would put back an older engine.
    func start(_ launch: Launch, cache: URL) async {
        // Once at a time.
        switch state {
        case .preparing, .failed: break
        case .downloading, .starting, .ready: return
        }
        isStopping = false
        let connection = machine.connection
        // Disconnecting (Connect Now) or a newer attempt ends this one at its next step.
        let attempt = connections
        let check = { if self.connections != attempt { throw Superseded() } }
        var attached: RemoteServer?
        do {
            state = .starting
            var engine = try await RemoteServer.running(on: connection)
            try check()
            let isNewer = engine.map { $0.version.compare(OpenCodeEngine.version, options: .numeric) == .orderedDescending } ?? false
            if engine?.version != OpenCodeEngine.version, !(isNewer && engine.map(isAnotherMacs) == true) {
                state = .downloading(progress: 0)
                try await RemoteEngineInstaller(connection: connection, cache: cache).install { progress in
                    Task { @MainActor in
                        if case .downloading = self.state { self.state = .downloading(progress: progress) }
                    }
                }
                try check()
                state = .starting
                if engine != nil { try await RemoteServer.stop(on: connection) }
                engine = nil
            }
            // The browser tools' helper, which an engine starts with.
            try await MachineBrowserInstaller.installHelper(launch.helper, on: connection)
            try check()
            let running: RemoteServer.Engine
            if let engine { running = engine } else { running = try await launchEngine(launch) }
            try check()
            var server = try await attach(running, launch)
            attached = server
            try check()
            let api = OpenCodeAPI(endpoint: server.endpoint, folderPrefix: RemoteFolder.prefix(for: machine.id))
            if server.engine.notes["settings"] != launch.fingerprint, !isAnotherMacs(server.engine), (try? await api.activeSessions())?.isEmpty == true {
                // Started with older accounts or settings, and nothing to interrupt: start it over.
                try check()
                server.disconnect()
                attached = nil
                try await RemoteServer.stop(on: connection)
                server = try await attach(launchEngine(launch), launch)
                attached = server
                try check()
            }
            self.server = server
            let current = OpenCodeAPI(endpoint: server.endpoint, folderPrefix: RemoteFolder.prefix(for: machine.id))
            self.api = current
            catalog.api = current
            state = .ready
            listen(to: current)
            keepAlive()
            // The browser, in the background: the first time, a download and an upload. A browser
            // tab in view comes back live.
            Task { await browser.prepare() }
            browser.resume()
            await catalog.refresh()
        } catch is Superseded {
            // What it connected is its own to close; the newer attempt has the rest.
            if let attached, attached !== server { attached.disconnect() }
        } catch {
            log.error("\(self.machine.destination, privacy: .public) didn't start: \(error.localizedDescription, privacy: .public)")
            server?.disconnect()
            server = nil
            state = .failed(error.localizedDescription)
        }
    }

    private struct Superseded: Error {}

    private func launchEngine(_ launch: Launch) async throws -> RemoteServer.Engine {
        try await RemoteServer.launch(on: machine.connection, environment: launch.environment, notes: ["settings": launch.fingerprint, "mac": Self.macID])
    }

    private func attach(_ engine: RemoteServer.Engine, _ launch: Launch) async throws -> RemoteServer {
        try await RemoteServer.attach(to: engine, on: machine.connection) { status in
            Task { @MainActor in self.exited(status: status) }
        }
    }

    /// Closes the connection. The engine keeps running on the machine.
    func disconnect() {
        isStopping = true
        downCheck?.cancel()
        downCheck = nil
        connections += 1
        eventTask?.cancel()
        eventTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        server?.disconnect()
        server = nil
        api = nil
        catalog.api = nil
        isLive = false
        state = .preparing
    }

    /// Closes the connection and stops the engine on the machine.
    func stopEngine() async {
        disconnect()
        try? await RemoteServer.stop(on: machine.connection)
    }

    /// The machine's engine stops by itself after a day without the app: say it's still here.
    private func keepAlive() {
        heartbeatTask?.cancel()
        let connection = machine.connection
        heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                await RemoteServer.heartbeat(on: connection)
            }
        }
    }

    private func listen(to api: OpenCodeAPI) {
        // One feed at a time: two would tell every event twice.
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await update in api.events.updates() {
                guard let self else { return }
                switch update {
                case .connected:
                    let wasLive = isLive
                    isLive = true
                    downCheck?.cancel()
                    downCheck = nil
                    if !wasLive {
                        await catalog.refresh()
                        await onReconnect()
                    }
                case .disconnected:
                    isLive = false
                    checkWhileDown(api)
                case .event(let event):
                    catalog.handle(event)
                    onEvent(event)
                }
            }
        }
    }

    @ObservationIgnored private var downCheck: Task<Void, Never>?
    /// Goes up with each disconnection, so a check from an earlier connection stops.
    @ObservationIgnored private var connections = 0

    /// The live feed went down. It comes back by itself after a blip; but when the engine behind
    /// the tunnel is gone (restarted on another port, say) while the tunnel stays up, nothing
    /// would ever change. So a few seconds on, ask the engine; not answering, the connection is
    /// lost, and connecting again starts (as after the network went).
    private func checkWhileDown(_ api: OpenCodeAPI) {
        // Once for each time it's down: the feed says so again at each of its own retries.
        guard downCheck == nil else { return }
        let connection = connections
        downCheck = Task { [weak self] in
            for wait in [6, 10, 20, 30] {
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled, !isLive, state == .ready, connections == connection else { return }
                let answered = await withTaskGroup(of: Bool.self) { group in
                    group.addTask { (try? await api.info()) != nil }
                    group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
                    let first = await group.next() ?? false
                    group.cancelAll()
                    return first
                }
                guard !answered else { continue }
                log.error("\(self.machine.destination, privacy: .public)'s engine stopped answering through its tunnel")
                lost("The connection to \(machine.name) was lost.")
                return
            }
            // It answered every time: the next time the feed goes down, check again.
            if let self, connections == connection { downCheck = nil }
        }
    }

    /// The connection is gone: say so, and let the app connect again.
    private func lost(_ reason: String) {
        disconnect()
        state = .failed(reason)
        onExit()
    }

    private func exited(status: Int32) {
        guard !isStopping else { return }
        let output = server?.recentOutput.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        log.error("\(self.machine.destination, privacy: .public) closed with status \(status): \(output, privacy: .public)")
        lost("The connection to \(machine.name) was lost.\(output.isEmpty ? "" : "\n\n" + String(output.suffix(400)))")
    }
}

/// The machines you've added, and their engines.
@Observable
final class Machines {
    private(set) var list: [Machine] = Machines.load()
    private(set) var engines: [String: MachineEngine] = [:]

    private static let key = "machines"

    init() {
        for machine in list { engines[machine.id] = MachineEngine(machine: machine) }
    }

    func engine(_ id: String?) -> MachineEngine? {
        id.flatMap { engines[$0] }
    }

    @discardableResult
    func add(_ destination: String) -> MachineEngine {
        let machine = Machine(destination: destination.trimmingCharacters(in: .whitespaces))
        if let engine = engines[machine.id] { return engine }
        list.append(machine)
        let engine = MachineEngine(machine: machine)
        engines[machine.id] = engine
        save()
        return engine
    }

    func remove(_ id: String) {
        if let engine = engines[id] { Task { await engine.stopEngine() } }
        engines[id] = nil
        list.removeAll { $0.id == id }
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: Self.key)
    }

    private static func load() -> [Machine] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Machine].self, from: data)) ?? []
    }
}

/// Where a folder is. A folder on a machine is written `ssh://<machine><path>` wherever the app
/// keys things by folder (projects, tabs, settings), so it can never pass for one of this Mac's
/// paths; its machine's engine is given the plain path.
nonisolated enum RemoteFolder {
    static let scheme = "ssh://"

    static func folder(_ path: String, on machine: String) -> String {
        scheme + machine + path
    }

    /// How a machine's folders start: what its engine's API takes off and puts back.
    static func prefix(for machine: String) -> String {
        scheme + machine
    }

    /// The machine and the path on it, for a folder on a machine.
    static func parse(_ folder: String) -> (machine: String, path: String)? {
        guard folder.hasPrefix(scheme) else { return nil }
        let rest = folder.dropFirst(scheme.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        return (String(rest[..<slash]), String(rest[slash...]))
    }

    static func machine(of folder: String) -> String? {
        parse(folder)?.machine
    }

    static func isRemote(_ folder: String) -> Bool {
        folder.hasPrefix(scheme)
    }
}

/// Short commands on a machine, over its shared SSH connection, for what the panel and sheets
/// read there (the engine has no file API).
nonisolated enum RemoteShell {
    /// Runs `script` with `sh` on `machine`: its output, or nil when it (or SSH) fails.
    static func run(_ script: String, on machine: String) -> Data? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh")
        process.arguments = SSHConnection(destination: machine).arguments(running: script)
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    /// A folder typed on `machine` (`~` for its home), as the full path it is there, or nil when
    /// there's no such folder.
    static func resolve(_ typed: String, on machine: String) -> String? {
        let typed = typed.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return nil }
        let target: String
        if typed == "~" {
            target = "\"$HOME\""
        } else if typed.hasPrefix("~/") {
            target = "\"$HOME\"/" + SSHConnection.quoted(String(typed.dropFirst(2)))
        } else if typed.hasPrefix("/") {
            target = SSHConnection.quoted(typed)
        } else {
            target = "\"$HOME\"/" + SSHConnection.quoted(typed)
        }
        guard let data = run("cd \(target) && pwd -P", on: machine) else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
    }
}

nonisolated extension RemoteFolder {
    /// A folder or file as a URL: a file URL on this Mac, `ssh://machine/path` on a machine, so
    /// what's there is never read from this Mac's disk by mistake.
    static func url(_ folder: String) -> URL {
        guard let (machine, path) = parse(folder) else { return URL(filePath: folder) }
        var components = URLComponents()
        components.scheme = "ssh"
        let parts = machine.split(separator: "@", maxSplits: 1).map(String.init)
        if parts.count == 2 { components.user = parts[0] }
        components.host = parts.last
        components.path = path
        return components.url ?? URL(filePath: path)
    }

    /// A file on a machine: the machine and the path there.
    static func parse(_ url: URL) -> (machine: String, path: String)? {
        guard url.scheme == "ssh", let host = url.host(percentEncoded: false) else { return nil }
        return ((url.user(percentEncoded: false).map { $0 + "@" } ?? "") + host, url.path(percentEncoded: false))
    }

    /// A URL as the app keys folders: its path on this Mac, `ssh://machine/path` on a machine.
    static func folder(of url: URL) -> String {
        parse(url).map { folder($0.path, on: $0.machine) } ?? url.path
    }

    /// A path the agent named (absolute, or relative to `directory`), as a URL on the machine
    /// `directory` is on.
    static func fileURL(_ path: String, in directory: String) -> URL {
        if let machine = machine(of: directory) {
            return url(path.hasPrefix("/") ? folder(path, on: machine) : directory + "/" + path)
        }
        return path.hasPrefix("/") ? URL(filePath: path) : URL(filePath: directory).appending(path: path)
    }
}

nonisolated extension RemoteShell {
    /// A folder's entries on a machine, or nil when it can't be read.
    static func list(_ url: URL) -> [(name: String, isDirectory: Bool)]? {
        guard let (machine, path) = RemoteFolder.parse(url),
              let data = run("cd \(SSHConnection.quoted(path)) && find . -mindepth 1 -maxdepth 1 -printf '%Y\\t%P\\0'", on: machine) else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\0").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[1]), parts[0] == "d")
        }
    }

    /// Up to `limit` bytes of a file on a machine.
    static func read(_ url: URL, limit: Int) -> Data? {
        guard let (machine, path) = RemoteFolder.parse(url) else { return nil }
        return run("head -c \(limit) -- \(SSHConnection.quoted(path))", on: machine)
    }

    /// Moves a file on a machine into `~/.kuvo-code/trash`, where it can still be found: nil
    /// when it went, else why not.
    static func trash(_ url: URL) -> String? {
        guard let (machine, path) = RemoteFolder.parse(url) else { return "Not on a machine." }
        let script = """
            T="$HOME/\(RemoteEngineInstaller.root)/trash/$(date +%Y%m%d-%H%M%S)-$$"
            mkdir -p "$T" && mv -- \(SSHConnection.quoted(path)) "$T/"
            """
        return run(script, on: machine) == nil ? "Couldn’t move \((path as NSString).lastPathComponent) out of the way on \(machine)." : nil
    }

    /// The files under a folder on a machine, relative to it, skipping the usual heavy folders.
    static func files(in url: URL, skipping skip: Set<String>, limit: Int) -> [String]? {
        guard let (machine, path) = RemoteFolder.parse(url) else { return nil }
        let pruned = skip.sorted().map { "-name \(SSHConnection.quoted($0))" }.joined(separator: " -o ")
        let script = "cd \(SSHConnection.quoted(path)) && find . \\( \(pruned) \\) -prune -o -type f -printf '%P\\0' | head -z -n \(limit)"
        guard let data = run(script, on: machine) else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
    }
}
