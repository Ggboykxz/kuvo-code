import Foundation
import Testing
@testable import OpenCodeKit

struct RemoteEngineTests {
    @Test func quotesForTheShell() {
        #expect(SSHConnection.quoted("plain") == "'plain'")
        #expect(SSHConnection.quoted("it's") == #"'it'\''s'"#)
        #expect(SSHConnection.quoted("$HOME; rm -rf /") == "'$HOME; rm -rf /'")
    }

    @Test func runsAScriptWithShWhateverTheLoginShell() {
        let arguments = SSHConnection(destination: "box").arguments(running: "echo \"$HOME\"", extra: ["-L", "1:127.0.0.1:2"])
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.suffix(4) == ["-L", "1:127.0.0.1:2", "box", #"sh -c 'echo "$HOME"'"#])
    }

    @Test func theEngineGetsItsOwnFoldersAndTheMachinesLocalhost() {
        let script = RemoteServer.script(remotePort: 43_210)
        #expect(script.contains("read -r line"))
        #expect(script.contains("XDG_DATA_HOME=\"$K/data\""))
        #expect(script.contains("--port 43210 --hostname 127.0.0.1"))
        #expect(script.contains("engine/\(OpenCodeEngine.version)/opencode"))
        // Nothing secret on its command line: those come over the input.
        #expect(!script.contains("PASSWORD"))
    }

    @Test func linuxBuildsAreThePinnedVersion() {
        for machine in ["x86_64", "aarch64"] {
            let release = EngineRelease.linux(machine: machine)
            #expect(release?.version == OpenCodeEngine.version)
            #expect(release?.tarball.lastPathComponent.contains(OpenCodeEngine.version) == true)
            #expect(release?.integrity.hasPrefix("sha512-") == true)
        }
        #expect(EngineRelease.linux(machine: "riscv64") == nil)
    }

    @Test func findsAFreeLocalPort() throws {
        let port = try RemoteServer.freeLocalPort()
        #expect((1024...65535).contains(port))
    }
}

/// Against a real machine over SSH. Skipped unless KUVO_TEST_SSH_HOST names one this Mac can reach
/// with its keys (it installs the engine in that machine's ~/.kuvo-code):
///
///     KUVO_TEST_SSH_HOST=lokum-local swift test --filter LiveRemoteEngineTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KUVO_TEST_SSH_HOST"] != nil), .serialized)
struct LiveRemoteEngineTests {
    let connection = SSHConnection(destination: ProcessInfo.processInfo.environment["KUVO_TEST_SSH_HOST"] ?? "")

    @Test func installsStartsAndStops() async throws {
        let cache = FileManager.default.temporaryDirectory.appending(path: "opencodekit-remote-cache")
        try await RemoteEngineInstaller(connection: connection, cache: cache).install()

        let server = try await RemoteServer.start(connection: connection, environment: [:])
        let client = HTTPClient(endpoint: server.endpoint)
        struct Info: Decodable { var version: String }
        var info: Info?
        for _ in 0..<100 where info == nil {
            info = try? await client.send(client.request("GET", "api/info"), as: Info.self)
            if info == nil { try await Task.sleep(for: .milliseconds(150)) }
        }
        #expect(info?.version == OpenCodeEngine.version)

        // Without the password, nothing.
        let anonymous = HTTPClient(endpoint: ServerEndpoint(url: server.endpoint.url, password: nil))
        await #expect(throws: (any Error).self) { try await anonymous.send(anonymous.request("GET", "api/info"), as: Info.self) }

        server.stop()
        try await Task.sleep(for: .seconds(3))
        let left = try await connection.run("ps -eo args | grep -c '[o]pencode serve --stdio' || true")
        #expect(left.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
    }
}
