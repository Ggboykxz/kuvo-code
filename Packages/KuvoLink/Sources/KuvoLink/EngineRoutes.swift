import Foundation

/// What a phone may ask an engine for, and passing it on: the Mac's side of what a machine's
/// bridge does in `kuvo-link.js` (the two lists are checked against `Vectors/link.json`).
public enum EngineRoutes {
    /// Sessions and what's in them, live events, and what the phone needs to show them. Never
    /// accounts, keys or integrations, the engine's settings, MCP servers or plugins.
    public static func allows(_ path: String) -> Bool {
        guard !path.contains("..") else { return false }
        return path.prefixMatch(of: #/api/session(/|\?|$)/#) != nil
            || path.prefixMatch(of: #/api/experimental/session/[^/]+/wait(\?|$)/#) != nil
            || path.prefixMatch(of: #/api/event(\?|$)/#) != nil
            || path.prefixMatch(of: #/api/(info|agent|command|model|provider|project|location|skill|vcs|worktree|permission|form)(/|\?|$)/#) != nil
    }

    static let requestHeaders = ["content-type", "accept", "x-opencode-directory", "last-event-id"]
    static let responseHeaders = ["content-type", "cache-control"]

    /// Passes `request` to the engine at `base` (its password added here), and its response back
    /// in pieces as they come: an event stream's events one by one.
    public static func forward(_ request: LinkRequest, to base: URL, password: String?, session: URLSession = .shared) -> AsyncThrowingStream<LinkResponsePart, Error> {
        AsyncThrowingStream { continuation in
            guard allows(request.path) else {
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
                    // In pieces: at each line's end, so an event goes as soon as it's whole, or
                    // every 32 KB of a long body.
                    var piece = Data()
                    piece.reserveCapacity(32 * 1024)
                    for try await byte in bytes {
                        piece.append(byte)
                        if byte == UInt8(ascii: "\n") || piece.count >= 32 * 1024 {
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
