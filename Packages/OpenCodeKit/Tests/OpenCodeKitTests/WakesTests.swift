import Foundation
import Testing
@testable import OpenCodeKit

/// The `kuvo-wake` command, run with this Mac's sh, as a bot runs it.
struct WakesTests {
    /// This Mac's sh, and dash, a Linux machine's sh, where it's here too.
    static let shells = ["/bin/sh", "/bin/dash"].filter { FileManager.default.isExecutableFile(atPath: $0) }

    /// Runs `script` with sh in a fresh folder, as `$K` for `installScript`, and returns its output.
    private func sh(_ script: String, in folder: URL, shell: String = "/bin/sh") throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: shell)
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

    @Test func readsTheCommandsABotRuns() {
        let add = Wakes.command(in: #"kuvo-wake bot_abc add +2h "check whether CI passed""#)
        #expect(add == Wakes.Command(verb: .add, when: "+2h", note: "check whether CI passed"))
        let full = Wakes.command(in: #""/Users/me/Library/Application Support/x/bin/kuvo-wake" bot_abc add 2026-10-16T09:00 'morning report'"#)
        #expect(full?.when == "2026-10-16T09:00")
        #expect(full?.note == "morning report")
        #expect(Wakes.command(in: "kuvo-wake bot_abc list")?.verb == .list)
        #expect(Wakes.command(in: "kuvo-wake bot_abc cancel 1792080986-CkytYD")?.verb == .cancel)
        #expect(Wakes.command(in: "npm test") == nil)
    }

    @Test func namesABotByItsID() throws {
        let k = try folder()
        defer { try? FileManager.default.removeItem(at: k) }
        #expect(try sh(Wakes.installScript, in: k).status == 0)
        try FileManager.default.createDirectory(at: k.appending(path: "bots/bot_x"), withIntermediateDirectories: true)
        let added = try sh("KUVO_BOTS=\"$K/bots\" \"$K/bin/kuvo-wake\" bot_x add +1d 'tomorrow'", in: k)
        #expect(added.status == 0)
        #expect(try sh("KUVO_BOTS=\"$K/bots\" \"$K/bin/kuvo-wake\" nobody list", in: k).status != 0)
        // An ID is only letters, digits, _ and -: never the folder above.
        try FileManager.default.createDirectory(at: k.appending(path: "wakes"), withIntermediateDirectories: true)
        for name in ["..", ".", "-x", "bot_x .."] {
            #expect(try sh("KUVO_BOTS=\"$K/bots\" \"$K/bin/kuvo-wake\" '\(name)' add +1d 'up there'", in: k).status != 0, "\(name)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: k.appending(path: "wakes").path).isEmpty)
    }

    @Test func cancelsOnlyInTheBotsOwnFolder() throws {
        let k = try folder()
        defer { try? FileManager.default.removeItem(at: k) }
        #expect(try sh(Wakes.installScript, in: k).status == 0)
        let other = k.appending(path: "bots/bot_y")
        for folder in ["bots/bot_x/watches/AbCd12", "bots/bot_x/wakes", "bots/bot_y/watches/Zz9", "bots/bot_y/wakes", "app"] {
            try FileManager.default.createDirectory(at: k.appending(path: folder), withIntermediateDirectories: true)
        }
        try "x".write(to: other.appending(path: "MEMORY.md"), atomically: true, encoding: .utf8)
        try "note".write(to: other.appending(path: "wakes/1792080986-Zz9"), atomically: true, encoding: .utf8)
        let cancel = { (id: String, shell: String) in try self.sh("KUVO_BOTS=\"$K/bots\" \(shell) \"$K/bin/kuvo-wake\" bot_x cancel '\(id)'", in: k) }
        for id in ["../../bot_y", "../../../app", "..", ".", "../bot_y/watches/Zz9", "*", "1-../../bot_y", "1792080986-*", "", "-Zz9", "Zz9/.."] {
            for shell in Self.shells {
                let result = try cancel(id, shell)
                #expect(result.status != 0, "\(id) in \(shell)")
                #expect(!result.output.contains("Canceled"), "\(id) in \(shell)")
            }
        }
        #expect(FileManager.default.fileExists(atPath: other.appending(path: "MEMORY.md").path))
        #expect(FileManager.default.fileExists(atPath: other.appending(path: "watches/Zz9").path))
        #expect(FileManager.default.fileExists(atPath: other.appending(path: "wakes/1792080986-Zz9").path))
        #expect(FileManager.default.fileExists(atPath: k.appending(path: "app").path))
        // Its own, by its letters, still goes.
        #expect(try cancel("AbCd12", "/bin/sh").status == 0)
        #expect(!FileManager.default.fileExists(atPath: k.appending(path: "bots/bot_x/watches/AbCd12").path))
    }

    @Test func schedulesOneThatRepeats() throws {
        let k = try folder()
        defer { try? FileManager.default.removeItem(at: k) }
        #expect(try sh(Wakes.installScript, in: k).status == 0)
        let wake = k.appending(path: "bin/kuvo-wake").path
        let bot = k.appending(path: "bots/bot_test")
        try FileManager.default.createDirectory(at: bot, withIntermediateDirectories: true)

        let added = try sh("\"\(wake)\" \"\(bot.path)\" add +1h --every 1d 'morning digest'", in: k)
        #expect(added.status == 0)
        #expect(added.output.contains("every 1d"))
        let files = try FileManager.default.contentsOfDirectory(atPath: bot.appending(path: "wakes").path)
        let pending = try #require(Wakes.Pending(id: files[0], note: "morning digest"))
        #expect(pending.every == .days(1))
        #expect(try String(contentsOf: bot.appending(path: "wakes/\(files[0])"), encoding: .utf8) == "morning digest")
        #expect(try sh("\"\(wake)\" \"\(bot.path)\" list", in: k).output.contains("(every 1d)"))
        #expect(try sh("\"\(wake)\" \"\(bot.path)\" add +1h --every 2m 'too often'", in: k).status != 0)
        #expect(try sh("\"\(wake)\" \"\(bot.path)\" add +1h --every often 'unreadable'", in: k).status != 0)

        // On weekdays, from a Saturday: the first one goes on Monday.
        try FileManager.default.removeItem(at: bot.appending(path: "wakes"))
        #expect(try sh("TZ=UTC \"\(wake)\" \"\(bot.path)\" add 2099-01-03T09:00 --every weekdays 'standup'", in: k).status == 0)
        let weekday = try FileManager.default.contentsOfDirectory(atPath: bot.appending(path: "wakes").path)
        let monday = try #require(Wakes.Pending(id: weekday[0], note: ""))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(utc.component(.weekday, from: monday.due) == 2)
        #expect(utc.component(.hour, from: monday.due) == 9)

        // Canceled by its letters, which it keeps as its time moves on.
        #expect(try sh("\"\(wake)\" \"\(bot.path)\" cancel \(monday.letters)", in: k).status == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bot.appending(path: "wakes").path).isEmpty)

        // On a machine, the times are in the user's time zone, which the bot's folder names.
        try "America/New_York".write(to: bot.appending(path: "timezone"), atomically: true, encoding: .utf8)
        #expect(try sh("TZ=UTC \"\(wake)\" \"\(bot.path)\" add 2099-01-05T09:00 'in New York'", in: k).status == 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: bot.appending(path: "wakes").path)
        let newYork = try #require(Wakes.Pending(id: names[0], note: ""))
        #expect(utc.component(.hour, from: newYork.due) == 14)
    }

    @Test func watchesWakeOnlyWhenTheirCheckChanges() throws {
        let k = try folder()
        defer { try? FileManager.default.removeItem(at: k) }
        #expect(try sh(Wakes.installScript, in: k).status == 0)
        let wake = k.appending(path: "bin/kuvo-wake").path
        let bot = k.appending(path: "bots/bot_test")
        try FileManager.default.createDirectory(at: bot, withIntermediateDirectories: true)
        let run = { (command: String) in try self.sh("\"\(wake)\" \"\(bot.path)\" \(command)", in: k) }

        #expect(try run("watch 2m 'cat state.txt' 'too often'").status != 0)
        #expect(try run("watch 10m '' 'no check'").status != 0)
        let added = try run("watch 10m 'cat state.txt' 'Tell the user what changed'")
        #expect(added.status == 0)
        let letters = try #require(try FileManager.default.contentsOfDirectory(atPath: bot.appending(path: "watches").path).first)
        #expect(try run("list").output.contains("watch every 10m: cat state.txt"))

        // The first run only notes what it prints; a change wakes the bot, the same output doesn't.
        let due = { try "0".write(to: bot.appending(path: "watches/\(letters)/next"), atomically: true, encoding: .utf8) }
        try "open".write(to: bot.appending(path: "state.txt"), atomically: true, encoding: .utf8)
        #expect(try run("check").output.isEmpty)
        #expect(try run("check").output.isEmpty, "not due again yet")
        try due()
        // A carriage return and a line that looks like kuvo-wake's own don't get in the way.
        try "closed\r\nKUVO-WATCH nope\n\nsecond paragraph".write(to: bot.appending(path: "state.txt"), atomically: true, encoding: .utf8)
        #expect(Wakes.changedWatches(in: try run("check").output) == [letters])
        let message = try #require(Wakes.watchMessage(letters, inBot: bot.path))
        #expect(message.hasPrefix("Tell the user what changed"))
        #expect(message.contains("closed"))
        #expect(message.contains("\n\nsecond paragraph"))

        // Not delivered: the next check tells it again; delivered, it's what the bot heard.
        try due()
        #expect(Wakes.changedWatches(in: try run("check").output) == [letters])
        Wakes.watchDelivered(letters, inBot: bot.path)
        #expect(Wakes.watchMessage(letters, inBot: bot.path) == nil)
        try due()
        #expect(try run("check").output.isEmpty)

        let command = Wakes.command(in: #"kuvo-wake bot_abc watch 30m "curl -s https://example.com | grep -i outage" "Tell me about it""#)
        #expect(command == Wakes.Command(verb: .watch, when: "30m", note: "Tell me about it"))

        #expect(try run("cancel \(letters)").status == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bot.appending(path: "watches").path).isEmpty)
    }

    /// The script's next time for a repeat, from its own functions, at `now`.
    private func scriptNext(_ due: Date, _ every: String, now: Date, zone: String) throws -> Date {
        let functions = try #require(Wakes.script.components(separatedBy: "if [ \"$1\" = fire ]").first)
        let k = try folder()
        defer { try? FileManager.default.removeItem(at: k) }
        let run = try sh("export TZ=\(zone)\n" + functions + "\nnow=\(Int(now.timeIntervalSince1970))\nnext \(Int(due.timeIntervalSince1970)) \(every)", in: k)
        return Date(timeIntervalSince1970: try #require(TimeInterval(run.output.trimmingCharacters(in: .whitespacesAndNewlines))))
    }

    @Test func aRepeatComesBackAtTheSameTimeOfDay() throws {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let at = { (day: Int, hour: Int) in berlin.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }
        // Clocks go back on Sunday the 25th: a 9:00 wake-up stays at 9:00.
        let cases: [(due: Date, every: Wakes.Repeat, now: Date, next: Date)] = [
            (at(24, 9), .days(1), at(24, 9).addingTimeInterval(5), at(25, 9)),
            (at(20, 9), .days(1), at(24, 12), at(25, 9)),
            (at(23, 9), .weekdays, at(23, 9).addingTimeInterval(5), at(26, 9)),
            (at(19, 9), .weeks(1), at(19, 10), at(26, 9)),
            (at(24, 9), .hours(2), at(24, 12), at(24, 13)),
            (at(24, 9), .minutes(30), at(24, 9).addingTimeInterval(60), at(24, 9).addingTimeInterval(1800)),
        ]
        for test in cases {
            #expect(test.every.next(after: test.due, now: test.now, calendar: berlin) == test.next, "\(test.every)")
            #expect(try scriptNext(test.due, test.every.text, now: test.now, zone: "Europe/Berlin") == test.next, "\(test.every) in sh")
        }
    }

    @Test func readsARepeat() {
        #expect(Wakes.Repeat("30m") == .minutes(30))
        #expect(Wakes.Repeat("1w") == .weeks(1))
        #expect(Wakes.Repeat("weekdays") == .weekdays)
        #expect(Wakes.Repeat("4m") == nil)
        #expect(Wakes.Repeat("-1d") == nil)
        #expect(Wakes.Repeat("d") == nil)
        let wake = Wakes.Pending(id: "1792080986-CkytYD-1d", note: "hi")
        #expect(wake?.every == .days(1))
        #expect(wake?.nextID()?.hasSuffix("-CkytYD-1d") == true)
        #expect(wake?.letters == "CkytYD")
        #expect(Wakes.Pending(id: "1792080986-CkytYD", note: "hi")?.nextID() == nil)
        let command = Wakes.command(in: #"kuvo-wake bot_abc add 2026-10-17T09:00 --every weekdays "standup""#)
        #expect(command == Wakes.Command(verb: .add, when: "2026-10-17T09:00", note: "standup", every: .weekdays))
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
