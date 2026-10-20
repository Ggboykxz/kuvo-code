import Foundation

/// Answers for web services the app calls (GitHub's API, its raw files), so tests never reach the
/// network: each test registers what an address answers, and addresses it didn't register answer
/// 404. Only the hosts given are stubbed; the app's other requests go out as they would.
nonisolated final class StubWeb: URLProtocol, @unchecked Sendable {
    struct Answer: Sendable {
        var status = 200
        var body = Data()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: Answer] = [:]
    /// Answers by address without its query, worked out from the request (its query, a page).
    nonisolated(unsafe) private static var routes: [String: @Sendable (URLComponents) -> Answer] = [:]
    nonisolated(unsafe) private static var hosts: Set<String> = []
    nonisolated(unsafe) private(set) static var asked: [String] = []

    /// Starts answering for `hosts`, with nothing registered yet.
    static func start(hosts: Set<String>) {
        lock.withLock {
            answers = [:]
            routes = [:]
            asked = []
            Self.hosts = hosts
        }
        URLProtocol.registerClass(StubWeb.self)
    }

    static func stop() {
        URLProtocol.unregisterClass(StubWeb.self)
        lock.withLock { hosts = [] }
    }

    static func answer(_ url: String, status: Int = 200, json: Any) throws {
        let body = try JSONSerialization.data(withJSONObject: json)
        lock.withLock { answers[url] = Answer(status: status, body: body) }
    }

    static func answer(_ url: String, status: Int = 200, text: String) {
        lock.withLock { answers[url] = Answer(status: status, body: Data(text.utf8)) }
    }

    /// Answers requests to `url` (any query) with what `answer` makes of each.
    static func route(_ url: String, _ answer: @escaping @Sendable (URLComponents) -> Answer) {
        lock.withLock { routes[url] = answer }
    }

    static func json(_ value: Any, status: Int = 200) -> Answer {
        Answer(status: status, body: (try? JSONSerialization.data(withJSONObject: value)) ?? Data())
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return lock.withLock { hosts.contains(host) }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var bare = components
        bare.query = nil
        let route = Self.lock.withLock {
            Self.asked.append(url.absoluteString)
            return Self.routes[bare.string ?? ""]
        }
        let answer = Self.lock.withLock { Self.answers[url.absoluteString] } ?? route?(components) ?? Answer(status: 404)
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
