import Foundation

/// A device's connection to the relay: a WebSocket, or something in memory for tests.
public protocol RelayTransport: AnyObject, Sendable {
    /// The address the relay gave this connection.
    var address: LinkAddress { get }
    /// What the relay sends, ending when the connection does.
    var messages: AsyncStream<RelayMessage> { get }
    /// Queues a message for the relay. They go out in the order queued, which keeps a session's
    /// messages in the order they were encrypted.
    func send(_ message: RelayMessage)
    func close()
}

/// The relay over a WebSocket.
public final class WebSocketRelay: RelayTransport, @unchecked Sendable {
    public let address: LinkAddress
    public let messages: AsyncStream<RelayMessage>
    private let task: URLSessionWebSocketTask
    private let outbox: AsyncStream<RelayMessage>.Continuation
    private let inbox: AsyncStream<RelayMessage>.Continuation

    /// Connects, says hello and waits for the relay's welcome.
    public static func connect(to url: URL, secret: RelaySecret) async throws -> any RelayTransport {
        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 1 << 20
        task.resume()
        do {
            try await task.send(.data(RelayMessage.hello(secret).data))
            guard case .data(let data) = try await task.receive(),
                  case .welcome(let address) = try RelayMessage(fromRelay: data), address == secret.address
            else { throw LinkError.relayUnavailable }
            return WebSocketRelay(task: task, address: address)
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            throw LinkError.relayUnavailable
        }
    }

    private init(task: URLSessionWebSocketTask, address: LinkAddress) {
        self.task = task
        self.address = address
        let (messages, inbox) = AsyncStream.makeStream(of: RelayMessage.self)
        let (outgoing, outbox) = AsyncStream.makeStream(of: RelayMessage.self)
        self.messages = messages
        self.inbox = inbox
        self.outbox = outbox

        Task { [task] in
            for await message in outgoing {
                do { try await task.send(.data(message.data)) } catch { break }
            }
        }
        Task { [task, inbox] in
            while true {
                guard case .data(let data)? = try? await task.receive() else { break }
                if let message = try? RelayMessage(fromRelay: data) { inbox.yield(message) }
            }
            inbox.finish()
            outbox.finish()
        }
        // Pings keep the connection open through routers that forget quiet ones, and notice
        // one that's gone.
        Task { [weak self, task] in
            while self != nil {
                try? await Task.sleep(for: .seconds(25))
                let answered = await withCheckedContinuation { done in
                    task.sendPing { done.resume(returning: $0 == nil) }
                }
                if !answered { task.cancel(with: .goingAway, reason: nil); break }
            }
        }
    }

    deinit { close() }

    public func send(_ message: RelayMessage) {
        outbox.yield(message)
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
        outbox.finish()
        inbox.finish()
    }
}
