import Foundation
import OpenCodeKit
import Testing
@testable import KuvoCode

/// Searching the sidebar for what was said in conversations (B18): sessions whose conversation has
/// the words, archived ones too, the latest first, with the words around them; not one deleted
/// since, and not every session for a word only the app's own labels have ("You", "Agent").
/// The engine is stubbed.
@MainActor
@Suite(.serialized) struct SessionSearchTests {
    let engine = StubEngine(port: 47990)
    let workspace = Workspace()

    init() {
        workspace.api = engine.api
    }

    private func conversation(_ id: String, you: String, agent: String) -> [[String: Any]] {
        [
            ["id": "msg_\(id)_1", "type": "user", "time": ["created": 1], "text": you],
            ["id": "msg_\(id)_2", "type": "assistant", "agent": "build", "time": ["created": 2, "completed": 3],
             "model": ["id": "m", "providerID": "p"], "content": [["type": "text", "text": agent]]],
        ]
    }

    /// Three sessions: the login fix (the latest), dark mode, and an archived one about logs.
    private func start() async {
        engine.list([
            StubEngine.session("ses_login", title: "Login", directory: "/tmp/kuvo-tests-search", created: 30),
            StubEngine.session("ses_dark", title: "Theme", directory: "/tmp/kuvo-tests-search", created: 20),
            StubEngine.session("ses_logs", title: "Old one", directory: "/tmp/kuvo-tests-search", created: 10,
                               extra: ["metadata": ["kuvo.archived": true]]),
        ])
        engine.conversation("ses_login", conversation("login", you: "The sign-in form forgets the email", agent: "Fixed: the form keeps the email now."))
        engine.conversation("ses_dark", conversation("dark", you: "Add a dark theme", agent: "Done: the theme follows the system."))
        engine.conversation("ses_logs", conversation("logs", you: "Why is the email log so big?", agent: "It keeps every request."))
        await workspace.refresh()
    }

    private func found(_ query: String) async -> [String] {
        await workspace.searchConversations(query).map(\.session.id)
    }

    @Test func findsWhatWasSaidLatestFirstArchivedToo() async throws {
        defer { engine.stop() }
        await start()
        #expect(await found("email") == ["ses_login", "ses_logs"])
        #expect(await found("THEME") == ["ses_dark"])
        let snippet = try #require(await workspace.searchConversations("forgets").first?.snippet)
        #expect(snippet.contains("forgets the email"), "the words around it: \(snippet)")
    }

    /// Words only the app adds when it writes a conversation out (who's speaking, its title) find
    /// nothing: no one said them.
    @Test func theAppsOwnLabelsFindNothing() async throws {
        defer { engine.stop() }
        await start()
        #expect(await found("you").isEmpty)
        #expect(await found("Agent").isEmpty)
        #expect(await found("Old one").isEmpty, "a title is found by the title search, not in conversations")
    }

    @Test func aDeletedSessionIsntFound() async throws {
        defer { engine.stop() }
        await start()
        #expect(await found("email").contains("ses_logs"))
        workspace.handle(try engine.event("session.deleted", session: "ses_logs"))
        #expect(await found("email") == ["ses_login"])
    }
}
