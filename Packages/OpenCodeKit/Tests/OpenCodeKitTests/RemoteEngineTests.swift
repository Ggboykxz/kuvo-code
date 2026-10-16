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
        #expect(arguments.contains("ControlMaster=auto"))
        // The engine's connection never joins the shared one.
        #expect(SSHConnection(destination: "box").arguments(running: "true", shared: false).contains("ControlPath=none"))
    }

    @Test func theEngineRunsOnItsOwnOnTheMachinesLocalhost() {
        let script = RemoteServer.launchScript
        #expect(script.contains("read -r line"))
        #expect(script.contains("XDG_DATA_HOME=\"$K/data\""))
        #expect(script.contains("setsid"))
        #expect(script.contains("--hostname 127.0.0.1"))
        #expect(script.contains("engine/\(OpenCodeEngine.version)/opencode"))
        // Nothing secret on its command line: those come over the input.
        #expect(!script.contains("PASSWORD"))
        // Only its user can read how to find it.
        #expect(script.contains("umask 077"))
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

    @Test func aMachinesFoldersAreKeyedApartAndSentPlain() {
        let api = OpenCodeAPI(endpoint: ServerEndpoint(url: URL(string: "http://127.0.0.1:1")!, password: nil), folderPrefix: "ssh://box")
        #expect(api.enginePath("ssh://box/home/me/app") == "/home/me/app")
        #expect(api.appFolder("/home/me/app") == "ssh://box/home/me/app")
        // Already the app's, or another machine's: left as it is.
        #expect(api.appFolder("ssh://box/home/me/app") == "ssh://box/home/me/app")
        #expect(api.enginePath("/Users/me/app") == "/Users/me/app")
    }

    @Test func findsAFreeLocalPort() throws {
        let port = try RemoteServer.freeLocalPort()
        #expect((1024...65535).contains(port))
    }
}

/// Against a real machine over SSH. Skipped unless KUVO_TEST_SSH_HOST names one this Mac can reach
/// with its keys (it installs the engine in that machine's ~/.kuvo-code-test, apart from the app's):
///
///     KUVO_TEST_SSH_HOST=my-server swift test --filter LiveRemoteEngineTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KUVO_TEST_SSH_HOST"] != nil), .serialized)
struct LiveRemoteEngineTests {
    let connection = SSHConnection(destination: ProcessInfo.processInfo.environment["KUVO_TEST_SSH_HOST"] ?? "")

    init() {
        // A folder of its own, so the tests never stop an engine the app runs there.
        RemoteEngineInstaller.root = ".kuvo-code-test"
    }

    @Test func runsOnItsOwnAndIsFoundAgain() async throws {
        let cache = FileManager.default.temporaryDirectory.appending(path: "opencodekit-remote-cache")
        defer { try? FileManager.default.removeItem(at: cache) }
        try await RemoteEngineInstaller(connection: connection, cache: cache).install()
        try await RemoteServer.stop(on: connection)
        #expect(try await RemoteServer.running(on: connection) == nil)

        let engine = try await RemoteServer.launch(on: connection, environment: [:], notes: ["test": "yes"])
        let server = try await RemoteServer.attach(to: engine, on: connection)
        let client = HTTPClient(endpoint: server.endpoint)
        struct Info: Decodable { var version: String }
        let info = try await client.send(client.request("GET", "api/info"), as: Info.self)
        #expect(info.version == OpenCodeEngine.version)

        // Without the password, nothing.
        let anonymous = HTTPClient(endpoint: ServerEndpoint(url: server.endpoint.url, password: nil))
        await #expect(throws: (any Error).self) { try await anonymous.send(anonymous.request("GET", "api/info"), as: Info.self) }

        // The connection goes; the engine stays, and is found again.
        server.disconnect()
        try await Task.sleep(for: .seconds(1))
        let found = try await RemoteServer.running(on: connection)
        #expect(found == engine)
        #expect(found?.notes["test"] == "yes")
        let again = try await RemoteServer.attach(to: try #require(found), on: connection)
        let reconnected = HTTPClient(endpoint: again.endpoint)
        #expect((try? await reconnected.send(reconnected.request("GET", "api/info"), as: Info.self)) != nil)
        again.disconnect()

        try await RemoteServer.stop(on: connection)
        try await Task.sleep(for: .seconds(2))
        #expect(try await RemoteServer.running(on: connection) == nil)
        let left = try await connection.run("ps -eo pid,args | grep '[o]pencode serve --port \(engine.port)' || true")
        #expect(left.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        // Nothing of the test's stays on the machine: its watchdog, and its folder.
        _ = try await connection.run("pkill -f '[/]\\.kuvo-code-test/run' || true; rm -rf \"$HOME/.kuvo-code-test\"")
        #expect(try await connection.run("[ -e \"$HOME/.kuvo-code-test\" ] && echo left || true").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
