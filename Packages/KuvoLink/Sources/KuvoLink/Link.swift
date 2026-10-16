import CryptoKit
import Foundation

public enum Link {
    public static let version = 1
    static let prologue = Data("kuvo-link v1".utf8)
    static let mailPrologue = Data("kuvo-link mail v1".utf8)
    /// How long a handshake may take before the host counts as unreachable.
    static let handshakeTimeout: Duration = .seconds(15)
}

public enum LinkError: Error, Equatable, LocalizedError {
    /// The relay has nothing connected at the host's address.
    case hostOffline
    /// The host turned the phone away: not paired, or a pairing link that's used up.
    case refused
    /// The session ended while a request was under way.
    case closed
    case relayUnavailable
    case unsupportedVersion
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .hostOffline: "It isn’t connected right now."
        case .refused: "It turned this phone away. Pair again."
        case .closed: "The connection closed."
        case .relayUnavailable: "Couldn’t reach the relay."
        case .unsupportedVersion: "It runs a version this app doesn’t know. Update both."
        case .timedOut: "It didn’t answer."
        }
    }
}

/// A host the phone is paired with.
public struct PairedHost: Codable, Hashable, Sendable {
    public var address: String
    public var key: Data
    public var name: String
    public var kind: HostHello.Kind

    public init(address: LinkAddress, key: Data, name: String, kind: HostHello.Kind) {
        self.address = address.text
        self.key = key
        self.name = name
        self.kind = kind
    }

    public var linkAddress: LinkAddress { LinkAddress(text: address)! }
}

/// A request to a host, like an HTTP one.
public struct LinkRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String = "GET", path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

/// A response, as it arrives: its status and headers once, then its body in pieces.
public enum LinkResponsePart: Sendable, Equatable {
    case head(status: Int, headers: [String: String])
    case body(Data)
}

/// Pushes and other messages for a device that may not be connected (PROTOCOL.md, "Mail").
public enum Mail {
    /// A mail frame, for the relay's `push`.
    public static func seal(_ payload: Data, from key: LinkKey, to remoteStatic: Data) throws -> Data {
        LinkFrame(.mail, session: 0, body: try OneWay.seal(payload, from: key, to: remoteStatic, prologue: Link.mailPrologue).message).data
    }

    public static func open(_ frame: Data, to key: LinkKey, from remoteStatic: Data) throws -> Data {
        let frame = try LinkFrame(frame)
        guard frame.kind == .mail else { throw FrameError.malformed }
        return try OneWay.open(frame.body, to: key, from: remoteStatic, prologue: Link.mailPrologue).payload
    }
}

/// The phone's side: sessions with the hosts it's paired with, over one relay connection.
public actor LinkClient {
    public typealias Connect = @Sendable (URL, RelaySecret) async throws -> any RelayTransport

    public nonisolated let relayURL: URL
    let key: LinkKey
    let secret: RelaySecret
    let hello: PhoneHello
    let connect: Connect

    private var relay: (any RelayTransport)?
    private var connecting: Task<any RelayTransport, Error>?
    private var sessions: [LinkAddress: Session] = [:]

    private final class Session {
        let id = UInt32.random(in: 1...UInt32.max)
        var host: PairedHost
        var initiator: IKInitiator?
        var transport: Transport?
        var hostHello: HostHello?
        var waiting: [CheckedContinuation<Void, Error>] = []
        var nextID = 1
        var streams: [Int: AsyncThrowingStream<LinkResponsePart, Error>.Continuation] = [:]

        init(host: PairedHost) { self.host = host }
    }

    public init(relay: URL, key: LinkKey, secret: RelaySecret, name: String, app: String, connect: @escaping Connect = WebSocketRelay.connect) {
        relayURL = relay
        self.key = key
        self.secret = secret
        hello = PhoneHello(name: name, app: app)
        self.connect = connect
    }

    /// Pairs with the host a pairing link names. Returns it, to keep.
    public func pair(_ link: PairingLink) async throws -> PairedHost {
        let address = link.host
        if let old = sessions[address] { end(old, with: .closed) }
        var host = PairedHost(address: address, key: link.key, name: link.name, kind: .mac)
        let hostHello = try await open(host, pairing: link.token)
        host.name = hostHello.name
        host.kind = hostHello.kind
        sessions[address]?.host = host
        return host
    }

    /// What the host says it is, opening a session if there's none.
    public func hostHello(_ host: PairedHost) async throws -> HostHello {
        try await open(host, pairing: nil)
    }

    /// Sends `request` to `host`; the response arrives in pieces. Stopping early (leaving the loop,
    /// or cancelling the task that reads) cancels the request on the host.
    public nonisolated func send(_ request: LinkRequest, to host: PairedHost) -> LinkResponse {
        let ticket = Ticket()
        let stop: @Sendable () -> Void = { Task { await self.cancel(ticket, on: host) } }
        let stream = AsyncThrowingStream<LinkResponsePart, Error> { continuation in
            let task = Task { await self.start(request, to: host, ticket: ticket, continuation: continuation) }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                task.cancel()
                stop()
            }
        }
        return LinkResponse(stream: stream, stop: stop)
    }

    #if DEBUG
    /// The relay connection gone, as a phone put to sleep loses it: no close sent to anyone.
    func dropRelayForTesting() {
        relay?.close()
    }
    #endif

    /// Ends every session and the relay connection.
    public func disconnect() {
        for session in sessions.values { end(session, with: .closed) }
        relay?.close()
        relay = nil
    }

    // MARK: Sessions

    @discardableResult
    private func open(_ host: PairedHost, pairing token: Data?) async throws -> HostHello {
        let address = host.linkAddress
        if let session = sessions[address] {
            if let hello = session.hostHello { return hello }
            try await withCheckedThrowingContinuation { session.waiting.append($0) }
            return session.hostHello!
        }
        let session = Session(host: host)
        sessions[address] = session
        do {
            let relay = try await relayConnection()
            // Ended while connecting (a pairing started over, the relay dropped): nothing will answer it.
            guard sessions[address] === session else { throw LinkError.closed }
            var initiator = IKInitiator(staticKey: key, remoteStatic: host.key, prologue: Link.prologue)
            var hello = self.hello
            hello.pair = token?.base64URL
            let message = try initiator.writeMessage1(payload: JSONEncoder().encode(hello))
            session.initiator = initiator
            relay.send(.send(to: address, payload: LinkFrame(.handshake1, session: session.id, body: message).data))
            Task {
                try? await Task.sleep(for: Link.handshakeTimeout)
                self.timeOut(session)
            }
            try await withCheckedThrowingContinuation { session.waiting.append($0) }
            return session.hostHello!
        } catch {
            end(session, with: (error as? LinkError) ?? .relayUnavailable)
            throw error
        }
    }

    /// No answer in time: whoever waits on it hears so, whether or not it's still the current one.
    private func timeOut(_ session: Session) {
        if session.transport == nil { end(session, with: .timedOut) }
    }

    private func end(_ session: Session, with error: LinkError) {
        let address = session.host.linkAddress
        if sessions[address] === session { sessions[address] = nil }
        for waiter in session.waiting { waiter.resume(throwing: error) }
        session.waiting = []
        for stream in session.streams.values { stream.finish(throwing: error) }
        session.streams = [:]
        if session.transport != nil { relay?.send(.send(to: address, payload: LinkFrame(.close, session: session.id).data)) }
        session.transport = nil
    }

    private func start(_ request: LinkRequest, to host: PairedHost, ticket: Ticket, continuation: AsyncThrowingStream<LinkResponsePart, Error>.Continuation) async {
        do {
            try await open(host, pairing: nil)
            guard let session = sessions[host.linkAddress], session.transport != nil else { throw LinkError.closed }
            try Task.checkCancellation()
            let id = session.nextID
            session.nextID += 1
            ticket.set(id: id, session: session.id)
            session.streams[id] = continuation
            let head = LinkMessage.Head(t: .req, id: id, m: request.method, p: request.path, h: request.headers)
            for piece in LinkMessage.pieces(head, body: request.body, end: true) {
                try seal(piece, in: session)
            }
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func cancel(_ ticket: Ticket, on host: PairedHost) {
        guard let (id, sessionID) = ticket.value, let session = sessions[host.linkAddress], session.id == sessionID,
              session.streams.removeValue(forKey: id) != nil
        else { return }
        try? seal(LinkMessage(.init(t: .cancel, id: id)), in: session)
    }

    private func seal(_ message: LinkMessage, in session: Session) throws {
        guard var transport = session.transport, let relay else { throw LinkError.closed }
        let ciphertext = try transport.seal(message.data)
        session.transport = transport
        relay.send(.send(to: session.host.linkAddress, payload: LinkFrame(.transport, session: session.id, body: ciphertext).data))
    }

    // MARK: The relay

    private func relayConnection() async throws -> any RelayTransport {
        if let relay { return relay }
        if let connecting { return try await connecting.value }
        let (connect, url, secret) = (connect, relayURL, secret)
        let task = Task { try await connect(url, secret) }
        connecting = task
        defer { connecting = nil }
        do {
            let relay = try await task.value
            self.relay = relay
            Task { [weak self] in
                for await message in relay.messages { await self?.receive(message) }
                await self?.relayEnded(relay)
            }
            return relay
        } catch {
            throw LinkError.relayUnavailable
        }
    }

    private func relayEnded(_ ended: any RelayTransport) {
        guard relay === ended else { return }
        relay = nil
        // A host can't tell a session's frames went missing, so start again.
        for session in sessions.values { end(session, with: .closed) }
    }

    private func receive(_ message: RelayMessage) {
        switch message {
        case .deliver(let from, let payload):
            guard let frame = try? LinkFrame(payload), let session = sessions[from], session.id == frame.session else { return }
            receive(frame, in: session)
        case .unreachable(let address):
            if let session = sessions[address] { end(session, with: .hostOffline) }
        default:
            break
        }
    }

    private func receive(_ frame: LinkFrame, in session: Session) {
        switch frame.kind {
        case .handshake2:
            guard var initiator = session.initiator, session.transport == nil else { return }
            do {
                let (payload, transport) = try initiator.readMessage2(frame.body)
                let hello = try JSONDecoder().decode(HostHello.self, from: payload)
                session.initiator = nil
                session.transport = transport
                guard hello.v == Link.version else { return end(session, with: .unsupportedVersion) }
                session.hostHello = hello
                for waiter in session.waiting { waiter.resume() }
                session.waiting = []
            } catch {
                end(session, with: .refused)
            }
        case .transport:
            guard var transport = session.transport else { return }
            guard let plaintext = try? transport.open(frame.body), let message = try? LinkMessage(plaintext) else {
                return end(session, with: .closed)
            }
            session.transport = transport
            receive(message, in: session)
        case .close:
            end(session, with: session.transport == nil ? .refused : .closed)
        case .handshake1, .mail:
            break
        }
    }

    private func receive(_ message: LinkMessage, in session: Session) {
        let head = message.head
        switch head.t {
        case .res, .data:
            guard let id = head.id, let stream = session.streams[id] else { return }
            if head.t == .res { stream.yield(.head(status: head.s ?? 502, headers: head.h ?? [:])) }
            if !message.body.isEmpty { stream.yield(.body(message.body)) }
            if head.end == true {
                session.streams[id] = nil
                stream.finish()
            }
        case .cancel:
            guard let id = head.id, let stream = session.streams.removeValue(forKey: id) else { return }
            stream.finish(throwing: LinkError.closed)
        case .ping:
            try? seal(LinkMessage(.init(t: .pong)), in: session)
        case .req, .pong:
            break
        }
    }
}

/// A response's pieces as they arrive. The session holds on to the stream while the host may
/// still send, so leaving the loop early has to say so: the iterator does when it goes.
public struct LinkResponse: AsyncSequence, Sendable {
    public typealias Element = LinkResponsePart

    let stream: AsyncThrowingStream<LinkResponsePart, Error>
    let stop: @Sendable () -> Void

    public func makeAsyncIterator() -> Iterator {
        Iterator(base: stream.makeAsyncIterator(), stopper: Stopper(stop))
    }

    public struct Iterator: AsyncIteratorProtocol {
        var base: AsyncThrowingStream<LinkResponsePart, Error>.Iterator
        let stopper: Stopper

        public mutating func next() async throws -> LinkResponsePart? {
            try await base.next()
        }
    }

    final class Stopper {
        let stop: @Sendable () -> Void
        init(_ stop: @escaping @Sendable () -> Void) { self.stop = stop }
        // Cancelling a request that already ended does nothing.
        deinit { stop() }
    }
}

/// Which request a stream became, for cancelling it.
private final class Ticket: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (Int, UInt32)?

    func set(id: Int, session: UInt32) { lock.withLock { stored = (id, session) } }
    var value: (Int, UInt32)? { lock.withLock { stored } }
}

/// The machines' side of the link (`Resources/kuvo-link.js`): the script the Mac app puts in a
/// machine's `~/.kuvo-code/bin` and the engine's runtime runs.
public enum Bridge {
    public static let fileName = "kuvo-link.js"

    public static var script: Data {
        get throws { try Data(contentsOf: Bundle.module.url(forResource: "kuvo-link", withExtension: "js")!) }
    }
}
