import Foundation
import Network

/// The panel's browser, offered to the agent as MCP tools (Streamable HTTP, JSON
/// responses) on 127.0.0.1. The engine is told about it at launch, with a token that
/// changes every time, so any model it runs can browse in the panel.
@MainActor
final class BrowserToolServer {
    private let agent: BrowserAgent
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private let token = UUID().uuidString + UUID().uuidString
    private(set) var url: URL?

    init(agent: BrowserAgent) {
        self.agent = agent
    }

    /// The engine's config entry for this server, as `OPENCODE_CONFIG_CONTENT` takes it.
    var engineConfig: [String: Any]? {
        url.map { engineConfig(at: $0) }
    }

    private func engineConfig(at url: URL) -> [String: Any] {
        ["mcp": ["servers": ["kuvo-browser": [
            "type": "remote",
            "url": url.absoluteString,
            "headers": ["Authorization": "Bearer \(token)"],
            "oauth": false,
            // Plain tools, so every model calls them directly.
            "codemode": false,
            // A tool that asks you (to sign in, for a code) waits for you.
            "timeout": ["execution": BrowserTools.executionTimeout],
        ] as [String: Any]]]]
    }

    /// Starts listening on a free loopback port and returns the address.
    func start() async throws -> URL {
        if let url { return url }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                MainActor.assumeIsolated {
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    case .failed(let error):
                        resumed = true
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
        }
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        self.url = url
        return url
    }

    private func accept(_ connection: NWConnection) {
        let http = HTTPConnection(connection: connection) { [weak self] request in
            await self?.respond(to: request) ?? .init(status: 503)
        } closed: { [weak self] id in
            self?.connections[id] = nil
        }
        connections[ObjectIdentifier(http)] = http
        http.start()
    }

    // MARK: HTTP

    private func respond(to request: HTTPRequest) async -> HTTPResponse {
        guard request.path.hasPrefix("/mcp") else { return .init(status: 404) }
        guard let authorization = request.headers["authorization"], authorization.hasPrefix("Bearer "),
              String(authorization.dropFirst(7)) == token else { return .init(status: 401) }
        switch request.method {
        case "POST": break
        case "DELETE": return .init(status: 200)
        default: return .init(status: 405, headers: ["Allow": "POST, DELETE"])
        }
        guard let body = try? JSONSerialization.jsonObject(with: request.body) else {
            return .json(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        if let batch = body as? [[String: Any]] {
            var replies: [[String: Any]] = []
            for message in batch { if let reply = await handle(message) { replies.append(reply) } }
            return replies.isEmpty ? .init(status: 202) : .json(replies)
        }
        guard let message = body as? [String: Any] else { return .init(status: 400) }
        guard let reply = await handle(message) else { return .init(status: 202) }
        var response = HTTPResponse.json(reply)
        if message["method"] as? String == "initialize" { response.headers["Mcp-Session-Id"] = UUID().uuidString }
        return response
    }

    // MARK: JSON-RPC

    /// The reply to one message, or nil for a notification.
    private func handle(_ message: [String: Any]) async -> [String: Any]? {
        guard let method = message["method"] as? String else { return nil }
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        func reply(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let supported = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
            return reply([
                "protocolVersion": requested.flatMap { supported.contains($0) ? $0 : nil } ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "kuvo-browser", "title": "Kuvo Code browser", "version": AppInfo.version],
                "instructions": BrowserTools.instructions(machine: false),
            ])
        case "ping":
            return reply([:])
        case "tools/list":
            return reply(["tools": BrowserTools.definitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return reply(await BrowserTools.call(name, arguments: arguments, agent: agent))
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unknown method \(method)"]]
        }
    }
}

// MARK: - Tools

/// The browser tools: names, descriptions and input schemas for the model, and what each does.
@MainActor
enum BrowserTools {
    static let definitions: [[String: Any]] = [
        tool("browser_navigate", "Open a web address (or search for words) in the browser panel the user sees. Returns the page as numbered elements.",
             ["url": ["type": "string", "description": "An address like example.com, or words to search for."]], required: ["url"]),
        tool("browser_snapshot", "Read the current page: title, address, scroll position, and its interactive elements numbered like [3], with visible text."),
        tool("browser_click", "Click the element with this number from the latest snapshot.",
             ["index": ["type": "integer", "description": "The element's number, like 3 for [3]."]], required: ["index"]),
        tool("browser_type", "Type text into the input with this number. Replaces what's there unless clear is false.",
             ["index": ["type": "integer"], "text": ["type": "string"],
              "submit": ["type": "boolean", "description": "Press Enter afterwards (submits search boxes and forms)."],
              "clear": ["type": "boolean", "description": "Clear the field first. Defaults to true."]], required: ["index", "text"]),
        tool("browser_select", "Choose an option, by its text or value, in the drop-down list with this number.",
             ["index": ["type": "integer"], "option": ["type": "string"]], required: ["index", "option"]),
        tool("browser_scroll", "Scroll the page up or down by screens.",
             ["direction": ["type": "string", "enum": ["up", "down"]], "pages": ["type": "number", "description": "How many screens. Defaults to 1."]], required: ["direction"]),
        tool("browser_press", "Press a key on the focused element: Enter, Escape, Tab, ArrowUp, ArrowDown, ArrowLeft, ArrowRight or Backspace. For typing text, use browser_type.",
             ["key": ["type": "string"]], required: ["key"]),
        tool("browser_back", "Go back a page."),
        tool("browser_forward", "Go forward a page."),
        tool("browser_text", "Read all the text on the current page, for long articles or docs."),
        tool("browser_screenshot", "See the visible part of the page as an image (for models that take images)."),
        tool("browser_wait", "Wait for the page to change (up to 10 seconds), then read it again.",
             ["seconds": ["type": "number"]], required: ["seconds"]),
        tool("browser_new_tab", "Open a new browser tab in the panel, optionally at an address.",
             ["url": ["type": "string"]]),
        tool("browser_sign_in", "Sign in on the page with the user's own username and password: they type them in Kuvo Code (or pick a saved one), and they go straight into the fields you name. You never see them. Use this for every sign-in, and never ask for a password in the chat. Name the fields the page has now (on a sign-in that asks for the username and the password on pages of their own, call it on each; the user answers once). Then submit the form yourself.",
             ["username": ["type": "integer", "description": "The number of the username or email field, if the page has one."],
              "password": ["type": "integer", "description": "The number of the password field, if the page has one."]]),
        tool("browser_ask_code", "Ask the user for a one-time code (from a text message, an email or an authenticator app), which goes straight into the field with this number. You never see it. Then submit it if the page doesn't on its own.",
             ["index": ["type": "integer"], "prompt": ["type": "string", "description": "What to tell the user, like \"Enter the 6-digit code texted to your phone\"."]], required: ["index"]),
        tool("browser_ask_user", "Ask the user to do something on the page themselves: a CAPTCHA, approving the sign-in on their phone, or anything else you can't do. Waits until they say it's done (up to 15 minutes), then reads the page again.",
             ["instruction": ["type": "string", "description": "What they should do, in a sentence."]], required: ["instruction"]),
    ]

    /// How long the engine lets a tool run: longer than the agent waits for the user.
    static let executionTimeout = 960_000

    /// What the engine tells the model about the tools.
    nonisolated static func instructions(machine: Bool) -> String {
        let place = machine
            ? "Use these tools to browse in the browser on this machine, which the user can watch in Kuvo Code's panel. localhost is this machine, so you can open servers you run here."
            : "Use these tools to browse in the browser panel the user sees."
        return place + " Start with browser_navigate, read pages with browser_snapshot, and act on elements by their number. To sign in, use browser_sign_in; for a one-time code, browser_ask_code; for anything only the user can do (a CAPTCHA, approving on their phone), browser_ask_user. Never ask the user for a password or a code in the chat."
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }

    static func call(_ name: String, arguments: [String: Any], agent: BrowserAgent) async -> [String: Any] {
        func text(_ value: String, error: Bool = false) -> [String: Any] {
            ["content": [["type": "text", "text": value]], "isError": error]
        }
        func int(_ key: String) -> Int? { (arguments[key] as? NSNumber)?.intValue ?? (arguments[key] as? String).flatMap(Int.init) }
        func string(_ key: String) -> String? { arguments[key] as? String }
        func bool(_ key: String) -> Bool? { (arguments[key] as? NSNumber)?.boolValue }

        switch name {
        case "browser_navigate":
            guard let url = string("url") else { return text("Missing url.", error: true) }
            return text(await agent.navigate(url))
        case "browser_snapshot":
            return text(await agent.snapshot())
        case "browser_click":
            guard let index = int("index") else { return text("Missing index.", error: true) }
            return text(await agent.click(index))
        case "browser_type":
            guard let index = int("index"), let value = string("text") else { return text("Missing index or text.", error: true) }
            return text(await agent.type(index, text: value, submit: bool("submit") ?? false, clear: bool("clear") ?? true))
        case "browser_select":
            guard let index = int("index"), let option = string("option") else { return text("Missing index or option.", error: true) }
            return text(await agent.select(index, option: option))
        case "browser_scroll":
            let pages = (arguments["pages"] as? NSNumber)?.doubleValue ?? 1
            return text(await agent.scroll(down: string("direction") != "up", pages: pages))
        case "browser_press":
            guard let key = string("key") else { return text("Missing key.", error: true) }
            return text(await agent.press(key))
        case "browser_back":
            return text(await agent.back())
        case "browser_forward":
            return text(await agent.forward())
        case "browser_text":
            return text(await agent.text())
        case "browser_screenshot":
            guard let png = await agent.screenshot() else { return text("Couldn't capture the page.", error: true) }
            return ["content": [["type": "image", "data": png, "mimeType": "image/png"]]]
        case "browser_wait":
            return text(await agent.wait((arguments["seconds"] as? NSNumber)?.doubleValue ?? 2))
        case "browser_new_tab":
            return text(await agent.newTab(string("url")))
        case "browser_sign_in":
            return text(await agent.signIn(username: int("username"), password: int("password")))
        case "browser_ask_code":
            guard let index = int("index") else { return text("Missing index.", error: true) }
            return text(await agent.askCode(index, prompt: string("prompt")))
        case "browser_ask_user":
            guard let instruction = string("instruction"), !instruction.isEmpty else { return text("Missing instruction.", error: true) }
            return text(await agent.askUser(instruction))
        default:
            return text("Unknown tool \(name).", error: true)
        }
    }
}

// MARK: - A minimal HTTP/1.1 server connection

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ object: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
    }
}

/// One client connection: reads requests (keep-alive), answers them one at a time.
@MainActor
private final class HTTPConnection {
    private let connection: NWConnection
    private let handler: (HTTPRequest) async -> HTTPResponse
    private let closed: (ObjectIdentifier) -> Void
    private var buffer = Data()

    init(connection: NWConnection, handler: @escaping (HTTPRequest) async -> HTTPResponse, closed: @escaping (ObjectIdentifier) -> Void) {
        self.connection = connection
        self.handler = handler
        self.closed = closed
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .failed, .cancelled: self.closed(ObjectIdentifier(self))
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data { self.buffer.append(data) }
                if self.process() { return }
                if complete || error != nil {
                    self.connection.cancel()
                } else {
                    self.receive()
                }
            }
        }
    }

    /// Handles a complete request in the buffer, if there is one; true when it took over.
    private func process() -> Bool {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { connection.cancel(); return true }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= length else { return false }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        buffer.removeSubrange(..<(bodyStart + length))
        let request = HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body)
        Task {
            let response = await handler(request)
            send(response)
        }
        return true
    }

    private func send(_ response: HTTPResponse) {
        let reason: String = switch response.status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "Error"
        }
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "keep-alive"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The next request on this connection, if one came in meanwhile.
                if !self.process() { self.receive() }
            }
        })
    }
}
