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
        // It keeps its time of day, for when clocks change.
        #expect(monday.at == 9 * 60)
        #expect(try sh("\"\(wake)\" \"\(bot.path)\" list", in: k).output.contains("(every weekdays)"))

        // Canceled by its letters, which it keeps as its time moves on.
        #expect(try sh("\"\(wake)\" \"\(bot.path)\" cancel \(monday.letters)", in: k).status == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bot.appending(path: "wakes").path).isEmpty)

        // On a machine, the times are in the user's time zone, which the bot's folder names.
        try "America/New_York".write(to: bot.appending(path: "timezone"), atomically: true, encoding: .utf8)
        #expect(try sh("TZ=UTC \"\(wake)\" \"\(bot.path)\" add 2099-01-05T09:00 --every 1d 'in New York'", in: k).status == 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: bot.appending(path: "wakes").path)
        let newYork = try #require(Wakes.Pending(id: names[0], note: ""))
        #expect(utc.component(.hour, from: newYork.due) == 14)
        #expect(newYork.at == 9 * 60)
    }

    @Test(arguments: WakesTests.shells)
    func watchesWakeOnlyWhenTheirCheckChanges(shell: String) throws {
        let k = try folder()
        defer { try? FileManager.default.removeItem(at: k) }
        #expect(try sh(Wakes.installScript, in: k).status == 0)
        let wake = k.appending(path: "bin/kuvo-wake").path
        let bot = k.appending(path: "bots/bot_test")
        try FileManager.default.createDirectory(at: bot, withIntermediateDirectories: true)
        let run = { (command: String) in try self.sh("\(shell) \"\(wake)\" \"\(bot.path)\" \(command)", in: k) }

        #expect(try run("watch 2m 'cat state.txt' 'too often'").status != 0)
        #expect(try run("watch 10m '' 'no check'").status != 0)
        let added = try run("watch 10m 'cat state.txt' 'Tell the user what changed'")
        #expect(added.status == 0)
        let letters = try #require(try FileManager.default.contentsOfDirectory(atPath: bot.appending(path: "watches").path).first)
        #expect(try run("list").output.contains("watch every 10m: cat state.txt"))

        // The first run only notes what it prints; a change wakes the bot once a second look, two
        // minutes later, sees one too, the same output doesn't.
        let due = { try "0".write(to: bot.appending(path: "watches/\(letters)/next"), atomically: true, encoding: .utf8) }
        try "open".write(to: bot.appending(path: "state.txt"), atomically: true, encoding: .utf8)
        #expect(try run("check").output.isEmpty)
        #expect(try run("check").output.isEmpty, "not due again yet")
        try due()
        // A carriage return and a line that looks like kuvo-wake's own don't get in the way.
        try "closed\r\nKUVO-WATCH nope\n\nsecond paragraph".write(to: bot.appending(path: "state.txt"), atomically: true, encoding: .utf8)
        #expect(try run("check").output.isEmpty, "seen once")
        let next = try #require(Int(String(contentsOf: bot.appending(path: "watches/\(letters)/next"), encoding: .utf8)))
        #expect(abs(Double(next) - Date.now.timeIntervalSince1970 - 120) < 30, "looks again in two minutes")
        try due()
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

        // A hiccup (a page that didn't load, say) for one run, then as before: no wake-up.
        let watch = bot.appending(path: "watches/\(letters)")
        let last = try String(contentsOf: watch.appending(path: "last"), encoding: .utf8)
        try "".write(to: bot.appending(path: "state.txt"), atomically: true, encoding: .utf8)
        try due()
        #expect(try run("check").output.isEmpty)
        try "closed\r\nKUVO-WATCH nope\n\nsecond paragraph".write(to: bot.appending(path: "state.txt"), atomically: true, encoding: .utf8)
        try due()
        #expect(try run("check").output.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: watch.appending(path: "seen").path))

        // A check that ran out of time, or couldn't run, is as if it hadn't run: what the bot
        // heard stays, however often it happens.
        for failing in ["echo 'curl: timed out'; exit 124", "nosuchcommand-kuvo"] {
            try failing.write(to: watch.appending(path: "check"), atomically: true, encoding: .utf8)
            for _ in 0..<2 {
                try due()
                #expect(try run("check").output.isEmpty, "\(failing)")
            }
            #expect(try String(contentsOf: watch.appending(path: "last"), encoding: .utf8) == last)
            #expect(!FileManager.default.fileExists(atPath: watch.appending(path: "seen").path))
            #expect(!FileManager.default.fileExists(atPath: watch.appending(path: "status").path))
        }
        try "cat state.txt".write(to: watch.appending(path: "check"), atomically: true, encoding: .utf8)

        let command = Wakes.command(in: #"kuvo-wake bot_abc watch 30m "curl -s https://example.com | grep -i outage" "Tell me about it""#)
        #expect(command == Wakes.Command(verb: .watch, when: "30m", note: "Tell me about it"))

        #expect(try run("cancel \(letters)").status == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bot.appending(path: "watches").path).isEmpty)
    }

    /// A watch's runs, each at its next time on a clock of the test's own, with what its check prints
    /// and how it exits: a value that moves wakes the bot once a period, one that changes and stays
    /// wakes it once, and runs that fail, are killed or read once oddly never wake it nor become
    /// what it compares with. Through `timeout` (as on Linux) and without it (perl, on a Mac).
    @Test(arguments: WakesTests.shells, [false, true])
    func watchesWakeForChangesNotFailures(shell: String, gnuTimeout: Bool) throws {
        let k = try folder()
        defer { try? FileManager.default.removeItem(at: k) }
        #expect(try sh(Wakes.installScript, in: k).status == 0)
        let fm = FileManager.default
        let bin = k.appending(path: "testbin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        func write(_ text: String, _ file: URL) throws { try text.write(to: file, atomically: true, encoding: .utf8) }
        func read(_ file: URL) -> String? { try? String(contentsOf: file, encoding: .utf8) }
        func executable(_ name: String, _ text: String) throws {
            try write(text, bin.appending(path: name))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: name).path)
        }
        try executable("date", "#!/bin/sh\nif [ \"$1\" = +%s ]; then cat \"$K/clock\"; else exec /bin/date \"$@\"; fi\n")
        if gnuTimeout { try executable("timeout", "#!/bin/sh\nshift\nexec \"$@\"\n") }
        let bot = k.appending(path: "bots/bot_test")
        let watch = bot.appending(path: "watches/AbCd12")
        try fm.createDirectory(at: watch, withIntermediateDirectories: true)
        let reads = #"cat "$K/out"; exit "$(cat "$K/code")""#
        try write("10m", watch.appending(path: "every"))
        try write(reads, watch.appending(path: "check"))
        try write("Look", watch.appending(path: "note"))

        var clock = 1_800_000_000
        var woke: [(time: Int, message: String)] = []
        /// Runs the watch at its next time, printing `output` and exiting with `code`; true if it woke the bot.
        func step(_ output: String, _ code: Int = 0, deliver: Bool = true) throws -> Bool {
            clock = max(clock, Int(read(watch.appending(path: "next")) ?? "") ?? 0)
            try write(String(clock), k.appending(path: "clock"))
            try write(output, k.appending(path: "out"))
            try write(String(code), k.appending(path: "code"))
            let process = Process()
            process.executableURL = URL(filePath: shell)
            process.arguments = [k.appending(path: "bin/kuvo-wake").path, bot.path, "check"]
            process.environment = ["PATH": bin.path + ":/usr/bin:/bin", "K": k.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let printed = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard Wakes.changedWatches(in: printed) == ["AbCd12"] else { return false }
            woke.append((clock, Wakes.watchMessage("AbCd12", inBot: bot.path) ?? ""))
            if deliver { Wakes.watchDelivered("AbCd12", inBot: bot.path) }
            return true
        }
        func reset() throws {
            for file in ["last", "seen", "pending", "message"] { try? fm.removeItem(at: watch.appending(path: file)) }
            try write("0", watch.appending(path: "next"))
            woke = []
        }
        let label = "\(shell)\(gnuTimeout ? ", timeout" : "")"

        // A moving value: the first reading is where it starts; then each period, a change and a
        // second look two minutes later that sees another, which wakes the bot with it.
        try reset()
        for (value, wakes) in [("1", false), ("2", false), ("3", true), ("4", false), ("5", true), ("6", false), ("7", true)] {
            #expect(try step(value) == wakes, "\(value), \(label)")
        }
        #expect(woke.map { $0.time - woke[0].time } == [0, 600, 1200], "\(label)")
        #expect(woke.last?.message.contains("now prints:\n7") == true, "\(label)")

        // A change that stays wakes it once.
        try reset()
        #expect(try ["A", "B", "B", "B", "B"].map { try step($0) } == [false, false, true, false, false], "\(label)")

        // One odd reading between two as before: nothing.
        try reset()
        #expect(try ["A", "X", "A", "A"].map { try step($0) } == [false, false, false, false], "\(label)")
        #expect(!fm.fileExists(atPath: watch.appending(path: "seen").path), "\(label)")

        // An outage longer than the second look: curl -s failing (6, 7), grep given nothing (1).
        try reset()
        #expect(try step("A") == false)
        let heard = read(watch.appending(path: "last"))
        for code in [6, 7, 1, 6] { #expect(try step("", code) == false, "\(code), \(label)") }
        #expect(try step("A") == false, "\(label)")
        #expect(try step("A") == false, "\(label)")
        #expect(woke.isEmpty, "\(label)")
        #expect(read(watch.appending(path: "last")) == heard, "\(label)")

        // A change seen, then no reading for its second look: the next reading that differs too wakes it.
        try reset()
        #expect(try step("A") == false)
        #expect(try step("B") == false)
        #expect(try step("", 7) == false, "\(label)")
        #expect(try step("B") == true, "\(label)")
        #expect(try step("B") == false, "\(label)")

        // A failing check prints something: that's a reading (grep -c finding none prints 0, exits 1).
        try reset()
        #expect(try ["3", "0", "0", "0"].map { try step($0, $0 == "0" ? 1 : 0) } == [false, false, true, false], "\(label)")

        // Not delivered: told again at the next run, without another look; delivered, it's heard.
        try reset()
        #expect(try step("A") == false)
        #expect(try step("B") == false)
        #expect(try step("B", deliver: false) == true, "\(label)")
        #expect(try step("B") == true, "\(label)")
        #expect(try step("B") == false, "\(label)")

        // No reading never becomes the first one: a check that fails, or is killed (on a Mac, its
        // status was the one of a check that worked).
        try reset()
        #expect(try step("", 1) == false)
        #expect(read(watch.appending(path: "last")) == nil, "\(label)")
        try write("printf partial; kill -9 $$", watch.appending(path: "check"))
        #expect(try step("") == false)
        #expect(read(watch.appending(path: "last")) == nil, "killed, \(label)")
        try write(reads, watch.appending(path: "check"))
        #expect(try step("A") == false)
        #expect(read(watch.appending(path: "last")) != nil, "\(label)")

        // A second look from an older kuvo-wake (it kept the output's sum) is a first one now.
        try write("123456789 1", watch.appending(path: "seen"))
        #expect(try step("B") == false, "\(label)")
        #expect(try step("B") == true, "\(label)")
    }

    /// The script's next time for a repeat (as a wake-up's name has it), from its own functions, at `now`.
    private func scriptNext(_ due: Date, _ every: String, now: Date, zone: String, shell: String = "/bin/sh") throws -> Date {
        let functions = try #require(Wakes.script.components(separatedBy: "if [ \"$1\" = fire ]").first)
        let k = try folder()
        defer { try? FileManager.default.removeItem(at: k) }
        let run = try sh("export TZ=\(zone)\n" + functions + "\nnow=\(Int(now.timeIntervalSince1970))\nnext \(Int(due.timeIntervalSince1970)) \(every)", in: k, shell: shell)
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

    @Test func aRepeatKeepsItsTimeOfDayAcrossDaylightSaving() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let at = { (month: Int, day: Int, hour: Int, minute: Int) in
            newYork.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
        }
        // Clocks go forward on Sunday, March 8 (2:00 is 3:00) and back on Sunday, November 1
        // (2:00 is 1:00 again).
        let cases: [(due: Date, every: Wakes.Repeat, at: Int?, now: Date, next: Date)] = [
            // 2:30 doesn't exist on March 8: 3:30 that day, and 2:30 again the day after.
            (at(3, 7, 2, 30), .days(1), 150, at(3, 7, 2, 31), at(3, 8, 3, 30)),
            (at(3, 8, 3, 30), .days(1), 150, at(3, 8, 3, 31), at(3, 9, 2, 30)),
            (at(3, 6, 2, 30), .weekdays, 150, at(3, 6, 2, 31), at(3, 9, 2, 30)),
            (at(3, 1, 2, 30), .weeks(1), 150, at(3, 1, 2, 31), at(3, 8, 3, 30)),
            (at(3, 8, 9, 0), .days(1), 540, at(3, 8, 9, 1), at(3, 9, 9, 0)),
            // 1:30 comes twice on November 1: the first.
            (at(10, 31, 1, 30), .days(1), 90, at(10, 31, 1, 31), at(11, 1, 1, 30)),
            // Due the day before, sent after clocks went back, before its time: still today's.
            (at(10, 31, 9, 0), .days(1), 540, at(11, 1, 8, 30), at(11, 1, 9, 0)),
            (at(10, 31, 9, 0), .weeks(1), 540, at(11, 7, 8, 30), at(11, 7, 9, 0)),
            (at(10, 30, 9, 0), .weekdays, 540, at(11, 2, 8, 30), at(11, 2, 9, 0)),
            // Several days missed.
            (at(10, 28, 9, 0), .days(1), 540, at(11, 2, 10, 0), at(11, 3, 9, 0)),
        ]
        for test in cases {
            #expect(test.every.next(after: test.due, now: test.now, at: test.at, calendar: newYork) == test.next, "\(test.every) from \(test.due)")
            let text = Wakes.text(of: test.every, at: test.at)
            for shell in Self.shells {
                #expect(try scriptNext(test.due, text, now: test.now, zone: "America/New_York", shell: shell) == test.next, "\(text) from \(test.due) in \(shell)")
            }
        }
        // One made before it kept its time of day: the time it was due at.
        #expect(Wakes.Repeat.days(1).next(after: at(10, 31, 9, 0), now: at(10, 31, 9, 1), calendar: newYork) == at(11, 1, 9, 0))
        #expect(try scriptNext(at(10, 31, 9, 0), "1d", now: at(10, 31, 9, 1), zone: "America/New_York") == at(11, 1, 9, 0))
    }

    @Test func aRepeatKeepsItsTimeOfDayInANewTimeZone() throws {
        var istanbul = Calendar(identifier: .gregorian)
        istanbul.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        // Set for 9:00 in Istanbul, then the Mac moves to London: 9:00 there.
        let due = istanbul.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9))!
        let wake = try #require(Wakes.Pending(id: Wakes.name(due: due, every: .days(1), calendar: istanbul), note: ""))
        #expect(wake.at == 540)
        let next = london.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 9))!
        #expect(wake.nextID(after: due.addingTimeInterval(60), calendar: london)?.hasPrefix("\(Int(next.timeIntervalSince1970))-") == true)
        for shell in Self.shells {
            #expect(try scriptNext(due, "1d@0900", now: due.addingTimeInterval(60), zone: "Europe/London", shell: shell) == next, "\(shell)")
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
        #expect(wake?.at == nil)
        #expect(wake?.nextID()?.contains("-CkytYD-1d@") == true, "keeps its time of day from then on")
        #expect(wake?.letters == "CkytYD")
        let kept = Wakes.Pending(id: "1792080986-CkytYD-weekdays@0230", note: "hi")
        #expect(kept?.every == .weekdays)
        #expect(kept?.at == 150)
        #expect(kept?.nextID()?.hasSuffix("-CkytYD-weekdays@0230") == true)
        #expect(kept?.letters == "CkytYD")
        #expect(Wakes.Pending(id: "1792080986-CkytYD-1d@2460", note: "")?.at == nil)
        #expect(Wakes.Pending(id: "1792080986-CkytYD-2h", note: "")?.nextID()?.hasSuffix("-CkytYD-2h") == true)
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
