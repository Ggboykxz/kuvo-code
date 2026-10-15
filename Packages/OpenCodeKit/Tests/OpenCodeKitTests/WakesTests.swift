import Foundation
import Testing
@testable import OpenCodeKit

/// The `kuvo-wake` command, run with this Mac's sh, as a bot runs it.
struct WakesTests {
    /// Runs `script` with sh in a fresh folder, as `$K` for `installScript`, and returns its output.
    private func sh(_ script: String, in folder: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = folder
        process.environment = ["PATH": "/usr/bin:/bin", "K": folder.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "wakes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func installsAndSchedulesListsAndCancels() throws {
        let k = try folder()
        defer { try? FileManager.default.removeItem(at: k) }
        #expect(try sh(Wakes.installScript, in: k).status == 0)
        let wake = k.appending(path: "bin/kuvo-wake").path
        let bot = k.appending(path: "bots/bot_test")
        try FileManager.default.createDirectory(at: bot, withIntermediateDirectories: true)

        let added = try sh("\"\(wake)\" \"\(bot.path)\" add +2h 'check whether CI passed'", in: k)
        #expect(added.status == 0)
        #expect(added.output.hasPrefix("Scheduled "))
        let files = try FileManager.default.contentsOfDirectory(atPath: bot.appending(path: "wakes").path)
        #expect(files.count == 1)
        let pending = try #require(Wakes.Pending(id: files[0], note: "check whether CI passed"))
        #expect(abs(pending.due.timeIntervalSinceNow - 7200) < 60)

        #expect(try sh("\"\(wake)\" \"\(bot.path)\" list", in: k).output.contains("check whether CI passed"))
        #expect(try sh("\"\(wake)\" \"\(bot.path)\" add 2001-01-01T09:00 'too late'", in: k).status != 0)
        #expect(try sh("\"\(wake)\" \"\(bot.path)\" add soon 'unreadable'", in: k).status != 0)
        #expect(try sh("\"\(wake)\" \"\(bot.path)\" add +1d", in: k).status != 0)

        #expect(try sh("\"\(wake)\" \"\(bot.path)\" cancel \(files[0])", in: k).status == 0)
        #expect(try sh("\"\(wake)\" \"\(bot.path)\" list", in: k).output.contains("No wake-ups"))
    }

    @Test func aWakeUpsTimeComesFromItsName() {
        let wake = Wakes.Pending(id: "1792080986-CkytYD", note: "hi")
        #expect(wake?.due == Date(timeIntervalSince1970: 1_792_080_986))
        #expect(Wakes.Pending(id: "notes.txt", note: "") == nil)
    }

    @Test func theWatchdogSendsWakeUpsAndKeepsTheEngineForThem() {
        let script = RemoteServer.launchScript
        #expect(script.contains("kuvo-wake\" fire"))
        #expect(script.contains("bots/*/wakes/*"))
        #expect(script.contains("KUVO_WAKE"))
    }
}
