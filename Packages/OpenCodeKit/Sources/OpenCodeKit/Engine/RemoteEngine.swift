import Foundation

/// A machine reached over SSH: a host from `~/.ssh/config` (like `lokum-local`) or `user@host`.
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

    /// The `ssh` arguments that run `script` on the machine with `sh`, whatever its login shell.
    public func arguments(running script: String, extra: [String] = []) -> [String] {
        Self.options + extra + [destination, "sh -c " + Self.quoted(script)]
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

    /// Makes sure the engine is on the machine. `progress` gets the fraction downloaded, when it is.
    public func install(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let probe = try await connection.run("""
            uname -sm
            if ldd --version 2>&1 | grep -qi musl; then echo musl; else echo glibc; fi
            test -x "\(remoteExecutable)" && "\(remoteExecutable)" --version 2>/dev/null || true
            """)
        let lines = probe.split(separator: "\n").map(String.init)
        if lines.count > 2, lines[2].hasSuffix(OpenCodeEngine.version) { return }
        let platform = lines.first ?? ""
        let parts = platform.split(separator: " ")
        guard parts.first == "Linux", lines.dropFirst().first == "glibc", let machine = parts.last,
              let release = EngineRelease.linux(machine: String(machine)) else {
            throw RemoteEngineError.unsupportedPlatform(platform + (lines.dropFirst().first == "musl" ? " (musl)" : ""))
        }
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

/// The engine on a machine, reached through SSH, that lives exactly as long as this object.
///
/// One `ssh` process carries everything: it starts `opencode serve --stdio` on the machine, bound to
/// its localhost, and forwards a local port to it (and, for the browser tools, a port on the machine
/// back to this Mac). The engine's settings and secrets (its password, accounts) go over the
/// session's input rather than its command line, so other users of the machine can't read them in
/// its process list, and they're never written to its disk. Closing the input, or losing the
/// connection, ends the engine there.
public final class RemoteServer: @unchecked Sendable {
    public let endpoint: ServerEndpoint
    public let connection: SSHConnection
    private let process: Process
    private let stdin: Pipe
    private let log: LogTail

    private init(endpoint: ServerEndpoint, connection: SSHConnection, process: Process, stdin: Pipe, log: LogTail) {
        self.endpoint = endpoint
        self.connection = connection
        self.process = process
        self.stdin = stdin
        self.log = log
    }

    public var isRunning: Bool { process.isRunning }

    /// The last lines ssh and the engine wrote to stderr, for error reports.
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

    /// Starts the engine on the machine and waits until it's listening. `environment` is handed to
    /// it, with values on one line each.
    public static func start(
        connection: SSHConnection,
        environment base: [String: String],
        reverse: [ReverseForward] = [],
        timeout: Duration = .seconds(90),
        onExit: @escaping @Sendable (Int32) -> Void = { _ in }
    ) async throws -> RemoteServer {
        var lastError: Error = RemoteEngineError.timedOut
        // A port someone else took on the machine: try another.
        for _ in 0..<3 {
            do {
                return try await attempt(connection: connection, environment: base, reverse: reverse, timeout: timeout, onExit: onExit)
            } catch RemoteEngineError.exited(let status, let output) where output.localizedCaseInsensitiveContains("in use") || output.contains("forwarding failed") {
                lastError = RemoteEngineError.exited(status: status, output: output)
            }
        }
        throw lastError
    }

    private static func attempt(
        connection: SSHConnection,
        environment base: [String: String],
        reverse: [ReverseForward],
        timeout: Duration,
        onExit: @escaping @Sendable (Int32) -> Void
    ) async throws -> RemoteServer {
        let password = ServerProcess.randomPassword()
        let remotePort = Int.random(in: 20_000..<60_000)
        let localPort = try freeLocalPort()

        var environment = base
        environment["OPENCODE_PASSWORD"] = password
        environment["OPENCODE_CLIENT"] = "desktop"
        environment.removeValue(forKey: "OPENCODE_SERVER_PASSWORD")

        var forwards = ["-o", "ExitOnForwardFailure=yes", "-L", "\(localPort):127.0.0.1:\(remotePort)"]
        for forward in reverse { forwards += ["-R", "\(forward.remotePort):127.0.0.1:\(forward.localPort)"] }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh")
        process.arguments = connection.arguments(running: script(remotePort: remotePort), extra: forwards)
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let log = LogTail()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { log.append(data) }
        }
        process.terminationHandler = { process in onExit(process.terminationStatus) }
        try process.run()

        // The settings, one per line, then an empty line; the input then stays open for the engine.
        let lines = environment.sorted { $0.key < $1.key }
            .filter { !$0.value.contains("\n") }
            .map { "\($0.key)=\($0.value)\n" }
            .joined() + "\n"
        stdin.fileHandleForWriting.write(Data(lines.utf8))

        do {
            _ = try await withThrowingTaskGroup(of: URL.self) { group in
                group.addTask { try await readHandshake(from: stdout.fileHandleForReading, process: process, log: log) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw RemoteEngineError.timedOut
                }
                let url = try await group.next()!
                group.cancelAll()
                return url
            }
        } catch {
            process.terminate()
            throw error
        }

        stdout.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        let endpoint = ServerEndpoint(url: URL(string: "http://127.0.0.1:\(localPort)")!, password: password)
        return RemoteServer(endpoint: endpoint, connection: connection, process: process, stdin: stdin, log: log)
    }

    /// Reads the settings from the input, gives the engine its own folders under `~/.kuvo-code`
    /// (apart from any opencode installed there), and starts it on the machine's localhost.
    static func script(remotePort: Int) -> String {
        """
        while IFS= read -r line && [ -n "$line" ]; do export "$line"; done
        K="$HOME/\(RemoteEngineInstaller.root)"
        export XDG_DATA_HOME="$K/data" XDG_CONFIG_HOME="$K/config" XDG_STATE_HOME="$K/state" XDG_CACHE_HOME="$K/cache"
        mkdir -p "$K/data" "$K/config" "$K/state" "$K/cache" "$K/workspace"
        cd "$K/workspace"
        exec "$K/engine/\(OpenCodeEngine.version)/opencode" serve --stdio --port \(remotePort) --hostname 127.0.0.1
        """
    }

    /// Closing the input is the engine's signal to stop; ssh goes with it.
    public func stop() {
        try? stdin.fileHandleForWriting.close()
        let process = process
        Task.detached {
            try? await Task.sleep(for: .seconds(5))
            if process.isRunning { process.terminate() }
        }
    }

    deinit { stop() }

    private static func readHandshake(from handle: FileHandle, process: Process, log: LogTail) async throws -> URL {
        var line = Data()
        for try await byte in handle.bytes {
            if byte == UInt8(ascii: "\n") { break }
            line.append(byte)
        }
        guard !line.isEmpty else {
            process.waitUntilExit()
            throw RemoteEngineError.exited(status: process.terminationStatus, output: log.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        struct Handshake: Decodable { var url: URL }
        guard let handshake = try? JSONDecoder().decode(Handshake.self, from: line) else {
            throw RemoteEngineError.unreadableHandshake(String(decoding: line, as: UTF8.self))
        }
        return handshake.url
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
