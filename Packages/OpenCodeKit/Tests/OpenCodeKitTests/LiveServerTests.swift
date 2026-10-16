import Foundation
import Testing
@testable import OpenCodeKit

/// Runs against a real opencode binary. Skipped unless OPENCODE_TEST_BINARY points at one:
///
///     OPENCODE_TEST_BINARY=/path/to/opencode swift test --filter LiveServerTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENCODE_TEST_BINARY"] != nil))
struct LiveServerTests {
    @Test func startsAndAnswersInfo() async throws {
        let binary = URL(filePath: ProcessInfo.processInfo.environment["OPENCODE_TEST_BINARY"]!)
        let root = FileManager.default.temporaryDirectory.appending(path: "opencodekit-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = EngineFolders(root: root)
        let server = try await ServerProcess.start(executable: binary, folders: folders, environment: ProcessInfo.processInfo.environment)
        defer { server.stop() }

        let client = HTTPClient(endpoint: server.endpoint)
        struct Info: Decodable { var version: String; var pid: Int }
        // The server answers 503 while it boots.
        var info: Info?
        for _ in 0..<100 where info == nil {
            info = try? await client.send(client.request("GET", "api/info"), as: Info.self)
            if info == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(info?.version == OpenCodeEngine.version)
    }

    @Test func createsAndRemovesWorktrees() async throws {
        let binary = URL(filePath: ProcessInfo.processInfo.environment["OPENCODE_TEST_BINARY"]!)
        let root = FileManager.default.temporaryDirectory.appending(path: "opencodekit-worktrees-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appending(path: "repo")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try "hello\n".write(to: repository.appending(path: "README.md"), atomically: true, encoding: .utf8)
        for arguments in [["init", "-q"], ["add", "."], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"]] {
            let git = Process()
            git.executableURL = URL(filePath: "/usr/bin/git")
            git.arguments = arguments
            git.currentDirectoryURL = repository
            try git.run()
            git.waitUntilExit()
        }

        let server = try await ServerProcess.start(executable: binary, folders: EngineFolders(root: root.appending(path: "engine")), environment: ProcessInfo.processInfo.environment)
        defer { server.stop() }
        let api = OpenCodeAPI(endpoint: server.endpoint)
        let location = try await api.location(directory: repository.path)
        // The engine names folders by their real path (/private/var/…).
        #expect(location.project.canonical.hasSuffix(repository.path))

        try await api.setSetupCommand(project: location.project.id, "touch set-up")
        #expect(try await api.projects().first { $0.id == location.project.id }?.commands?.start == "touch set-up")

        let worktree = try await api.createWorktree(project: location.project.id)
        #expect(FileManager.default.fileExists(atPath: worktree + "/README.md"))
        #expect(FileManager.default.fileExists(atPath: worktree + "/set-up"))
        #expect(try await api.location(directory: worktree).project.id == location.project.id)

        // The setup command's file isn't committed, so only a forced removal goes through.
        await #expect(throws: ServerError.self) { try await api.removeWorktree(project: location.project.id, directory: worktree, force: false) }
        try await api.removeWorktree(project: location.project.id, directory: worktree, force: true)
        #expect(!FileManager.default.fileExists(atPath: worktree))
    }
}
