import Foundation

// Starts processes, so only on the Mac; the phone reaches engines through Kuvo Link.
#if os(macOS)

/// A machine reached over SSH: a host from `~/.ssh/config` (like `my-server`) or `user@host`.
/// Everything goes through the system's `ssh`, so the user's keys, agent and config apply.
public struct SSHConnection: Sendable, Hashable, Codable {
    public var destination: String

    public init(destination: String) {
        self.destination = destination
    }

    /// For every connection: never a password prompt (there's no terminal to type it in), a
    /// timeout to connect, and a check that notices when the machine goes away.
    static let options = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=15",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
    ]

    /// Short commands share one connection per machine, kept open a little while after the last,
    /// so each costs a round trip rather than a new login. (Its socket's folder is this user's
    /// alone; `%C` is a hash of the host and user.)
    static var sharing: [String] {
        let folder = "/tmp/kuvo-ssh-\(getuid())"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Only a folder that's really this user's alone: one another account made first could
        // hold a socket of its own, which ssh would hand what it sends (launch secrets on stdin).
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            return separate
        }
        return ["-o", "ControlMaster=auto", "-o", "ControlPath=\(folder)/%C", "-o", "ControlPersist=120"]
    }

    /// The engine's own connection stays apart, so its tunnels end with it.
    static let separate = ["-o", "ControlMaster=no", "-o", "ControlPath=none"]

    /// The `ssh` arguments that run `script` on the machine with `sh`, whatever its login shell.
    /// sshd hands the command to that shell, and one like fish reads backslashes in quotes its own
    /// way, so the script goes as base64, which no shell changes, for `sh` to decode and run. Its
    /// standard input stays the command's.
    public func arguments(running script: String, extra: [String] = [], shared: Bool = true) -> [String] {
        Self.options + (shared ? Self.sharing : Self.separate) + extra + [destination, Self.command(running: script)]
    }

    /// The command line for the machine's login shell that runs `script` with `sh`. Without a
    /// working `base64` there, it fails (127) rather than running nothing and saying it's done.
    public static func command(running script: String) -> String {
        "exec sh -c 'kuvo_script=$(printf %s " + Data(script.utf8).base64EncodedString() + " | base64 -d) || exit 127; eval \"$kuvo_script\"'"
    }

    /// Runs `script` on the machine and returns what it printed. `input` is sent to it.
    @discardableResult
    public func run(_ script: String, input: URL? = nil) async throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh")
        process.arguments = arguments(running: script)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        if let input { process.standardInput = try FileHandle(forReadingFrom: input) }
        // Read while it runs: a full pipe would stall it.
        let output = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
        let errors = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        let text = String(decoding: await output.value, as: UTF8.self)
        guard status == 0 else {
            throw RemoteEngineError.ssh(status: status, message: String(decoding: await errors.value, as: UTF8.self))
        }
        return text
    }

    /// `text` as one word for `sh`.
    public static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum RemoteEngineError: LocalizedError {
    case ssh(status: Int32, message: String)
    case unsupportedPlatform(String)
    case exited(status: Int32, output: String)
    case unreadableHandshake(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .ssh(let status, let message):
            let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if status == 255, message.contains("Host key verification failed") {
                return "This Mac doesn't know the machine's host key yet. Connect to it once in Terminal with ssh, then try again."
            }
            if status == 255, message.localizedCaseInsensitiveContains("permission denied") {
                return "The machine didn't accept this Mac's SSH key. Kuvo Code connects with your keys and SSH agent, without a password."
            }
            return message.isEmpty ? "SSH stopped (exit code \(status))." : message
        case .unsupportedPlatform(let platform):
            return "The engine runs on Linux on x86-64 or ARM64 with glibc; this machine is \(platform)."
        case .exited(let status, let output):
            return "The engine on the machine stopped (exit code \(status)).\(output.isEmpty ? "" : "\n\n\(output)")"
        case .unreadableHandshake(let line):
            return "The engine on the machine said something unexpected when starting: \(line)"
        case .timedOut:
            return "The engine on the machine took too long to start."
        }
    }
}

/// Puts the pinned engine on a machine, in `~/.kuvo-code/engine/<version>/opencode`: downloaded and
/// checked on this Mac, then sent over SSH and unpacked there, so the machine needs nothing but `sh`
/// and `tar`, and never downloads code itself.
public struct RemoteEngineInstaller: Sendable {
    public var connection: SSHConnection
    /// Where this Mac keeps the checked Linux packages, so a second machine needs no download.
    public var cache: URL

    public init(connection: SSHConnection, cache: URL) {
        self.connection = connection
        self.cache = cache
    }

    /// The folder in the machine's home with everything Kuvo Code keeps there. A copy of the app
    /// for testing can take another, so its engine there is its own; set before connecting.
    nonisolated(unsafe) public static var root = ".kuvo-code"

    var remoteExecutable: String { "$HOME/\(Self.root)/engine/\(OpenCodeEngine.version)/opencode" }

    /// Gives the engine folders of its own in `~/.kuvo-code` (`$K`), for everything it runs there,
    /// so it never touches the machine's own opencode, if it has one. Only you can open `$K`: what's
    /// in it (conversations, bots' memory, settings) is yours, wherever the home folder is open. (The commands the agent
    /// runs get the machine's own back: [CommandEnvironment].)
    /// Worked out each time, never kept, so a `root` set later is the one it names.
    static var folders: String {
        """
        K="$HOME/\(root)"
        mkdir -p "$K" && chmod 700 "$K"
        \(CommandEnvironment.keepScript)
        export XDG_DATA_HOME="$K/data" XDG_CONFIG_HOME="$K/config" XDG_STATE_HOME="$K/state" XDG_CACHE_HOME="$K/cache" npm_config_cache="$K/cache/npm" BUN_INSTALL="$K/cache/bun" KUVO_INTEGRATIONS="$K/integrations" TMPDIR="$K/tmp"
        mkdir -p "$K/data" "$K/config" "$K/state" "$K/cache" "$K/workspace" "$K/integrations" "$K/tmp"
        find "$K/tmp" -mindepth 1 -maxdepth 1 -mtime +3 -exec rm -rf {} + 2>/dev/null
        """
    }

    /// `command` as the engine's own helpers run on the machine: with its folders in `$K` (and
    /// the XDG folders pointed there), from its workspace, its runtime at `$E`.
    public static func script(_ command: String) -> String {
        """
        \(folders)
        E="$K/engine/\(OpenCodeEngine.version)/opencode"
        mkdir -p "$K/bin" "$K/run" && chmod 700 "$K/run"
        cd "$K/workspace" || exit 1
        \(command)
        """
    }

    /// Connects and checks that the machine can run the engine: the build it needs, and whether
    /// it's there already.
    @discardableResult
    public func check() async throws -> (release: EngineRelease, isInstalled: Bool) {
        let probe = try await connection.run("""
            uname -sm
            if ldd --version 2>&1 | grep -qi musl; then echo musl; else echo glibc; fi
            test -x "\(remoteExecutable)" && (\(Self.folders.replacingOccurrences(of: "\n", with: "; ")); "\(remoteExecutable)" --version) 2>/dev/null || true
            """)
        let lines = probe.split(separator: "\n").map(String.init)
        let platform = lines.first ?? ""
        let parts = platform.split(separator: " ")
        guard parts.first == "Linux", lines.dropFirst().first == "glibc", let machine = parts.last,
              let release = EngineRelease.linux(machine: String(machine)) else {
            throw RemoteEngineError.unsupportedPlatform(platform + (lines.dropFirst().first == "musl" ? " (musl)" : ""))
        }
        return (release, lines.count > 2 && lines[2].hasSuffix(OpenCodeEngine.version))
    }

    /// Makes sure the engine is on the machine. `progress` gets the fraction downloaded, when it is.
    public func install(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let (release, isInstalled) = try await check()
        if isInstalled { return }
        let package = try await checkedPackage(release, progress: progress)
        let folder = "$HOME/\(Self.root)/engine"
        try await connection.run("""
            set -e
            mkdir -p "\(folder)/.staging"
            tar xzf - -C "\(folder)/.staging" package/bin/opencode
            rm -rf "\(folder)/\(release.version)"
            mkdir -p "\(folder)/\(release.version)"
            mv "\(folder)/.staging/package/bin/opencode" "\(folder)/\(release.version)/opencode"
            chmod +x "\(folder)/\(release.version)/opencode"
            rm -rf "\(folder)/.staging"
            find "\(folder)" -mindepth 1 -maxdepth 1 ! -name "\(release.version)" -exec rm -rf {} +
            """, input: package)
        progress(1)
    }

    /// The release's tarball, from this Mac's cache when it's there and still matches its checksum.
    private func checkedPackage(_ release: EngineRelease, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        let file = cache.appending(path: release.tarball.lastPathComponent)
        if fm.fileExists(atPath: file.path), (try? EngineInstaller.verifyIntegrity(of: file, against: release)) != nil {
            return file
        }
        let download = try await EngineInstaller.download(release, progress: progress)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try? fm.removeItem(at: file)
        try fm.moveItem(at: download, to: file)
        // Older versions' packages aren't needed again.
        for entry in (try? fm.contentsOfDirectory(atPath: cache.path)) ?? [] where !entry.contains(release.version) {
            try? fm.removeItem(at: cache.appending(path: entry))
        }
        return file
    }
}

/// The engine on a machine, and the connection to it.
///
/// The engine runs there on its own, apart from any connection, so a task carries on while this
/// Mac sleeps, shuts down or loses the network; the app finds it again next time. It listens on
/// the machine's localhost only, behind a password, and this Mac reaches it through an SSH tunnel.
/// Its settings and secrets
/// (the password, accounts) go over the session's input rather than a command line, so other users
/// of the machine can't read them in its process list. Accounts copied there are kept in its
/// engine's own store, in `~/.kuvo-code/data`, readable by that user only, and signed out when the
/// machine is removed. What's needed to find it again (its process, port and password) is kept in
/// `~/.kuvo-code/run/engine.json`, readable by that user only, who could read it from the engine's
/// process anyway. If the app hasn't been connected for a day, the engine stops by itself.
public final class RemoteServer: @unchecked Sendable {
    /// The engine running on a machine.
    public struct Engine: Codable, Sendable, Equatable {
        public var pid: Int
        public var port: Int
        public var password: String
        public var version: String
        /// The app's own notes on how it started it, kept with it.
        public var notes: [String: String]
        /// The agents bridge beside it (`kuvo-agents.js`), when it was started with one: where it
        /// listens on the machine's localhost, behind its own password.
        public var agents: Agents?

        public struct Agents: Codable, Sendable, Equatable {
            public var port: Int
            public var password: String
        }
    }

    public let engine: Engine
    public let endpoint: ServerEndpoint
    /// The agents bridge beside it, through the same tunnel.
    public let agentsEndpoint: ServerEndpoint?
    public let connection: SSHConnection
    private let tunnel: Process
    private let log: LogTail

    private init(engine: Engine, endpoint: ServerEndpoint, agentsEndpoint: ServerEndpoint?, connection: SSHConnection, tunnel: Process, log: LogTail) {
        self.engine = engine
        self.endpoint = endpoint
        self.agentsEndpoint = agentsEndpoint
        self.connection = connection
        self.tunnel = tunnel
        self.log = log
    }

    public var isConnected: Bool { tunnel.isRunning }

    /// The last lines ssh wrote, for error reports.
    public var recentOutput: String { log.text }

    static var run: String { "$HOME/\(RemoteEngineInstaller.root)/run" }

    /// The engine already running on the machine, if there is one. Finding it counts as the app
    /// being around, for the engine's watchdog.
    public static func running(on connection: SSHConnection) async throws -> Engine? {
        let text = try await connection.run("""
            R="\(run)"
            [ -f "$R/engine.json" ] || exit 0
            pid=$(sed -n 's/^{"pid":\\([0-9]*\\),.*/\\1/p' "$R/engine.json")
            [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && grep -q opencode "/proc/$pid/cmdline" 2>/dev/null || exit 0
            touch "$R/attached"
            cat "$R/engine.json"
            """)
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        return try? JSONDecoder().decode(Engine.self, from: Data(line.utf8))
    }

    /// Starts the engine on the machine, on its own, and waits until it's listening. `environment`
    /// is handed to it, with values on one line each; `notes` are kept with it. `withAgents`: the
    /// agents bridge (`bin/kuvo-agents.js`, put there first) starts beside it.
    public static func launch(on connection: SSHConnection, environment base: [String: String], notes: [String: String] = [:], withAgents: Bool = false) async throws -> Engine {
        var lastError: Error = RemoteEngineError.timedOut
        // A port someone else took on the machine: try another.
        for _ in 0..<3 {
            let port = Int.random(in: 20_000..<60_000)
            let agents = withAgents ? Engine.Agents(port: (port - 20_000 + Int.random(in: 1..<40_000)) % 40_000 + 20_000, password: ServerProcess.randomPassword()) : nil
            var engine = Engine(pid: 0, port: port, password: ServerProcess.randomPassword(), version: OpenCodeEngine.version, notes: notes, agents: agents)
            var environment = base
            environment["OPENCODE_PASSWORD"] = engine.password
            environment["OPENCODE_CLIENT"] = "desktop"
            environment.removeValue(forKey: "OPENCODE_SERVER_PASSWORD")
            // What's kept to find it again, but its process, which the script adds.
            struct Record: Encodable { var port: Int, password: String, version: String, notes: [String: String], agents: Engine.Agents? }
            let record = String(decoding: try JSONEncoder().encode(Record(port: engine.port, password: engine.password, version: engine.version, notes: engine.notes, agents: agents)), as: UTF8.self)
            environment["KUVO_RECORD"] = String(record.dropFirst())
            environment["KUVO_PORT"] = String(engine.port)
            if let agents {
                environment["KUVO_AGENTS_PORT"] = String(agents.port)
                environment["KUVO_AGENTS_PASSWORD"] = agents.password
            }
            let lines = environment.sorted { $0.key < $1.key }
                .filter { !$0.value.contains("\n") }
                .map { "\($0.key)=\($0.value)\n" }
                .joined() + "\n"
            _ = clearedLeftovers
            let input = FileManager.default.temporaryDirectory.appending(path: "kuvo-engine-\(UUID().uuidString)")
            // Only this user can read it, and it's gone as soon as ssh has sent it (or, if the app
            // stopped first, the next time it starts one).
            FileManager.default.createFile(atPath: input.path, contents: Data(lines.utf8), attributes: [.posixPermissions: 0o600])
            defer { try? FileManager.default.removeItem(at: input) }
            do {
                let pid = try await connection.run(launchScript, input: input).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let pid = Int(pid) else { throw RemoteEngineError.unreadableHandshake(pid) }
                engine.pid = pid
                return engine
            } catch RemoteEngineError.ssh(let status, let message) where status == 3 && message.localizedCaseInsensitiveContains("in use") {
                lastError = RemoteEngineError.exited(status: status, output: message)
            } catch RemoteEngineError.ssh(let status, let message) where status == 3 {
                throw RemoteEngineError.exited(status: status, output: message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        throw lastError
    }

    /// Settings for the engine that stay out of its environment (see `launchScript`).
    public static let privateSettingsVariable = "KUVO_PRIVATE_SETTINGS"

    /// Reads the settings from the input, gives the engine its own folders under `~/.kuvo-code`,
    /// starts it in a session of its own on the machine's localhost, writes down how to find it,
    /// and starts its watchdog. Prints its process once it listens.
    ///
    /// `KUVO_SETTINGS`, when it's given, becomes the engine's settings file there (its global
    /// settings, which a project's own outrank), in place of what was there.
    ///
    /// `privateSettingsVariable`, when it's given, is the rest of your settings, which can hold
    /// secrets (a server's environment or headers): written to a file only this user can read in
    /// `keys`, which the engine reads (`OPENCODE_CONFIG`, above its settings file and below a
    /// project's own), never left in its environment.
    ///
    /// Integrations' keys (`KUVO_KEY_…`) go in files only this user can read, in `keys`, which the
    /// settings name with `{file:…}`, never in the engine's environment, where the agent's own
    /// commands (`env`, say) would print them. They're gone once the engine is: its watchdog takes
    /// them away, unless an engine started since has put its own there.
    ///
    /// Every minute the watchdog sends bots' and sessions' wake-ups that are due ([Wakes]). Every
    /// ten, it stops the engine if the app hasn't been around for a day and no wake-up is waiting.
    ///
    /// With `KUVO_AGENTS_PORT` and `KUVO_AGENTS_PASSWORD`, the agents bridge starts beside the
    /// engine once it listens, with the same settings, and stops with it ([agentsScript]). Only it
    /// gets its password, never the engine (whose agent's commands could print it).
    static var launchScript: String {
        """
        while IFS= read -r line && [ -n "$line" ]; do export "$line"; done
        port=$KUVO_PORT; record=$KUVO_RECORD; unset KUVO_PORT KUVO_RECORD
        aport=${KUVO_AGENTS_PORT-}; apass=${KUVO_AGENTS_PASSWORD-}; unset KUVO_AGENTS_PORT KUVO_AGENTS_PASSWORD
        \(RemoteEngineInstaller.folders)
        if [ -n "${KUVO_SETTINGS+set}" ]; then
          mkdir -p "$K/config/opencode" && (umask 077; printf '%s\\n' "$KUVO_SETTINGS" >"$K/config/opencode/opencode.json")
          unset KUVO_SETTINGS
        fi
        R="$K/run"; mkdir -p "$R"; chmod 700 "$R"
        launch="$$.$(date +%s)"
        rm -rf "$K/keys"; mkdir -p "$K/keys"; chmod 700 "$K/keys"; echo "$launch" >"$K/keys/.launch"
        for v in $(env | sed -n 's/^\\(KUVO_KEY_[A-Za-z0-9_]*\\)=.*/\\1/p'); do
          (umask 077; printf '%s' "$(printenv "$v")" >"$K/keys/$v"); unset "$v"
        done
        if [ -n "${\(privateSettingsVariable)+set}" ]; then
          (umask 077; printenv \(privateSettingsVariable) >"$K/keys/settings.json")
          export OPENCODE_CONFIG="$K/keys/settings.json"; unset \(privateSettingsVariable)
        fi
        \(Wakes.installScript)
        \(Launcher.installScript)
        \(CommandEnvironment.installScript)
        export PATH="$K/bin:$PATH"
        # Bots' and sessions' folders under this root, for `kuvo-wake` (its default is the app's own root).
        export KUVO_BOTS="$K/bots" KUVO_WAKES="$K/wakes"
        cd "$K/workspace"
        touch "$R/attached"
        setsid "$K/engine/\(OpenCodeEngine.version)/opencode" serve --port "$port" --hostname 127.0.0.1 >"$R/engine.log" 2>&1 </dev/null &
        pid=$!
        i=0
        until grep -q "server listening" "$R/engine.log" 2>/dev/null; do
          if ! kill -0 "$pid" 2>/dev/null || [ $i -ge 900 ]; then tail -n 5 "$R/engine.log" >&2; kill "$pid" 2>/dev/null; rm -rf "$K/keys"; exit 3; fi
          sleep 0.1; i=$((i + 1))
        done
        (umask 077; printf '{"pid":%s,%s\n' "$pid" "$record" >"$R/engine.json")
        \(agentsScript)
        # Kuvo Link, for the phones you've paired: beside the engine, once the Mac has set it up.
        if [ -f "$R/link.json" ] && [ -f "$K/bin/kuvo-link.js" ]; then
          KUVO_HOME="$K" BUN_BE_BUN=1 BUN_RUNTIME_TRANSPILER_CACHE_PATH=0 setsid "$K/engine/\(OpenCodeEngine.version)/opencode" "$K/bin/kuvo-link.js" run >"$R/link.log" 2>&1 </dev/null &
        fi
        setsid sh -c 'i=0; while kill -0 "$1" 2>/dev/null; do sleep 60; grep -q "\\"pid\\":$1," "$2/engine.json" 2>/dev/null || break; "$3/bin/kuvo-wake" fire "$3/bots" "$2/engine.json" 2>/dev/null; i=$((i + 1)); [ $((i % 10)) -eq 0 ] || continue; { ls "$3"/bots/*/wakes/* || ls -d "$3"/bots/*/watches/*/ || ls "$3"/wakes/*/wakes/* || ls -d "$3"/wakes/*/watches/*/; } >/dev/null 2>&1 && continue; [ -n "$(find "$2/attached" -mmin +1440 2>/dev/null)" ] && kill "$1"; done; [ "$(cat "$3/keys/.launch" 2>/dev/null)" = "$4" ] && rm -rf "$3/keys"' watchdog "$pid" "$R" "$K" "$launch" >/dev/null 2>&1 </dev/null &
        echo "$pid"
        """
    }

    /// Connects to `engine` through a tunnel of its own, and waits until it answers. `onExit` is
    /// called if the tunnel closes without being asked to.
    public static func attach(
        to engine: Engine,
        on connection: SSHConnection,
        timeout: Duration = .seconds(90),
        onExit: @escaping @Sendable (Int32) -> Void = { _ in }
    ) async throws -> RemoteServer {
        let localPort = try freeLocalPort()
        var forwards = ["-o", "ExitOnForwardFailure=yes", "-L", "\(localPort):127.0.0.1:\(engine.port)"]
        // The agents bridge beside it, through the same connection.
        var agentsEndpoint: ServerEndpoint?
        if let agents = engine.agents {
            let agentsPort = try freeLocalPort(besides: localPort)
            forwards += ["-L", "\(agentsPort):127.0.0.1:\(agents.port)"]
            agentsEndpoint = ServerEndpoint(url: URL(string: "http://127.0.0.1:\(agentsPort)")!, password: agents.password)
        }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh")
        // Not `-N`: a command on the machine that reads this app's end of a pipe, so the tunnel
        // ends when the app does, however it ends (a crash, a force quit), like this Mac's engine.
        process.arguments = SSHConnection.options + SSHConnection.separate + forwards + [connection.destination, "cat >/dev/null"]
        process.standardInput = Pipe.unshared()
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe.unshared()
        process.standardError = stderr
        let log = LogTail()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { log.append(data) }
        }
        let exits = ExitSignal()
        process.terminationHandler = { process in
            if exits.fire() { onExit(process.terminationStatus) }
        }
        try process.run()

        let endpoint = ServerEndpoint(url: URL(string: "http://127.0.0.1:\(localPort)")!, password: engine.password)
        let client = HTTPClient(endpoint: endpoint)
        struct Info: Decodable { var version: String }
        let deadline = ContinuousClock.now + timeout
        do {
            while true {
                if !process.isRunning {
                    process.waitUntilExit()
                    throw RemoteEngineError.exited(status: process.terminationStatus, output: log.text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if (try? await client.send(client.request("GET", "api/info"), as: Info.self)) != nil { break }
                if ContinuousClock.now > deadline { throw RemoteEngineError.timedOut }
                try await Task.sleep(for: .milliseconds(150))
            }
        } catch {
            // Given up on, or cancelled (a reconnect called off): the tunnel goes with it.
            _ = exits.fire()
            if process.isRunning { process.terminate() }
            throw error
        }
        return RemoteServer(engine: engine, endpoint: endpoint, agentsEndpoint: agentsEndpoint, connection: connection, tunnel: process, log: log)
    }

    /// Closes the tunnel. The engine keeps running on the machine.
    public func disconnect() {
        tunnel.terminationHandler = nil
        if tunnel.isRunning { tunnel.terminate() }
    }

    deinit { disconnect() }

    /// Starts the agents bridge beside the engine (`$pid`, listening on `$port`), when it's asked
    /// for (`$aport`, `$apass`) and on the machine: in a session of its own, from the engine's
    /// workspace, with everything it keeps in `$K/agents`; an older one there stops first. It
    /// stops by itself when the engine does. Its process is kept in `run/agents.pid`.
    static var agentsScript: String {
        """
        if [ -n "$aport" ] && [ -n "$apass" ] && [ -f "$K/bin/kuvo-agents.js" ]; then
          \(stopAgentsScript)
          mkdir -p "$K/agents" && chmod 700 "$K/agents"
          KUVO_AGENTS_REMOTE=1 KUVO_AGENTS_HOME="$K/agents" KUVO_HOME="$K" KUVO_AGENTS_PORT="$aport" KUVO_AGENTS_PASSWORD="$apass" KUVO_ENGINE_PORT="$port" KUVO_ENGINE_PID="$pid" BUN_BE_BUN=1 BUN_RUNTIME_TRANSPILER_CACHE_PATH=0 setsid "$K/engine/\(OpenCodeEngine.version)/opencode" "$K/bin/kuvo-agents.js" >"$R/agents.log" 2>&1 </dev/null &
          echo $! >"$R/agents.pid"
        fi
        """
    }

    /// Stops the agents bridge running there, if one is (needs `$R`), and waits a moment for it to
    /// put away what it has.
    static var stopAgentsScript: String {
        """
        apid=$(cat "$R/agents.pid" 2>/dev/null)
        if [ -n "$apid" ] && grep -q kuvo-agents "/proc/$apid/cmdline" 2>/dev/null; then kill "$apid" 2>/dev/null; i=0; while kill -0 "$apid" 2>/dev/null && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done; fi
        rm -f "$R/agents.pid"
        """
    }

    static var stopScript: String {
        """
        R="\(run)"
        rm -rf "${R%/run}/keys"
        \(stopAgentsScript)
        [ -f "$R/engine.json" ] || exit 0
        pid=$(sed -n 's/^{"pid":\\([0-9]*\\),.*/\\1/p' "$R/engine.json")
        [ -n "$pid" ] && grep -q opencode "/proc/$pid/cmdline" 2>/dev/null && kill "$pid"
        rm -f "$R/engine.json"
        """
    }

    /// What stops the engine, as part of a longer script (in a shell of its own: it ends early when
    /// there's nothing to stop).
    public static var stopCommand: String { "(\n" + stopScript + "\n)" }

    /// Stops the engine on the machine, if it's running.
    public static func stop(on connection: SSHConnection) async throws {
        try await connection.run(stopScript)
    }

    /// Stops the engine on the machine without waiting more than `timeout`, for when the app quits.
    /// With `unlessWaking`, an engine with bots' or sessions' wake-ups waiting keeps running, to
    /// send them. `first` runs before, either way.
    public static func stopNow(on connection: SSHConnection, timeout: TimeInterval = 3, unlessWaking: Bool = false, first: String = "") {
        let root = "\"$HOME/\(RemoteEngineInstaller.root)\""
        let waiting = "{ ls \(root)/bots/*/wakes/* || ls -d \(root)/bots/*/watches/*/ || ls \(root)/wakes/*/wakes/* || ls -d \(root)/wakes/*/watches/*/; } >/dev/null 2>&1 && exit 0\n"
        runNow(first + (unlessWaking ? waiting : "") + stopScript, on: connection, timeout: timeout)
    }

    /// Runs `script` on the machine without waiting more than `timeout`, for when the app quits.
    public static func runNow(_ script: String, on connection: SSHConnection, timeout: TimeInterval = 3) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh")
        process.arguments = connection.arguments(running: script)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let deadline = Date.now.addingTimeInterval(timeout)
        while process.isRunning, Date.now < deadline { usleep(50_000) }
        if process.isRunning { process.terminate() }
    }

    /// Tells the machine's phone link bridge that the Mac `mac` is here, telling your phones what
    /// happens in the machine's sessions itself, so the bridge doesn't (KuvoLink's PROTOCOL.md,
    /// "Notifications"). Good for a couple of minutes; said again each minute. False when it
    /// couldn't be said.
    @discardableResult
    public static func markPresent(_ mac: String, on connection: SSHConnection) async -> Bool {
        (try? await connection.run("mkdir -p \"\(run)/present\" && touch \"\(run)/present/\(mac)\"")) != nil
    }

    /// Takes the Mac `mac` out of the machine's present ones, as it quits: what `stopNow` runs first.
    public static func leavingScript(_ mac: String) -> String {
        "rm -f \"\(run)/present/\(mac)\"\n"
    }

    /// Tells the engine's watchdog the app is still around.
    public static func heartbeat(on connection: SSHConnection) async {
        _ = try? await connection.run("touch \"\(run)/attached\" 2>/dev/null || true")
    }

    /// A port nobody on this Mac is listening on right now, other than `taken`.
    static func freeLocalPort(besides taken: Int) throws -> Int {
        for _ in 0..<5 {
            let port = try freeLocalPort()
            if port != taken { return port }
        }
        throw POSIXError(.EADDRINUSE)
    }

    /// A port nobody on this Mac is listening on right now.
    static func freeLocalPort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.EMFILE) }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRINUSE) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// True the first time only: whichever comes first of the tunnel closing and giving up on it.
final class ExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() -> Bool {
        lock.withLock {
            defer { fired = true }
            return !fired
        }
    }
}

#endif

/// Launch files an earlier run of the app left when it stopped mid-launch: they hold every key
/// and the engine's password. Cleared once, before the first launch.
private let clearedLeftovers: Void = {
    let folder = FileManager.default.temporaryDirectory
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    for name in names where name.hasPrefix("kuvo-engine-") {
        let file = folder.appending(path: name)
        let changed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if changed.timeIntervalSinceNow < -600 { try? FileManager.default.removeItem(at: file) }
    }
}()
