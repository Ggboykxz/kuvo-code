import Foundation

/// The opencode v2 HTTP API, the parts the app uses.
///
/// Calls that take a `directory` are scoped to that project folder (sent as the
/// `x-opencode-directory` header). Session calls are scoped by the session itself.
public struct OpenCodeAPI: Sendable {
    public let client: HTTPClient

    public init(endpoint: ServerEndpoint, session: URLSession = .shared) {
        client = HTTPClient(endpoint: endpoint, session: session)
    }

    public var events: EventStream { EventStream(client: client) }

    // MARK: Server

    public func info() async throws -> ServerInfo {
        try await get("api/info")
    }

    // MARK: Catalog

    public func integrations(directory: String? = nil) async throws -> [Integration] {
        try await get("api/integration", directory: directory, as: LocatedEnvelope<[Integration]>.self).data
    }

    public func integration(_ id: String, directory: String? = nil) async throws -> Integration {
        try await get("api/integration/\(id.pathEscaped)", directory: directory, as: LocatedEnvelope<Integration>.self).data
    }

    public func providers(directory: String? = nil) async throws -> [Provider] {
        try await get("api/provider", directory: directory, as: LocatedEnvelope<[Provider]>.self).data
    }

    public func models(directory: String? = nil) async throws -> [Model] {
        try await get("api/model", directory: directory, as: LocatedEnvelope<[Model]>.self).data
    }

    public func defaultModel(directory: String? = nil) async throws -> Model? {
        try await get("api/model/default", directory: directory, as: LocatedEnvelope<Model?>.self).data
    }

    public func agents(directory: String? = nil) async throws -> [Agent] {
        try await get("api/agent", directory: directory, as: LocatedEnvelope<[Agent]>.self).data
    }

    public func commands(directory: String? = nil) async throws -> [Command] {
        try await get("api/command", directory: directory, as: LocatedEnvelope<[Command]>.self).data
    }

    /// The project's version control state: today, its current git branch.
    public func vcs(directory: String) async throws -> VCSInfo {
        try await get("api/vcs", directory: directory, as: LocatedEnvelope<VCSInfo>.self).data
    }

    // MARK: Connecting providers

    public func connectKey(integration: String, key: String, answer: FormAnswer? = nil, directory: String? = nil) async throws {
        struct Body: Encodable { var key: String; var answer: FormAnswer? }
        try await send("POST", "api/integration/\(integration.pathEscaped)/connect/key", directory: directory, body: Body(key: key, answer: answer))
    }

    public func connectExternal(integration: String, method: String, answer: FormAnswer? = nil, directory: String? = nil) async throws {
        struct Body: Encodable { var methodID: String; var answer: FormAnswer? }
        try await send("POST", "api/integration/\(integration.pathEscaped)/connect/external", directory: directory, body: Body(methodID: method, answer: answer))
    }

    public func startOAuth(integration: String, method: String, answer: FormAnswer? = nil, directory: String? = nil) async throws -> OAuthAttempt {
        struct Body: Encodable { var methodID: String; var answer: FormAnswer? }
        return try await send("POST", "api/integration/\(integration.pathEscaped)/connect/oauth", directory: directory,
                              body: Body(methodID: method, answer: answer), as: LocatedEnvelope<OAuthAttempt>.self).data
    }

    public func oauthStatus(integration: String, attempt: String, directory: String? = nil) async throws -> OAuthStatus {
        try await get("api/integration/\(integration.pathEscaped)/connect/oauth/\(attempt.pathEscaped)", directory: directory, as: LocatedEnvelope<OAuthStatus>.self).data
    }

    /// For `mode == .code` sign-ins only: hands the pasted code to the engine.
    public func completeOAuth(integration: String, attempt: String, code: String, directory: String? = nil) async throws {
        struct Body: Encodable { var code: String }
        try await send("POST", "api/integration/\(integration.pathEscaped)/connect/oauth/\(attempt.pathEscaped)/complete", directory: directory, body: Body(code: code))
    }

    public func cancelOAuth(integration: String, attempt: String, directory: String? = nil) async throws {
        try await send("DELETE", "api/integration/\(integration.pathEscaped)/connect/oauth/\(attempt.pathEscaped)", directory: directory)
    }

    public func credentials() async throws -> [Credential] {
        try await get("api/credential", as: DataEnvelope<[Credential]>.self).data
    }

    /// Stored sign-ins with their secrets, for asking providers about usage.
    /// Keep the result in memory only.
    public func credentialSecrets() async throws -> [CredentialSecret] {
        try await get("api/credential", as: DataEnvelope<[CredentialSecret]>.self).data
    }

    public func activateCredential(_ id: String) async throws {
        try await send("POST", "api/credential/\(id.pathEscaped)/activate")
    }

    public func removeCredential(_ id: String) async throws {
        try await send("DELETE", "api/credential/\(id.pathEscaped)")
    }

    // MARK: Sessions

    public func sessions(directory: String? = nil, roots: Bool = true, limit: Int = 100) async throws -> Page<Session> {
        var query: [String: String?] = ["limit": String(limit), "order": "desc"]
        if roots { query["parentID"] = "null" }
        if let directory { query["directory"] = directory }
        return try await get("api/session", query: query)
    }

    public func session(_ id: String) async throws -> Session {
        try await get("api/session/\(id.pathEscaped)", as: DataEnvelope<Session>.self).data
    }

    /// Sessions that are running right now.
    public func activeSessions() async throws -> Set<String> {
        let active = try await get("api/session/active", as: DataEnvelope<[String: JSONValue]>.self).data
        return Set(active.keys)
    }

    public func createSession(directory: String, title: String? = nil, agent: String? = nil, model: ModelRef? = nil, permissions: [PermissionRule]? = nil) async throws -> Session {
        struct Body: Encodable { var title: String?; var agent: String?; var model: ModelRef?; var location: Location; var permissions: [PermissionRule]? }
        let body = Body(title: title, agent: agent, model: model, location: Location(directory: directory), permissions: permissions)
        return try await send("POST", "api/session", body: body, as: DataEnvelope<Session>.self).data
    }

    public func renameSession(_ id: String, title: String) async throws {
        struct Body: Encodable { var title: String }
        try await send("PATCH", "api/session/\(id.pathEscaped)", body: Body(title: title))
    }

    /// Replaces the session's own permission rules (the agent's still apply underneath).
    public func setPermissions(session id: String, rules: [PermissionRule]) async throws {
        struct Body: Encodable { var permissions: [PermissionRule] }
        try await send("PATCH", "api/session/\(id.pathEscaped)", body: Body(permissions: rules))
    }

    /// Attaches (or replaces) an instruction for the session's agent under `key` (lowercase
    /// letters, digits, `.`, `_` and `-`). The agent hears about the change at its next step.
    public func setInstruction(session id: String, key: String, text: String) async throws {
        struct Body: Encodable { var value: String }
        try await send("PUT", "api/experimental/session/\(id.pathEscaped)/instructions/entries/\(key.pathEscaped)", body: Body(value: text))
    }

    public func removeInstruction(session id: String, key: String) async throws {
        try await send("DELETE", "api/experimental/session/\(id.pathEscaped)/instructions/entries/\(key.pathEscaped)")
    }

    public func deleteSession(_ id: String) async throws {
        try await send("DELETE", "api/session/\(id.pathEscaped)")
    }

    /// Marks the session read up to its last run.
    public func markViewed(_ id: String, idle: Milliseconds) async throws {
        struct Body: Encodable { var idle: Milliseconds }
        try await send("POST", "api/session/\(id.pathEscaped)/view", body: Body(idle: idle))
    }

    /// The newest messages, oldest first.
    public func messages(session: String, limit: Int = 100, before cursor: String? = nil) async throws -> Page<Message> {
        var query: [String: String?] = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor } else { query["order"] = "desc" }
        var page: Page<Message> = try await get("api/session/\(session.pathEscaped)/message", query: query)
        page.data.reverse()
        return page
    }

    public func inbox(session: String) async throws -> [InboxItem] {
        try await get("api/session/\(session.pathEscaped)/inbox", as: DataEnvelope<[InboxItem]>.self).data
    }

    public func diff(session: String) async throws -> [FileDiff] {
        try await get("api/session/\(session.pathEscaped)/diff", as: DataEnvelope<[FileDiff]>.self).data
    }

    // MARK: Running

    public struct PromptFile: Encodable, Sendable {
        public var uri: String
        public var name: String?

        public init(uri: String, name: String? = nil) {
            self.uri = uri
            self.name = name
        }
    }

    /// Sends a message. Returns as soon as it's queued; the reply arrives as events.
    public func prompt(session: String, id: String, text: String, files: [PromptFile] = [], delivery: InboxItem.Delivery = .steer) async throws {
        struct Body: Encodable { var id: String; var text: String; var files: [PromptFile]?; var delivery: InboxItem.Delivery }
        let body = Body(id: id, text: text, files: files.isEmpty ? nil : files, delivery: delivery)
        try await send("POST", "api/session/\(session.pathEscaped)/prompt", body: body, as: Empty.self)
    }

    public func runCommand(session: String, name: String, arguments: String) async throws {
        struct Body: Encodable { var name: String; var text: String }
        try await send("POST", "api/session/\(session.pathEscaped)/command", body: Body(name: name, text: arguments))
    }

    public func selectAgent(session: String, agent: String) async throws {
        struct Body: Encodable { var agent: String }
        try await send("POST", "api/session/\(session.pathEscaped)/agent", body: Body(agent: agent))
    }

    public func selectModel(session: String, model: ModelRef) async throws {
        struct Body: Encodable { var model: ModelRef }
        try await send("POST", "api/session/\(session.pathEscaped)/model", body: Body(model: model))
    }

    /// Stops the current run. With `resume`, the agent goes straight on with the input waiting
    /// to steer it, so that input goes in now instead of at the next step.
    public func interrupt(session: String, resume: Bool = false) async throws {
        struct Response: Decodable { var interrupted: Bool }
        try await send("POST", "api/session/\(session.pathEscaped)/interrupt", query: ["resume": resume ? "true" : nil], as: Response.self)
    }

    /// Removes waiting input before the agent gets it. Input already delivered is left alone.
    /// Summarizes the conversation so far to free up the context window: right away when
    /// idle, otherwise at the agent's next step.
    public func compact(session: String) async throws {
        struct Body: Encodable {}
        try await send("POST", "api/session/\(session.pathEscaped)/compact", body: Body(), as: JSONValue.self)
    }

    /// Waits for the session's run to wind down after an interrupt.
    public func wait(session: String) async throws {
        try await send("POST", "api/experimental/session/\(session.pathEscaped)/wait")
    }

    /// Takes the conversation back to before `messageID`, and the files the agent changed
    /// since. Until the next message (which makes it final), `clearRevert` brings it all back.
    public func stageRevert(session: String, messageID: String) async throws -> Session.Revert {
        struct Body: Encodable { var messageID: String }
        return try await send("POST", "api/session/\(session.pathEscaped)/revert/stage", body: Body(messageID: messageID), as: DataEnvelope<Session.Revert>.self).data
    }

    public func clearRevert(session: String) async throws {
        try await send("DELETE", "api/session/\(session.pathEscaped)/revert")
    }

    public func cancelInbox(session: String, item: String) async throws {
        try await send("DELETE", "api/session/\(session.pathEscaped)/inbox/\(item.pathEscaped)")
    }

    /// Moves waiting input between the next step (`steer`, which also wakes an idle session)
    /// and after the run (`queue`).
    public func setDelivery(session: String, item: String, delivery: InboxItem.Delivery) async throws {
        struct Body: Encodable { var delivery: InboxItem.Delivery }
        try await send("PATCH", "api/session/\(session.pathEscaped)/inbox/\(item.pathEscaped)", body: Body(delivery: delivery))
    }

    // MARK: Permissions and questions

    public func permissions(session: String) async throws -> [PermissionRequest] {
        try await get("api/session/\(session.pathEscaped)/permission", as: DataEnvelope<[PermissionRequest]>.self).data
    }

    public func reply(session: String, permission: String, decision: PermissionRequest.Decision, message: String? = nil) async throws {
        struct Body: Encodable { var decision: PermissionRequest.Decision; var message: String? }
        try await send("POST", "api/session/\(session.pathEscaped)/permission/\(permission.pathEscaped)/reply", body: Body(decision: decision, message: message))
    }

    public func forms(session: String) async throws -> [FormRequest] {
        try await get("api/session/\(session.pathEscaped)/form", as: DataEnvelope<[FormRequest]>.self).data
    }

    public func reply(session: String, form: String, answer: FormAnswer) async throws {
        struct Body: Encodable { var answer: FormAnswer }
        try await send("POST", "api/session/\(session.pathEscaped)/form/\(form.pathEscaped)/reply", body: Body(answer: answer))
    }

    /// Declines a question. With a message, the agent reads it as feedback.
    public func dismiss(session: String, form: String, message: String? = nil) async throws {
        try await send("DELETE", "api/session/\(session.pathEscaped)/form/\(form.pathEscaped)", query: ["message": message])
    }

    // MARK: Plumbing

    private func get<Response: Decodable>(_ path: String, query: [String: String?] = [:], directory: String? = nil, as type: Response.Type = Response.self) async throws -> Response {
        try await client.send(request("GET", path, query: query, directory: directory, body: Empty?.none), as: type)
    }

    @discardableResult
    private func send<Response: Decodable>(_ method: String, _ path: String, query: [String: String?] = [:], directory: String? = nil, body: (some Encodable)? = Empty?.none, as type: Response.Type = Empty.self) async throws -> Response {
        try await client.send(request(method, path, query: query, directory: directory, body: body), as: type)
    }

    private func request(_ method: String, _ path: String, query: [String: String?], directory: String?, body: (some Encodable)?) throws -> URLRequest {
        var request = try client.request(method, path, query: query, body: body)
        if let directory {
            request.setValue(directory.addingPercentEncoding(withAllowedCharacters: .uriComponentAllowed), forHTTPHeaderField: "x-opencode-directory")
        }
        return request
    }
}

extension CharacterSet {
    /// What JavaScript's `encodeURIComponent` leaves alone.
    static let uriComponentAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
}

extension String {
    var pathEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .uriComponentAllowed) ?? self
    }
}
