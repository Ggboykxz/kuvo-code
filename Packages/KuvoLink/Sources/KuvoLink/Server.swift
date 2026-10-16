import Foundation

/// A host's side: answers the phones it's paired with, over its relay connection. The Mac app
/// runs one; machines run the same in JavaScript (`Resources/kuvo-link.js`).
public actor LinkServer {
    public struct Phone: Sendable, Hashable {
        public var key: Data
        public var name: String
        public var address: LinkAddress
    }

    /// Whether to let a phone in: its static key, and what it said (`pair` holds a pairing token).
    public typealias Authorize = @Sendable (_ key: Data, _ hello: PhoneHello) async -> Bool
    /// Answers a request, in pieces.
    public typealias Handle = @Sendable (LinkRequest, Phone) -> AsyncThrowingStream<LinkResponsePart, Error>

    let key: LinkKey
    let hello: HostHello
    let authorize: Authorize
    let handle: Handle
    private var relay: (any RelayTransport)?
    private var sessions: [SessionKey: Session] = [:]

    private struct SessionKey: Hashable {
        var address: LinkAddress
        var id: UInt32
    }

    private final class Session {
        let key: SessionKey
        let phone: Phone
        var transport: Transport
        var incoming: [Int: LinkRequest] = [:]
        var running: [Int: Task<Void, Never>] = [:]

        init(key: SessionKey, phone: Phone, transport: Transport) {
            self.key = key
            self.phone = phone
            self.transport = transport
        }
    }

    public init(key: LinkKey, hello: HostHello, authorize: @escaping Authorize, handle: @escaping Handle) {
        self.key = key
        self.hello = hello
        self.authorize = authorize
        self.handle = handle
    }

    /// Serves over `relay` until it closes. Sessions on an earlier connection end.
    public func serve(_ relay: any RelayTransport) async {
        for session in sessions.values { end(session, notify: false) }
        self.relay = relay
        for await message in relay.messages {
            guard case .deliver(let from, let payload) = message, let frame = try? LinkFrame(payload) else { continue }
            await receive(frame, from: from)
        }
        if self.relay === relay {
            self.relay = nil
            for session in sessions.values { end(session, notify: false) }
        }
    }

    /// Ends the sessions of a phone that's no longer paired.
    public func forget(phone key: Data) {
        for session in sessions.values where session.phone.key == key { end(session, notify: true) }
    }

    private func receive(_ frame: LinkFrame, from address: LinkAddress) async {
        let key = SessionKey(address: address, id: frame.session)
        switch frame.kind {
        case .handshake1:
            await handshake(frame.body, key: key)
        case .transport:
            guard let session = sessions[key] else { return send(.close, key: key) }
            guard let plaintext = try? session.transport.open(frame.body), let message = try? LinkMessage(plaintext) else {
                return end(session, notify: true)
            }
            receive(message, in: session)
        case .close:
            if let session = sessions[key] { end(session, notify: false) }
        case .handshake2, .mail:
            break
        }
    }

    private func handshake(_ message: Data, key: SessionKey) async {
        var responder = IKResponder(staticKey: self.key, prologue: Link.prologue)
        guard let payload = try? responder.readMessage1(message),
              let phoneHello = try? JSONDecoder().decode(PhoneHello.self, from: payload), phoneHello.v == Link.version,
              await authorize(responder.remoteStatic, phoneHello),
              let (reply, transport) = try? responder.writeMessage2(payload: JSONEncoder().encode(hello))
        else { return send(.close, key: key) }
        // One session per phone: a new one replaces what's left of the last.
        for old in sessions.values where old.key.address == key.address { end(old, notify: false) }
        let phone = Phone(key: responder.remoteStatic, name: phoneHello.name, address: key.address)
        sessions[key] = Session(key: key, phone: phone, transport: transport)
        send(.handshake2, key: key, body: reply)
    }

    private func receive(_ message: LinkMessage, in session: Session) {
        let head = message.head
        switch head.t {
        case .req:
            guard let id = head.id, let method = head.m, let path = head.p else { return }
            let request = LinkRequest(method: method, path: path, headers: head.h ?? [:], body: message.body)
            if head.end == false { session.incoming[id] = request } else { run(request, id: id, in: session) }
        case .data:
            guard let id = head.id, var request = session.incoming[id] else { return }
            request.body += message.body
            if head.end == true {
                session.incoming[id] = nil
                run(request, id: id, in: session)
            } else {
                session.incoming[id] = request
            }
        case .cancel:
            guard let id = head.id else { return }
            session.running.removeValue(forKey: id)?.cancel()
            session.incoming[id] = nil
        case .ping:
            seal(LinkMessage(.init(t: .pong)), in: session)
        case .res, .pong:
            break
        }
    }

    private func run(_ request: LinkRequest, id: Int, in session: Session) {
        let stream = handle(request, session.phone)
        session.running[id] = Task {
            var head: LinkMessage.Head?
            do {
                for try await part in stream {
                    switch part {
                    case .head(let status, let headers):
                        head = .init(t: .res, id: id, h: headers, s: status)
                    case .body(let data):
                        // The head goes with the first piece of the body.
                        let first = head ?? .init(t: .data, id: id)
                        head = .init(t: .data, id: id)
                        self.reply(first, body: data, id: id, end: false, in: session)
                    }
                }
                self.reply(head ?? .init(t: .data, id: id), body: Data(), id: id, end: true, in: session)
            } catch {
                if head == nil || head?.t == .res {
                    let failed = LinkMessage.Head(t: .res, id: id, h: ["content-type": "text/plain"], s: 502)
                    self.reply(failed, body: Data(String(describing: error).utf8), id: id, end: true, in: session)
                } else {
                    self.reply(.init(t: .cancel, id: id), body: Data(), id: id, end: nil, in: session)
                }
            }
        }
    }

    private func reply(_ head: LinkMessage.Head, body: Data, id: Int, end: Bool?, in session: Session) {
        // A cancelled request says nothing more.
        guard session.running[id] != nil, sessions[session.key] === session else { return }
        if head.t == .cancel {
            seal(LinkMessage(head), in: session)
        } else {
            for piece in LinkMessage.pieces(head, body: body, end: end ?? false) { seal(piece, in: session) }
        }
        if end != false { session.running[id] = nil }
    }

    private func seal(_ message: LinkMessage, in session: Session) {
        guard let ciphertext = try? session.transport.seal(message.data) else { return end(session, notify: true) }
        send(.transport, key: session.key, body: ciphertext)
    }

    private func end(_ session: Session, notify: Bool) {
        guard sessions[session.key] === session else { return }
        sessions[session.key] = nil
        for task in session.running.values { task.cancel() }
        session.running = [:]
        if notify { send(.close, key: session.key) }
    }

    private func send(_ kind: LinkFrame.Kind, key: SessionKey, body: Data = Data()) {
        relay?.send(.send(to: key.address, payload: LinkFrame(kind, session: key.id, body: body).data))
    }
}
