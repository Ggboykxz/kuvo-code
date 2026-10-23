import Foundation
import OpenCodeKit
import Testing
@testable import KuvoCode

/// The sidebar's lists: each project with its sessions, the latest first, the project worked in
/// last on top; chats apart; an archived session out of both, at once, and back when brought back.
/// The engine is stubbed.
@MainActor
@Suite(.serialized) struct SidebarListsTests {
    static let engine = "http://127.0.0.1:47995"
    let workspace = Workspace()

    private static func session(_ id: String, in directory: String, updated: Int, archived: Bool = false) -> [String: Any] {
        ["id": id, "projectID": "p", "cost": 0, "title": id,
         "tokens": ["input": 0, "output": 0, "reasoning": 0, "cache": ["read": 0, "write": 0]],
         "time": ["created": 1, "updated": updated], "location": ["directory": directory],
         "metadata": archived ? ["kuvo.archived": true] : [:]]
    }

    init() async {
        TestEnvironment.prepare()
        StubWeb.start(hosts: ["127.0.0.1"])
        let listed = StubWeb.json(["data": [
            Self.session("s_web_old", in: "/tmp/kuvo-tests/web", updated: 10),
            Self.session("s_web_new", in: "/tmp/kuvo-tests/web", updated: 50),
            Self.session("s_api", in: "/tmp/kuvo-tests/api", updated: 40),
            Self.session("s_gone", in: "/tmp/kuvo-tests/api", updated: 99, archived: true),
            Self.session("s_chat", in: Workspace.chatsFolder, updated: 30),
        ]])
        StubWeb.route(Self.engine + "/api/session") { _ in listed }
        StubWeb.route(Self.engine + "/api/session/active") { _ in StubWeb.json(["data": [:]]) }
        StubWeb.handle(Self.engine + "/api/session/") { request, _ in
            request.httpMethod == "PATCH" ? StubWeb.json(["data": [:]]) : StubWeb.Answer(status: 404)
        }
        workspace.api = OpenCodeAPI(endpoint: ServerEndpoint(url: URL(string: Self.engine)!, password: "test"))
        await workspace.refresh()
    }

    @Test func projectsWithTheirSessionsLatestFirst() {
        defer { StubWeb.stop() }
        let projects = workspace.projects.filter { $0.directory.hasPrefix("/tmp/kuvo-tests/") }
        #expect(projects.map(\.directory) == ["/tmp/kuvo-tests/web", "/tmp/kuvo-tests/api"])
        #expect(projects.first?.sessions.map(\.id) == ["s_web_new", "s_web_old"])
        // Archived: in neither list.
        #expect(projects.last?.sessions.map(\.id) == ["s_api"])
        #expect(workspace.chats.map(\.id) == ["s_chat"])
    }

    @Test func archivingTakesItOutAtOnceAndBack() async {
        defer { StubWeb.stop() }
        await workspace.setArchived("s_web_new", true)
        #expect(workspace.projects.first { $0.directory == "/tmp/kuvo-tests/web" }?.sessions.map(\.id) == ["s_web_old"])
        #expect(workspace.projects.first?.directory == "/tmp/kuvo-tests/api")
        await workspace.setArchived("s_web_new", false)
        #expect(workspace.projects.first { $0.directory == "/tmp/kuvo-tests/web" }?.sessions.map(\.id) == ["s_web_new", "s_web_old"])
        await workspace.setArchived("s_chat", true)
        #expect(workspace.chats.isEmpty)
    }

    @Test func pinningMarksIt() async {
        defer { StubWeb.stop() }
        await workspace.setPinned("s_api", true)
        #expect(workspace.session("s_api").map(Workspace.isPinned) == true)
        await workspace.setPinned("s_api", false)
        #expect(workspace.session("s_api").map(Workspace.isPinned) == false)
    }
}
