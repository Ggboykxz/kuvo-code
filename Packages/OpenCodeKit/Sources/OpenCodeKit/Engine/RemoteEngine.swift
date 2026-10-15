import Foundation

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
        return ["-o", "ControlMaster=auto", "-o", "ControlPath=\(folder)/%C", "-o", "ControlPersist=120"]
    }

    /// The engine's own connection stays apart, so its tunnels end with it.
    static let separate = ["-o", "ControlMaster=no", "-o", "ControlPath=none"]

    /// The `ssh` arguments that run `script` on the machine with `sh`, whatever its login shell.
    public func arguments(running script: String, extra: [String] = [], shared: Bool = true) -> [String] {
        Self.options + (shared ? Self.sharing : Self.separate) + extra + [destination, "sh -c " + Self.quoted(script)]
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

    /// The folder in the machine's home with everything Kuvo Code keeps there.
    public static let root = ".kuvo-code"

    var remoteExecutable: String { "$HOME/\(Self.root)/engine/\(OpenCodeEngine.version)/opencode" }

    /// Gives the engine folders of its own in `~/.kuvo-code` (`$K`), for everything it runs there,
    /// so it never touches the machine's own opencode, if it has one.
    static let folders = """
        K="$HOME/\(root)"
        export XDG_DATA_HOME="$K/data" XDG_CONFIG_HOME="$K/config" XDG_STATE_HOME="$K/state" XDG_CACHE_HOME="$K/cache"
        mkdir -p "$K/data" "$K/config" "$K/state" "$K/cache" "$K/workspace"
        """

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
/// the machine's localhost only, behind a password, and this Mac reaches it through an SSH tunnel
/// (with, for the browser tools, a port on the machine back to this Mac). Its settings and secrets
/// (the password, accounts) go over the session's input rather than a command line, so other users
/// of the machine can't read them in its process list, and the accounts are never written to its
/// disk. What's needed to find it again (its process, port and password) is kept in
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
    }

    public let engine: Engine
    public let endpoint: ServerEndpoint
    public let connection: SSHConnection
    /// Whether the tunnel brings a port on the machine back to this Mac.
    public let hasReverse: Bool
    private let tunnel: Process
    private let log: LogTail

    private init(engine: Engine, endpoint: ServerEndpoint, connection: SSHConnection, hasReverse: Bool, tunnel: Process, log: LogTail) {
        self.engine = engine
        self.endpoint = endpoint
        self.connection = connection
        self.hasReverse = hasReverse
        self.tunnel = tunnel
        self.log = log
    }

    public var isConnected: Bool { tunnel.isRunning }

    /// The last lines ssh wrote, for error reports.
    public var recentOutput: String { log.text }

    /// A port on the machine that reaches a port on this Mac.
    public struct ReverseForward: Sendable {
        public var remotePort: Int
        public var localPort: Int

        public init(remotePort: Int, localPort: Int) {
            self.remotePort = remotePort
            self.localPort = localPort
        }
    }

    static let run = "$HOME/\(RemoteEngineInstaller.root)/run"

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
    /// is handed to it, with values on one line each; `notes` are kept with it.
    public static func launch(on connection: SSHConnection, environment base: [String: String], notes: [String: String] = [:]) async throws -> Engine {
        var lastError: Error = RemoteEngineError.timedOut
        // A port someone else took on the machine: try another.
        for _ in 0..<3 {
            var engine = Engine(pid: 0, port: Int.random(in: 20_000..<60_000), password: ServerProcess.randomPassword(), version: OpenCodeEngine.version, notes: notes)
            var environment = base
            environment["OPENCODE_PASSWORD"] = engine.password
            environment["OPENCODE_CLIENT"] = "desktop"
            environment.removeValue(forKey: "OPENCODE_SERVER_PASSWORD")
            // What's kept to find it again, but its process, which the script adds.
            struct Record: Encodable { var port: Int, password: String, version: String, notes: [String: String] }
            let record = String(decoding: try JSONEncoder().encode(Record(port: engine.port, password: engine.password, version: engine.version, notes: engine.notes)), as: UTF8.self)
            environment["KUVO_RECORD"] = String(record.dropFirst())
            environment["KUVO_PORT"] = String(engine.port)
            let lines = environment.sorted { $0.key < $1.key }
                .filter { !$0.value.contains("\n") }
                .map { "\($0.key)=\($0.value)\n" }
                .joined() + "\n"
            let input = FileManager.default.temporaryDirectory.appending(path: "kuvo-engine-\(UUID().uuidString)")
            // Only this user can read it, and it's gone as soon as ssh has sent it.
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

    /// Reads the settings from the input, gives the engine its own folders under `~/.kuvo-code`,
    /// starts it in a session of its own on the machine's localhost, writes down how to find it,
    /// and starts its watchdog. Prints its process once it listens.
    static var launchScript: String {
        """
        while IFS= read -r line && [ -n "$line" ]; do export "$line"; done
        port=$KUVO_PORT; record=$KUVO_RECORD; unset KUVO_PORT KUVO_RECORD
        \(RemoteEngineInstaller.folders)
        R="$K/run"; mkdir -p "$R"; chmod 700 "$R"
        cd "$K/workspace"
        touch "$R/attached"
        setsid "$K/engine/\(OpenCodeEngine.version)/opencode" serve --port "$port" --hostname 127.0.0.1 >"$R/engine.log" 2>&1 </dev/null &
        pid=$!
        i=0
        until grep -q "server listening" "$R/engine.log" 2>/dev/null; do
          if ! kill -0 "$pid" 2>/dev/null || [ $i -ge 900 ]; then tail -n 5 "$R/engine.log" >&2; kill "$pid" 2>/dev/null; exit 3; fi
          sleep 0.1; i=$((i + 1))
        done
        (umask 077; printf '{"pid":%s,%s\n' "$pid" "$record" >"$R/engine.json")
        setsid sh -c 'while kill -0 "$1" 2>/dev/null; do sleep 600; [ -n "$(find "$2/attached" -mmin +1440 2>/dev/null)" ] && kill "$1"; done' watchdog "$pid" "$R" >/dev/null 2>&1 </dev/null &
        echo "$pid"
        """
    }

    /// Connects to `engine` through a tunnel of its own, and waits until it answers. `onExit` is
    /// called if the tunnel closes without being asked to.
    public static func attach(
        to engine: Engine,
        on connection: SSHConnection,
        reverse: [ReverseForward] = [],
        timeout: Duration = .seconds(90),
        onExit: @escaping @Sendable (Int32) -> Void = { _ in }
    ) async throws -> RemoteServer {
        do {
            return try await tunnel(to: engine, on: connection, reverse: reverse, timeout: timeout, onExit: onExit)
        } catch RemoteEngineError.exited(_, let output) where !reverse.isEmpty && output.localizedCaseInsensitiveContains("remote port forwarding failed") {
            // The port back to this Mac is still held by a connection the machine hasn't noticed
            // is gone: connect without it for now.
            return try await tunnel(to: engine, on: connection, reverse: [], timeout: timeout, onExit: onExit)
        }
    }

    private static func tunnel(to engine: Engine, on connection: SSHConnection, reverse: [ReverseForward], timeout: Duration, onExit: @escaping @Sendable (Int32) -> Void) async throws -> RemoteServer {
        let localPort = try freeLocalPort()
        var forwards = ["-N", "-o", "ExitOnForwardFailure=yes", "-L", "\(localPort):127.0.0.1:\(engine.port)"]
        for forward in reverse { forwards += ["-R", "\(forward.remotePort):127.0.0.1:\(forward.localPort)"] }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh")
        process.arguments = SSHConnection.options + SSHConnection.separate + forwards + [connection.destination]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
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
        while true {
            if !process.isRunning {
                process.waitUntilExit()
                _ = exits.fire()
                throw RemoteEngineError.exited(status: process.terminationStatus, output: log.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if (try? await client.send(client.request("GET", "api/info"), as: Info.self)) != nil { break }
            if ContinuousClock.now > deadline {
                _ = exits.fire()
                process.terminate()
                throw RemoteEngineError.timedOut
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        return RemoteServer(engine: engine, endpoint: endpoint, connection: connection, hasReverse: !reverse.isEmpty, tunnel: process, log: log)
    }

    /// Closes the tunnel. The engine keeps running on the machine.
    public func disconnect() {
        tunnel.terminationHandler = nil
        if tunnel.isRunning { tunnel.terminate() }
    }

    deinit { disconnect() }

    static var stopScript: String {
        """
        R="\(run)"
        [ -f "$R/engine.json" ] || exit 0
        pid=$(sed -n 's/^{"pid":\\([0-9]*\\),.*/\\1/p' "$R/engine.json")
        [ -n "$pid" ] && grep -q opencode "/proc/$pid/cmdline" 2>/dev/null && kill "$pid"
        rm -f "$R/engine.json"
        """
    }

    /// Stops the engine on the machine, if it's running.
    public static func stop(on connection: SSHConnection) async throws {
        try await connection.run(stopScript)
    }

    /// Stops the engine on the machine without waiting more than `timeout`, for when the app quits.
    public static func stopNow(on connection: SSHConnection, timeout: TimeInterval = 3) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh")
        process.arguments = connection.arguments(running: stopScript)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let deadline = Date.now.addingTimeInterval(timeout)
        while process.isRunning, Date.now < deadline { usleep(50_000) }
        if process.isRunning { process.terminate() }
    }

    /// Tells the engine's watchdog the app is still around.
    public static func heartbeat(on connection: SSHConnection) async {
        _ = try? await connection.run("touch \"\(run)/attached\" 2>/dev/null || true")
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
