import CryptoKit
import Foundation
import Testing
@testable import KuvoLink

/// A relay in memory: passes `send`s to whoever is connected at the address.
final class MemoryRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var connected: [LinkAddress: Connection] = [:]

    final class Connection: RelayTransport, @unchecked Sendable {
        let address: LinkAddress
        let messages: AsyncStream<RelayMessage>
        let inbox: AsyncStream<RelayMessage>.Continuation
        weak var relay: MemoryRelay?

        init(address: LinkAddress, relay: MemoryRelay) {
            self.address = address
            self.relay = relay
            (messages, inbox) = AsyncStream.makeStream()
        }

        func send(_ message: RelayMessage) { relay?.route(message, from: self) }
        func close() {
            inbox.finish()
            relay?.drop(self)
        }
    }

    func connect(_ secret: RelaySecret) -> Connection {
        let connection = Connection(address: secret.address, relay: self)
        lock.withLock {
            connected[secret.address]?.inbox.finish()
            connected[secret.address] = connection
        }
        return connection
    }

    var connect: LinkClient.Connect {
        { _, secret in self.connect(secret) }
    }

    fileprivate func route(_ message: RelayMessage, from sender: Connection) {
        guard case .send(let to, let payload) = message else { return }
        let target = lock.withLock { connected[to] }
        if let target {
            target.inbox.yield(.deliver(from: sender.address, payload: payload))
        } else {
            sender.inbox.yield(.unreachable(to))
        }
    }

    fileprivate func drop(_ connection: Connection) {
        lock.withLock { if connected[connection.address] === connection { connected[connection.address] = nil } }
    }
}

/// A host on a memory relay, answering with `handle`, letting in phones that show `token` once.
private struct TestHost {
    let key = LinkKey()
    let secret = RelaySecret()
    let token = randomBytes(16)
    let server: LinkServer
    let link: PairingLink

    init(relay: MemoryRelay, handle: @escaping LinkServer.Handle) {
        let paired = Paired()
        let token = self.token
        server = LinkServer(key: key, hello: HostHello(kind: .mac, name: "Test Mac", app: "0.0.1", engine: "2.0.30"), authorize: { key, hello in
            if paired.contains(key) { return true }
            guard hello.pair == token.base64URL else { return false }
            paired.insert(key)
            return true
        }, handle: handle)
        link = PairingLink(relay: URL(string: "wss://relay.test")!, host: secret.address, key: key.publicBytes, token: token, name: "Test Mac")
        let connection = relay.connect(secret)
        Task { [server] in await server.serve(connection) }
    }

    final class Paired: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: Set<Data> = []
        func contains(_ key: Data) -> Bool { lock.withLock { keys.contains(key) } }
        func insert(_ key: Data) { _ = lock.withLock { keys.insert(key) } }
    }
}

private func phone(on relay: MemoryRelay) -> LinkClient {
    LinkClient(relay: URL(string: "wss://relay.test")!, key: LinkKey(), secret: RelaySecret(), name: "Test iPhone", app: "0.0.1", connect: relay.connect)
}

/// Answers with the request's method, path, headers and body, echoed.
private let echo: LinkServer.Handle = { request, _ in
    AsyncThrowingStream { continuation in
        continuation.yield(.head(status: 200, headers: ["content-type": "application/octet-stream", "x-path": request.path, "x-method": request.method, "x-dir": request.headers["x-opencode-directory"] ?? ""]))
        if !request.body.isEmpty { continuation.yield(.body(request.body)) }
        continuation.finish()
    }
}

private func collect(_ stream: LinkResponse) async throws -> (status: Int, headers: [String: String], body: Data) {
    var status = 0, headers: [String: String] = [:], body = Data()
    for try await part in stream {
        switch part {
        case .head(let s, let h): (status, headers) = (s, h)
        case .body(let data): body += data
        }
    }
    return (status, headers, body)
}

@Suite struct LinkTests {
    @Test func pairsThenAnswers() async throws {
        let relay = MemoryRelay()
        let host = TestHost(relay: relay, handle: echo)
        let client = phone(on: relay)
        let paired = try await client.pair(host.link)
        #expect(paired.name == "Test Mac")
        #expect(paired.kind == .mac)

        let response = try await collect(client.send(LinkRequest(path: "api/session?limit=5", headers: ["x-opencode-directory": "/tmp/p"]), to: paired))
        #expect(response.status == 200)
        #expect(response.headers["x-path"] == "api/session?limit=5")
        #expect(response.headers["x-dir"] == "/tmp/p")

        // A second request on the same session.
        let posted = try await collect(client.send(LinkRequest(method: "POST", path: "api/x", body: Data("hello".utf8)), to: paired))
        #expect(posted.headers["x-method"] == "POST")
        #expect(posted.body == Data("hello".utf8))
    }

    @Test func aPhoneThatIsNotPairedIsTurnedAway() async throws {
        let relay = MemoryRelay()
        let host = TestHost(relay: relay, handle: echo)
        let stranger = phone(on: relay)
        var link = host.link
        link.token = randomBytes(16)
        await #expect(throws: LinkError.refused) { try await stranger.pair(link) }

        let paired = PairedHost(address: host.secret.address, key: host.key.publicBytes, name: "", kind: .mac)
        await #expect(throws: LinkError.refused) { try await collect(stranger.send(LinkRequest(path: "api/session"), to: paired)) }
    }

    @Test func aPairedPhoneComesBackWithoutTheToken() async throws {
        let relay = MemoryRelay()
        let host = TestHost(relay: relay, handle: echo)
        let key = LinkKey(), secret = RelaySecret()
        let first = LinkClient(relay: host.link.relay, key: key, secret: secret, name: "p", app: "0", connect: relay.connect)
        let paired = try await first.pair(host.link)
        await first.disconnect()

        let later = LinkClient(relay: host.link.relay, key: key, secret: secret, name: "p", app: "0", connect: relay.connect)
        #expect(try await collect(later.send(LinkRequest(path: "api/info"), to: paired)).status == 200)
    }

    @Test func bodiesLongerThanOneMessageArriveWhole() async throws {
        let relay = MemoryRelay()
        let host = TestHost(relay: relay, handle: echo)
        let client = phone(on: relay)
        let paired = try await client.pair(host.link)
        let big = randomBytes(300_000)
        let response = try await collect(client.send(LinkRequest(method: "POST", path: "api/upload", body: big), to: paired))
        #expect(response.body == big)
    }

    @Test func aStreamStopsOnTheHostWhenThePhoneStopsReading() async throws {
        let relay = MemoryRelay()
        let stopped = AsyncStream.makeStream(of: Void.self)
        let host = TestHost(relay: relay) { request, phone in
            guard request.path == "api/event" else { return echo(request, phone) }
            return AsyncThrowingStream { continuation in
                let task = Task {
                    continuation.yield(.head(status: 200, headers: ["content-type": "text/event-stream"]))
                    var n = 0
                    while !Task.isCancelled {
                        continuation.yield(.body(Data("data: \(n)\n\n".utf8)))
                        n += 1
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    stopped.continuation.yield()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        let client = phone(on: relay)
        let paired = try await client.pair(host.link)
        var events = 0
        for try await part in client.send(LinkRequest(path: "api/event"), to: paired) {
            if case .body = part { events += 1 }
            if events == 3 { break }
        }
        #expect(events == 3)
        var iterator = stopped.stream.makeAsyncIterator()
        _ = await iterator.next()

        // The session is still good for the next request.
        #expect(try await collect(client.send(LinkRequest(path: "api/info"), to: paired)).status == 200)
    }

    @Test func aHostThatIsNotConnectedIsOffline() async throws {
        let relay = MemoryRelay()
        let client = phone(on: relay)
        let nobody = PairedHost(address: RelaySecret().address, key: LinkKey().publicBytes, name: "", kind: .machine)
        await #expect(throws: LinkError.hostOffline) { try await collect(client.send(LinkRequest(path: "api/info"), to: nobody)) }
    }

    @Test func aFailingHandlerAnswers502() async throws {
        let relay = MemoryRelay()
        struct Broken: Error {}
        let host = TestHost(relay: relay) { _, _ in AsyncThrowingStream { $0.finish(throwing: Broken()) } }
        let client = phone(on: relay)
        let paired = try await client.pair(host.link)
        #expect(try await collect(client.send(LinkRequest(path: "api/info"), to: paired)).status == 502)
    }

    @Test func urlSessionRequestsGoOverTheLink() async throws {
        let relay = MemoryRelay()
        let host = TestHost(relay: relay, handle: echo)
        let client = phone(on: relay)
        let paired = try await client.pair(host.link)
        let session = URLSession(configuration: LinkURLProtocol.configuration(client: client) { [paired] })
        let base = LinkURLProtocol.baseURL(for: paired)

        var request = URLRequest(url: base.appending(path: "api/session/abc/prompt").appending(queryItems: [URLQueryItem(name: "a", value: "b c")]))
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"text":"hi"}"#.utf8)
        request.setValue("/Users/me/project", forHTTPHeaderField: "x-opencode-directory")
        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "x-path") == "api/session/abc/prompt?a=b%20c")
        #expect(http.value(forHTTPHeaderField: "x-dir") == "/Users/me/project")
        #expect(data == Data(#"{"text":"hi"}"#.utf8))

        let (bytes, _) = try await session.bytes(for: URLRequest(url: base.appending(path: "api/event")))
        var lines = 0
        for try await _ in bytes.lines { lines += 1 }
        #expect(lines == 0)
    }

    @Test func mailOpensOnlyForItsPhone() throws {
        let host = LinkKey(), phone = LinkKey(), other = LinkKey()
        let payload = Data(#"{"t":"notify","title":"Needs you"}"#.utf8)
        let frame = try Mail.seal(payload, from: host, to: phone.publicBytes)
        #expect(try Mail.open(frame, to: phone, from: host.publicBytes) == payload)
        #expect(throws: Noise.Failure.decrypt) { try Mail.open(frame, to: other, from: host.publicBytes) }
        #expect(throws: Noise.Failure.decrypt) { try Mail.open(frame, to: phone, from: other.publicBytes) }
    }

    @Test func pairingLinksGoBothWays() throws {
        let link = PairingLink(relay: URL(string: "wss://link.example/v1")!, host: RelaySecret().address, key: LinkKey().publicBytes, name: "Sam’s MacBook & co")
        #expect(PairingLink(link.url) == link)
        #expect(PairingLink(URL(string: "kuvo-link://pair?v=2")!) == nil)
        #expect(PairingLink(URL(string: "https://pair")!) == nil)
    }

    @Test func messagesSplitToFit() throws {
        let body = randomBytes(200_000)
        let pieces = LinkMessage.pieces(.init(t: .res, id: 9, h: ["content-type": "x"], s: 200), body: body, end: true)
        #expect(pieces.count == 4)
        #expect(pieces.allSatisfy { $0.data.count <= LinkMessage.maxLength })
        #expect(pieces.first?.head.t == .res)
        #expect(pieces.dropFirst().allSatisfy { $0.head.t == .data && $0.head.id == 9 })
        #expect(pieces.map(\.head.end) == [false, false, false, true])
        #expect(pieces.reduce(Data()) { $0 + $1.body } == body)
        for piece in pieces { #expect(try LinkMessage(piece.data) == piece) }
    }
}
