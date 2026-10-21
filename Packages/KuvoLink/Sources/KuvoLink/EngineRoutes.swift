import Foundation

/// What a phone may ask an engine for, and passing it on: the Mac's side of what a machine's
/// bridge does in `kuvo-link.js` (the two lists are checked against `Vectors/link.json`).
public enum EngineRoutes {
    /// Sessions and what's in them, live events, what the phone needs to show them, a project's
    /// files to read, and terminals. Never accounts, keys or integrations, the engine's settings,
    /// MCP servers or plugins.
    public static func allows(_ path: String, method: String = "GET") -> Bool {
        guard staysInProject(path) else { return false }
        // Commands the engine runs for agents: read only (the list, one, its output); never run
        // one or remove it.
        if path.prefixMatch(of: #/api/shell(/|\?|$)/#) != nil {
            return ["GET", "HEAD"].contains(method.uppercased()) && path.wholeMatch(of: #/api/shell(/[^/?]+(/output)?)?(\?.*)?/#) != nil
        }
        return path.prefixMatch(of: #/api/session(/|\?|$)/#) != nil
            || path.prefixMatch(of: #/api/experimental/session/[^/]+/wait(\?|$)/#) != nil
            || path.prefixMatch(of: #/api/event(\?|$)/#) != nil
            || path.prefixMatch(of: #/api/(info|agent|command|model|provider|project|location|skill|vcs|worktree|permission|form)(/|\?|$)/#) != nil
            || path.prefixMatch(of: #/api/fs/(list|find)(\?|$)/#) != nil
            || path.prefixMatch(of: #/api/fs/read//#) != nil
            || path.prefixMatch(of: #/api/pty(/|\?|$)/#) != nil
    }

    /// What a phone may ask a Mac's coding agents' bridge for: what it may ask an engine for, and
    /// their accounts (adding, naming, removing and signing in to them) and Auto's list. Never
    /// where the engine is, nor updating an agent's program (that runs an installer on the Mac).
    public static func allowsAgents(_ path: String, method: String = "GET") -> Bool {
        guard staysInProject(path) else { return false }
        let routed = routed(path)
        if routed.prefixMatch(of: #/api/kuvo/engine(/|\?|$)/#) != nil { return false }
        if routed.prefixMatch(of: #/api/integration/[^/?]+/update(/|\?|$)/#) != nil { return false }
        return allows(path, method: method)
            || path.prefixMatch(of: #/api/integration(/|\?|$)/#) != nil
            || path.prefixMatch(of: #/api/kuvo/(auto|accounts)(/|\?|$)/#) != nil
    }

    /// `path` as the agents bridge routes it: split into parts, without empty ones or "." ones
    /// (which its URL parser drops, "%2e" too), each decoded ("%75pdate" is "update"). So
    /// "integration/x//update", ".../x/./update" and ".../x/%75pdate" are "integration/x/update".
    static func routed(_ path: String) -> String {
        let query = path.firstIndex(of: "?")
        let parts = path[..<(query ?? path.endIndex)].split(separator: "/")
            .filter { $0 != "." && $0.lowercased() != "%2e" }
            .map { $0.removingPercentEncoding ?? String($0) }
        return parts.joined(separator: "/") + (query.map { String(path[$0...]) } ?? "")
    }

    /// The sockets a phone may open: a terminal's.
    public static func allowsSocket(_ path: String) -> Bool {
        staysInProject(path) && path.prefixMatch(of: #/api/pty/[^/?]+/connect(\?|$)/#) != nil
    }

    /// No way out of the project, written plainly or percent-encoded ("%2E%2E"): the engine
    /// decodes it, and lists a folder above the project if asked. Nor a fragment ("#…"), which
    /// isn't sent: ".../update#x" would be checked as itself and reach ".../update". Nor tabs,
    /// line breaks or other control characters, which URL parsers drop (".\t." is ".." to them),
    /// nor a space at either end, which they drop too (".../update " is ".../update" to them).
    static func staysInProject(_ path: String) -> Bool {
        guard !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              !path.hasPrefix(" "), !path.hasSuffix(" "),
              let decoded = path.removingPercentEncoding else { return false }
        return !decoded.contains("..") && !decoded.contains("\\") && !path.contains("..") && !path.contains("#")
    }

    static let requestHeaders = ["content-type", "accept", "x-opencode-directory", "last-event-id"]
    static let responseHeaders = ["content-type", "cache-control"]

    /// Opens the socket `request` names on the engine at `base` (its password added here): text
    /// from `input` goes to it, and what it sends comes back, `.open` first.
    public static func connect(_ request: LinkRequest, to base: URL, password: String?, input: AsyncStream<Data>) -> AsyncThrowingStream<LinkSocketEvent, Error> {
        AsyncThrowingStream { continuation in
            guard allowsSocket(request.path), let url = URL(string: request.path, relativeTo: base),
                  var components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: false)
            else { return continuation.finish(throwing: URLError(.badURL)) }
            components.scheme = components.scheme == "https" ? "wss" : "ws"
            guard let socketURL = components.url else { return continuation.finish(throwing: URLError(.badURL)) }
            var outgoing = URLRequest(url: socketURL)
            if let directory = request.headers["x-opencode-directory"] { outgoing.setValue(directory, forHTTPHeaderField: "x-opencode-directory") }
            if let password { outgoing.setValue("Basic " + Data("opencode:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
            // A session of its own, to hear when the socket's open.
            let watcher = SocketWatcher()
            let session = URLSession(configuration: .ephemeral, delegate: watcher, delegateQueue: nil)
            let socket = session.webSocketTask(with: outgoing)
            socket.resume()
            let reading = Task {
                do {
                    try await watcher.opened()
                    continuation.yield(.open)
                    while true {
                        switch try await socket.receive() {
                        case .string(let text): continuation.yield(.text(Data(text.utf8)))
                        case .data(let data): continuation.yield(.binary(data))
                        @unknown default: break
                        }
                    }
                } catch {
                    // Closed by the engine (the shell exited): the end, not a failure.
                    if socket.closeCode != .invalid { continuation.finish() } else { continuation.finish(throwing: error) }
                }
            }
            let writing = Task {
                for await text in input {
                    try? await socket.send(.string(String(decoding: text, as: UTF8.self)))
                }
                socket.cancel(with: .normalClosure, reason: nil)
            }
            continuation.onTermination = { _ in
                reading.cancel()
                writing.cancel()
                socket.cancel(with: .goingAway, reason: nil)
                session.finishTasksAndInvalidate()
            }
        }
    }

    /// Passes `request` to the engine at `base` (its password added here), and its response back
    /// in pieces as they come: an event stream's events one by one.
    public static func forward(_ request: LinkRequest, to base: URL, password: String?, session: URLSession = .shared,
                               allowing: @Sendable (String, String) -> Bool = { allows($0, method: $1) }) -> AsyncThrowingStream<LinkResponsePart, Error> {
        AsyncThrowingStream { continuation in
            guard allowing(request.path, request.method) else {
                continuation.yield(.head(status: 403, headers: ["content-type": "text/plain"]))
                continuation.yield(.body(Data("That isn’t available over the link.".utf8)))
                continuation.finish()
                return
            }
            let task = Task {
                do {
                    guard let url = URL(string: request.path, relativeTo: base) else { throw URLError(.badURL) }
                    var outgoing = URLRequest(url: url)
                    let method = request.method.uppercased()
                    outgoing.httpMethod = method
                    outgoing.timeoutInterval = .infinity
                    let given = Dictionary(request.headers.map { ($0.key.lowercased(), $0.value) }) { first, _ in first }
                    for name in requestHeaders { if let value = given[name] { outgoing.setValue(value, forHTTPHeaderField: name) } }
                    if let password { outgoing.setValue("Basic " + Data("opencode:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
                    if method != "GET", method != "HEAD" { outgoing.httpBody = request.body }

                    let (bytes, response) = try await session.bytes(for: outgoing)
                    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    var headers: [String: String] = [:]
                    for name in responseHeaders { if let value = http.value(forHTTPHeaderField: name) { headers[name] = value } }
                    continuation.yield(.head(status: http.statusCode, headers: headers))
                    // In pieces: at each event's end (a blank line), so an event goes as soon as
                    // it's whole and each costs the relay one message, or every 32 KB of a long body.
                    var piece = Data()
                    piece.reserveCapacity(32 * 1024)
                    var previous: UInt8 = 0
                    for try await byte in bytes {
                        piece.append(byte)
                        defer { previous = byte }
                        if (byte == UInt8(ascii: "\n") && previous == UInt8(ascii: "\n")) || piece.count >= 32 * 1024 {
                            continuation.yield(.body(piece))
                            piece.removeAll(keepingCapacity: true)
                        }
                    }
                    if !piece.isEmpty { continuation.yield(.body(piece)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Says when a WebSocket task opens, or that it never will.
private final class SocketWatcher: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Void, Error>?
    private var waiting: CheckedContinuation<Void, Error>?

    func opened() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let outcome { continuation.resume(with: outcome) } else { waiting = continuation }
            }
        }
    }

    private func settle(_ result: Result<Void, Error>) {
        lock.withLock {
            guard outcome == nil else { return }
            outcome = result
            waiting?.resume(with: result)
            waiting = nil
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        settle(.success(()))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        settle(.failure(error ?? URLError(.networkConnectionLost)))
    }
}
