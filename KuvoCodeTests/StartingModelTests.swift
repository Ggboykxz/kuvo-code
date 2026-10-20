import Foundation
import OpenCodeKit
import Testing
@testable import KuvoCode

/// The model a new session or bot starts on: the one you picked if you can still use it, else
/// the engine's default, else the first you can use; never one whose account you signed out of
/// (it would only fail). Before the models are known, what you picked, as it is. The engine's
/// answers are stubbed (StubWeb), in the shape it sends them.
@MainActor
@Suite(.serialized) struct StartingModelTests {
    static let engine = "http://127.0.0.1:47999"
    let catalog = Catalog(isMac: true)

    init() {
        TestEnvironment.prepare()
        StubWeb.start(hosts: ["127.0.0.1", "models.opencode.ai"])
        catalog.api = OpenCodeAPI(endpoint: ServerEndpoint(url: URL(string: Self.engine)!, password: "test"))
    }

    private static func model(_ provider: String, _ id: String, released: Int = 1, free: Bool = false) -> [String: Any] {
        ["id": id, "modelID": id, "providerID": provider, "name": id,
         "capabilities": ["tools": true, "input": ["text"], "output": ["text"]], "variants": [],
         "time": ["released": released], "cost": [["input": free ? 0 : 1, "output": free ? 0 : 1]],
         "status": "active", "enabled": true, "limit": ["context": 100_000, "output": 8_000]]
    }

    private static func account(_ id: String, signedIn: Bool) -> [String: Any] {
        ["id": id, "name": id.capitalized, "methods": [["type": "key"]],
         "connections": signedIn ? [["type": "credential", "credentialID": "cred_\(id)", "method": "key"]] : []]
    }

    /// The engine as it answers: these accounts, their models, its default.
    private func engine(accounts: [[String: Any]], models: [[String: Any]], defaultModel: [String: Any]?) async throws {
        let location = ["directory": "/"]
        try StubWeb.answer(Self.engine + "/api/integration", json: ["location": location, "data": accounts])
        try StubWeb.answer(Self.engine + "/api/model", json: ["location": location, "data": models])
        try StubWeb.answer(Self.engine + "/api/model/default", json: ["location": location, "data": (defaultModel as Any?) ?? NSNull()])
        try StubWeb.answer(Self.engine + "/api/agent", json: ["location": location, "data": []])
        try StubWeb.answer(Self.engine + "/api/command", json: ["location": location, "data": []])
        await catalog.refresh()
    }

    private let sonnet = ModelRef(id: "sonnet", providerID: "anthropic")
    private let luna = ModelRef(id: "luna", providerID: "openai")

    @Test func theModelYouPickedIfYouCanUseIt() async throws {
        defer { StubWeb.stop() }
        try await engine(accounts: [Self.account("anthropic", signedIn: true), Self.account("openai", signedIn: true)],
                         models: [Self.model("anthropic", "sonnet"), Self.model("openai", "luna")],
                         defaultModel: Self.model("openai", "luna"))
        #expect(catalog.startingModel(sonnet) == sonnet)
    }

    /// Signed out of its account: the engine's default instead.
    @Test func signedOutOfItsAccountTheDefault() async throws {
        defer { StubWeb.stop() }
        try await engine(accounts: [Self.account("anthropic", signedIn: false), Self.account("openai", signedIn: true)],
                         models: [Self.model("anthropic", "sonnet"), Self.model("openai", "luna")],
                         defaultModel: Self.model("openai", "luna"))
        #expect(catalog.startingModel(sonnet) == luna)
        #expect(catalog.isUnavailable(sonnet))
    }

    /// Neither it nor the default can run: the first model you can use, of the newest first.
    @Test func neitherThenTheFirstYouCanUse() async throws {
        defer { StubWeb.stop() }
        try await engine(accounts: [Self.account("anthropic", signedIn: false), Self.account("openai", signedIn: false), Self.account("deepseek", signedIn: true)],
                         models: [Self.model("anthropic", "sonnet"), Self.model("openai", "luna"),
                                  Self.model("deepseek", "chat-old", released: 1), Self.model("deepseek", "chat-new", released: 2)],
                         defaultModel: Self.model("anthropic", "sonnet"))
        #expect(catalog.startingModel(sonnet, luna) == ModelRef(id: "chat-new", providerID: "deepseek"))
    }

    /// Of the ones you picked, the first you can use (the one picked here, then the last used).
    @Test func theFirstOfTheWantedYouCanUse() async throws {
        defer { StubWeb.stop() }
        try await engine(accounts: [Self.account("anthropic", signedIn: false), Self.account("openai", signedIn: true)],
                         models: [Self.model("anthropic", "sonnet"), Self.model("openai", "luna")],
                         defaultModel: nil)
        #expect(catalog.startingModel(nil, sonnet, luna) == luna)
    }

    /// OpenCode Zen's free models need no account.
    @Test func freeModelsNeedNoAccount() async throws {
        defer { StubWeb.stop() }
        try await engine(accounts: [Self.account("opencode", signedIn: false)],
                         models: [Self.model("opencode", "glm-free", free: true)],
                         defaultModel: nil)
        let free = ModelRef(id: "glm-free", providerID: "opencode")
        #expect(catalog.startingModel(free) == free)
    }

    /// Just after launch, before the engine has said what there is: what you picked, as it is.
    @Test func beforeTheModelsAreKnownWhatYouPicked() {
        defer { StubWeb.stop() }
        #expect(catalog.startingModel(sonnet) == sonnet)
    }

    /// A coding agent's model, before the agents have said what they have (they come after the
    /// engine): kept, not swapped for another just because it isn't listed yet.
    @Test func aCodingAgentsModelBeforeTheAgentsAnswer() async throws {
        defer { StubWeb.stop() }
        try await engine(accounts: [Self.account("openai", signedIn: true)], models: [Self.model("openai", "luna")], defaultModel: Self.model("openai", "luna"))
        let claude = ModelRef(id: "opus", providerID: "claude-code")
        #expect(catalog.startingModel(claude) == claude)
        // The agents can't run (their bridge stopped): the default instead.
        catalog.forgetAgents()
        #expect(catalog.startingModel(claude) == luna)
    }
}
