import Foundation
import OpenCodeKit
import Testing
@testable import KuvoCode

/// A project's other folders: its agent works in them as in its own (by their path, and the path
/// they're at through a link, as /var is /private/var), after your own rules so Ask First still
/// asks; changing the folders replaces their rules, and a bot's own folder stays allowed.
@Suite struct ProjectFoldersTests {
    private let ask = PermissionRule(action: "external_directory", resource: "*", effect: .ask)

    @Test func eachFolderAllowedByItsPathAndWhereItIs() throws {
        let link = FileManager.default.temporaryDirectory.appending(path: "kuvo-link-\(UUID().uuidString)")
        let real = AppInfo.testRoot.appending(path: "Folders/api-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: link) }
        let rules = ProjectFolders.rules(for: [link.path])
        #expect(rules.map(\.resource).contains(link.path + "/*"))
        #expect(rules.map(\.resource).contains(real.resolvingSymlinksInPath().path + "/*"))
        #expect(rules.allSatisfy { $0.effect == .allow && $0.action == "external_directory" })
    }

    /// After your rules (the last that matches wins): your Ask First rule still asks elsewhere.
    @Test func afterYourOwnRules() {
        let rules = ProjectFolders.permissions([ask], folders: ["/srv/api"])
        #expect(rules.first == ask)
        #expect(rules.last?.resource == "/srv/api/*")
    }

    /// Other folders now: the old ones' rules go, a bot's own folder's stays.
    @Test func changingTheFoldersReplacesTheirRules() {
        let bot = PermissionRule(action: "external_directory", resource: "/Users/me/Library/Application Support/run.kuvo.code/bots/bot_abc/*", effect: .allow)
        let before = ProjectFolders.permissions([ask, bot], folders: ["/srv/old"])
        let after = ProjectFolders.permissions(before, folders: ["/srv/new"])
        #expect(!after.contains { $0.resource.hasPrefix("/srv/old") })
        #expect(after.contains { $0.resource == "/srv/new/*" })
        #expect(after.contains(bot) && after.contains(ask))
    }

    /// The agent is told which folders are the project's, by name, so "in api" means one.
    @Test func theAgentIsToldWhichFolders() {
        let text = ProjectFolders.instructions(primary: "/srv/web", folders: ["/srv/api", "/srv/shared lib"])
        #expect(text.contains("web (/srv/web)"))
        #expect(text.contains("- api: /srv/api") && text.contains("- shared lib: /srv/shared lib"))
    }
}
