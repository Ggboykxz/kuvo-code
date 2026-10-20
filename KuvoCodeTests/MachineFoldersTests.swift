import Foundation
import OpenCodeKit
import Testing
@testable import KuvoCode

/// A machine's folders: written `ssh://machine/path` wherever the app keys things by folder, so
/// one never passes for this Mac's; as URLs and back, whatever the names hold; and names sent in a
/// command to the machine reach it as written, never as more of the command.
@Suite struct MachineFoldersTests {
    @Test(arguments: [
        ("my-server", "/home/me/web app"),
        ("me@box", "/srv/Zoë's project"),
        ("lab", "/"),
        ("box", "/tmp/a#b?c%20d"),
    ])
    func aFolderAndBack(machine: String, path: String) {
        let folder = RemoteFolder.folder(path, on: machine)
        #expect(RemoteFolder.isRemote(folder))
        #expect(RemoteFolder.parse(folder)?.machine == machine)
        #expect(RemoteFolder.parse(folder)?.path == path)
        let url = RemoteFolder.url(folder)
        #expect(!url.isFileURL)
        #expect(RemoteFolder.folder(of: url) == folder)
    }

    @Test func thisMacsFoldersStayThisMacs() {
        #expect(!RemoteFolder.isRemote("/Users/me/project"))
        #expect(RemoteFolder.url("/Users/me/project").isFileURL)
        #expect(RemoteFolder.parse("/Users/me/project") == nil)
    }

    /// A path the agent names, on the machine its conversation is on.
    @Test func aPathTheAgentNames() {
        let directory = RemoteFolder.folder("/srv/app", on: "box")
        #expect(RemoteFolder.folder(of: RemoteFolder.fileURL("src/main.go", in: directory)) == RemoteFolder.folder("/srv/app/src/main.go", on: "box"))
        #expect(RemoteFolder.folder(of: RemoteFolder.fileURL("/etc/hosts", in: directory)) == RemoteFolder.folder("/etc/hosts", on: "box"))
        #expect(RemoteFolder.fileURL("src/main.go", in: "/Users/me/app").path == "/Users/me/app/src/main.go")
    }

    /// Whatever a name holds, the shell on the other side gets it as one word, as written.
    @Test(arguments: ["plain", "two words", "it's", "a'; rm -rf ~; echo '", "$(whoami)", "`id`", "back\\slash", "new\nline", ""])
    func namesReachTheShellAsWritten(name: String) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "printf %s " + SSHConnection.quoted(name)]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(String(decoding: data, as: UTF8.self) == name)
    }

    /// A sign-in page that sends the browser back to localhost: its port, to forward to the machine.
    @Test func aSignInsReturnPort() throws {
        let url = try #require(URL(string: "https://auth.openai.com/authorize?client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"))
        #expect(SignInForward.callbackPort(in: url) == 1455)
        #expect(SignInForward.callbackPort(in: URL(string: "https://x.com/a?redirect_uri=https%3A%2F%2Fexample.com%3A8443%2F")!) == nil)
        #expect(SignInForward.callbackPort(in: URL(string: "https://x.com/a?redirect_uri=http%3A%2F%2Flocalhost%3A80%2F")!) == nil)
    }
}
