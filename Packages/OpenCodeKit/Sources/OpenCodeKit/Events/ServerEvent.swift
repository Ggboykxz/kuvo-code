import Foundation

/// One event from `GET /api/event`. Only the envelope is decoded up front;
/// `payload(as:)` decodes `data` into whatever shape the event's type has.
public struct ServerEvent: Sendable, Identifiable {
    public var id: String
    public var type: String
    public var created: Milliseconds?
    public var location: Location?
    /// The `data` object's `sessionID`, for the many events that have one.
    public var sessionID: String?
    /// The event as it came, JSON.
    public let raw: Data

    private struct Head: Decodable {
        var id: String
        var type: String
        var created: Milliseconds?
        var location: Location?
        var data: SessionRef?

        struct SessionRef: Decodable { var sessionID: String? }
    }

    private struct Envelope<Payload: Decodable>: Decodable {
        var data: Payload
    }

    public init(json: Data) throws {
        let head = try HTTPClient.decoder.decode(Head.self, from: json)
        id = head.id
        type = head.type
        created = head.created
        location = head.location
        sessionID = head.data?.sessionID
        raw = json
    }

    public func payload<Payload: Decodable>(as type: Payload.Type = Payload.self) throws -> Payload {
        try HTTPClient.decoder.decode(Envelope<Payload>.self, from: raw).data
    }

    /// The whole `data` object, for events the app doesn't model.
    public var data: JSONValue? {
        try? payload(as: JSONValue.self)
    }
}

/// Payloads of the events the app reacts to.
public enum EventPayload {
    public struct Step: Decodable, Sendable {
        public var assistantMessageID: String
        public var agent: String?
        public var model: ModelRef?
        public var started: Milliseconds?
        public var finish: String?
        public var cost: Double?
        public var tokens: TokenUsage?
        public var error: StructuredError?
    }

    public struct Delta: Decodable, Sendable {
        public var assistantMessageID: String
        public var ordinal: Int?
        public var delta: String
    }

    public struct BlockEnded: Decodable, Sendable {
        public var assistantMessageID: String
        public var text: String
    }

    public struct BlockStarted: Decodable, Sendable {
        public var assistantMessageID: String
    }

    public struct ToolInputStarted: Decodable, Sendable {
        public var assistantMessageID: String
        public var id: String
        public var name: String
    }

    public struct ToolInputDelta: Decodable, Sendable {
        public var assistantMessageID: String
        public var id: String
        public var delta: String
    }

    public struct ToolInputEnded: Decodable, Sendable {
        public var assistantMessageID: String
        public var id: String
        public var text: String
    }

    public struct ToolCalled: Decodable, Sendable {
        public var assistantMessageID: String
        public var id: String
        public var input: JSONValue
    }

    public struct ToolProgress: Decodable, Sendable {
        public var assistantMessageID: String
        public var id: String
        public var metadata: JSONValue
    }

    public struct ToolSucceeded: Decodable, Sendable {
        public var assistantMessageID: String
        public var id: String
        public var content: [Message.ToolOutput]
        public var metadata: JSONValue?
    }

    public struct ToolFailed: Decodable, Sendable {
        public var assistantMessageID: String
        public var id: String
        public var error: StructuredError
        public var content: [Message.ToolOutput]?
        public var metadata: JSONValue?
    }

    public struct Retry: Decodable, Sendable {
        public var assistantMessageID: String
        public var attempt: Int
        public var at: Milliseconds
        public var error: StructuredError
    }

    public struct InboxEnqueued: Decodable, Sendable {
        public var inboxID: String
        public var item: Item

        public struct Item: Decodable, Sendable {
            public var type: String
            public var payload: JSONValue
            public var delivery: InboxItem.Delivery
        }
    }

    public struct InboxChanged: Decodable, Sendable {
        public var inboxID: String
    }

    public struct ExecutionEnded: Decodable, Sendable {
        public var error: StructuredError?
        public var reason: String?
    }

    public struct Usage: Decodable, Sendable {
        public var cost: Double
        public var tokens: TokenUsage
    }

    public struct Renamed: Decodable, Sendable {
        public var title: String
    }

    public struct AgentSelected: Decodable, Sendable {
        public var agent: String
        public var previous: String?
    }

    public struct ModelSelected: Decodable, Sendable {
        public var model: ModelRef
        public var previous: ModelRef?
    }

    public struct PermissionReplied: Decodable, Sendable {
        public var sessionID: String
        public var requestID: String
    }

    public struct FormCreated: Decodable, Sendable {
        public var form: FormRequest
    }

    public struct FormSettled: Decodable, Sendable {
        public var id: String
        public var sessionID: String
    }

    public struct RevertCommitted: Decodable, Sendable {
        public var to: String
    }
}
