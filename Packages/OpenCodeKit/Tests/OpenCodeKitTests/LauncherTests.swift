import Foundation
import Testing
@testable import OpenCodeKit

/// `kuvo-npx`, run with this Mac's sh as the engine runs an integration's server.
struct LauncherTests {
    /// Runs `kuvo-npx` with `arguments` and only `path` to find commands in.
    private func run(_ launcher: URL, _ arguments: [String], path: String) throws -> String {
        let process = Process()
        process.executableURL = launcher
        process.arguments = arguments
        process.environment = ["PATH": path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A command at `file` that prints how it was run.
    private func fake(_ file: URL, says word: String) throws {
        try "#!/bin/sh\necho \(word) \"BUN_BE_BUN=$BUN_BE_BUN\" \"$@\"\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    @Test func runsTheEnginesBunWithoutNodeAndNpxWithIt() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "launcher-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let bin = folder.appending(path: "bin"), node = folder.appending(path: "node")
        try FileManager.default.createDirectory(at: node, withIntermediateDirectories: true)
        let engine = folder.appending(path: "engine with space")
        try fake(engine, says: "engine")
        try Launcher.install(in: bin, engine: engine)
        let launcher = bin.appending(path: Launcher.name)

        #expect(try run(launcher, ["some-mcp@1.0.0", "--stdio"], path: "/bin") == "engine BUN_BE_BUN=1 x some-mcp@1.0.0 --stdio")
        try fake(node.appending(path: "npx"), says: "npx")
        #expect(try run(launcher, ["some-mcp@1.0.0"], path: node.path + ":/bin") == "npx BUN_BE_BUN= -y some-mcp@1.0.0")
    }
}
