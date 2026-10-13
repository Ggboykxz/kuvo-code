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
        let folders = EngineFolders(root: FileManager.default.temporaryDirectory.appending(path: "opencodekit-tests"))
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
}
