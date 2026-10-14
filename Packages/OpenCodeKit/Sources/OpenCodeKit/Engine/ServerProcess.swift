import Foundation

/// Folders the engine keeps its database, config, state and caches in. The app
/// gives it its own, so it never migrates or shares an `opencode` install's data.
public struct EngineFolders: Sendable {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The engine's own working directory, and so the default project for calls that
    /// don't name one (the catalog). Kept empty on purpose: with the home folder there,
    /// the engine scans ~ and macOS stops it with "would like to access your Desktop".
    public var workspace: URL { root.appending(path: "workspace") }

    /// Where the engine keeps its database (`opencode*.db`) and logs.
    public var dataDirectory: URL { root.appending(path: "data/opencode") }

    /// The engine's global settings file, which it reloads when the file changes. Its
    /// `skills` folder beside it holds skills every project can use.
    public var configFile: URL { root.appending(path: "config/opencode/opencode.json") }

    var environment: [String: String] {
        [
            "XDG_DATA_HOME": root.appending(path: "data").path,
            "XDG_CONFIG_HOME": root.appending(path: "config").path,
            "XDG_STATE_HOME": root.appending(path: "state").path,
            "XDG_CACHE_HOME": root.appending(path: "cache").path,
        ]
    }

    func create() throws {
        for path in environment.values + [workspace.path] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }
}

public enum ServerProcessError: LocalizedError {
    case exited(status: Int32, output: String)
    case unreadableHandshake(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .exited(let status, let output):
            "The engine stopped (exit code \(status)).\(output.isEmpty ? "" : "\n\n\(output)")"
        case .unreadableHandshake(let line): "The engine said something unexpected when starting: \(line)"
        case .timedOut: "The engine took too long to start."
        }
    }
}

/// A private opencode server that lives exactly as long as this object.
///
/// Started as `opencode serve --stdio --port 0`: the server picks a free port,
/// prints `{"url": …}` as its first line, and exits when its stdin closes, so
/// it can't outlive the app even if the app crashes.
public final class ServerProcess: @unchecked Sendable {
    public let endpoint: ServerEndpoint
    private let process: Process
    private let stdin: Pipe
    private let log: LogTail

    private init(endpoint: ServerEndpoint, process: Process, stdin: Pipe, log: LogTail) {
        self.endpoint = endpoint
        self.process = process
        self.stdin = stdin
        self.log = log
    }

    public var isRunning: Bool { process.isRunning }

    /// The last lines the server wrote to stderr, for error reports.
    public var recentOutput: String { log.text }

    /// Starts the server and waits until it's listening.
    public static func start(
        executable: URL,
        folders: EngineFolders,
        environment base: [String: String],
        timeout: Duration = .seconds(60),
        onExit: @escaping @Sendable (Int32) -> Void = { _ in }
    ) async throws -> ServerProcess {
        try folders.create()
        let password = Self.randomPassword()

        var environment = base
        for (key, value) in folders.environment { environment[key] = value }
        environment["OPENCODE_PASSWORD"] = password
        // Tells the server it's driven by a desktop GUI (what opencode's own desktop app sends).
        environment["OPENCODE_CLIENT"] = "desktop"
        environment.removeValue(forKey: "OPENCODE_SERVER_PASSWORD")

        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", "--stdio", "--port", "0"]
        process.environment = environment
        process.currentDirectoryURL = folders.workspace
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

        let url: URL
        do {
            url = try await withThrowingTaskGroup(of: URL.self) { group in
                group.addTask { try await Self.readHandshake(from: stdout.fileHandleForReading, process: process, log: log) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ServerProcessError.timedOut
                }
                let url = try await group.next()!
                group.cancelAll()
                return url
            }
        } catch {
            process.terminate()
            throw error
        }

        // Keep draining stdout so the server never blocks on a full pipe.
        stdout.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        return ServerProcess(endpoint: ServerEndpoint(url: url, password: password), process: process, stdin: stdin, log: log)
    }

    /// Closing stdin is the server's signal to shut down cleanly.
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
            // stdout closed before the handshake: the server died while starting.
            process.waitUntilExit()
            throw ServerProcessError.exited(status: process.terminationStatus, output: log.text)
        }
        struct Handshake: Decodable { var url: URL }
        guard let handshake = try? JSONDecoder().decode(Handshake.self, from: line) else {
            throw ServerProcessError.unreadableHandshake(String(decoding: line, as: UTF8.self))
        }
        return handshake.url
    }

    private static func randomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The last few kilobytes of a stream.
final class LogTail: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let limit = 16 * 1024

    func append(_ data: Data) {
        lock.withLock {
            buffer.append(data)
            if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
        }
    }

    var text: String {
        lock.withLock { String(decoding: buffer, as: UTF8.self) }
    }
}
