import Foundation

/// Wake-ups for bots. A bot schedules one with the `kuvo-wake` command: a file in its folder's
/// `wakes`, named by the time it's due, holding a note. When it's due, the note goes to the bot's
/// session as a message. On a machine the engine's watchdog sends it (`kuvo-wake fire`), so it
/// arrives while the Mac is off; on the Mac, the app does.
///
/// A bot's folder holds `session` (its session's ID), `MEMORY.md`, `wakes` and, for a bot with no
/// project, `workspace`.
public enum Wakes {
    /// A wake-up's message starts with this, so the app can show it as one, and the bot knows it.
    public static let marker = "[Wake-up] "
    /// A bot may have this many waiting at once, so a loop can't pile them up.
    public static let limit = 50

    /// One waiting wake-up, from its file.
    public struct Pending: Sendable, Hashable, Identifiable {
        /// The file's name: the time it's due, in seconds, a dash and a few random letters, and for
        /// one that repeats, a dash and its repeat; for days, weeks and weekdays, then "@" and the
        /// time of day it keeps (1d@0900), for weeks with its day (1w@Mon0900).
        public let id: String
        public let due: Date
        public let note: String
        /// How often it comes back, if it does.
        public let every: Repeat?
        /// The time of day it keeps, in minutes, for one that repeats by days; nil for one made
        /// before it kept it.
        public let at: Int?
        /// The day of the week a weekly one keeps, as `Calendar` counts them (1 is Sunday); nil
        /// for one made before it kept it.
        public let weekday: Int?

        public init?(id: String, note: String) {
            let parts = id.split(separator: "-", maxSplits: 2)
            guard let seconds = parts.first.flatMap({ TimeInterval($0) }) else { return nil }
            self.id = id
            due = Date(timeIntervalSince1970: seconds)
            self.note = note
            let repeating = parts.count > 2 ? parts[2].split(separator: "@", maxSplits: 1).map(String.init) : []
            every = repeating.first.flatMap(Repeat.init)
            let kept = repeating.count > 1 ? Wakes.kept(repeating[1]) : nil
            at = kept?.minutes
            weekday = kept?.weekday
        }

        /// The letters that name it for good: a repeating one keeps them when it comes back.
        public var letters: String { String(id.split(separator: "-").dropFirst().first ?? "") }

        /// The file's name for its next time, after it went at `now`, with the same letters, time
        /// of day and day of the week (one made before it kept those, the ones it was due at); nil
        /// if it doesn't repeat.
        public func nextID(after now: Date = .now, calendar: Calendar = .current) -> String? {
            guard let every else { return nil }
            let at = every.keepsTimeOfDay ? at ?? Wakes.minutes(of: due, calendar: calendar) : nil
            let weekday = every.keepsWeekday ? weekday ?? calendar.component(.weekday, from: due) : nil
            let next = every.next(after: due, now: now, at: at, weekday: weekday, calendar: calendar)
            return "\(Int(next.timeIntervalSince1970))-\(letters)-" + Wakes.text(of: every, at: at, weekday: weekday)
        }
    }

    /// How often a wake-up comes back: every so many minutes, hours, days or weeks, or on weekdays.
    public enum Repeat: Sendable, Hashable {
        case minutes(Int), hours(Int), days(Int), weeks(Int)
        case weekdays

        /// 30m, 2h, 1d, 1w or weekdays, as `kuvo-wake` takes it.
        public init?(_ text: String) {
            if text == "weekdays" { self = .weekdays; return }
            guard let unit = text.last, let count = Int(text.dropLast()), count > 0, text.first?.isNumber == true else { return nil }
            switch unit {
            case "m" where count >= 5: self = .minutes(count)
            case "h": self = .hours(count)
            case "d": self = .days(count)
            case "w": self = .weeks(count)
            default: return nil
            }
        }

        public var text: String {
            switch self {
            case .minutes(let n): "\(n)m"
            case .hours(let n): "\(n)h"
            case .days(let n): "\(n)d"
            case .weeks(let n): "\(n)w"
            case .weekdays: "weekdays"
            }
        }

        /// Whether it comes back at a time of day (days, weeks and weekdays) rather than after so long.
        public var keepsTimeOfDay: Bool {
            switch self {
            case .minutes, .hours: false
            case .days, .weeks, .weekdays: true
            }
        }

        /// Whether it comes back on a day of the week too (weeks).
        public var keepsWeekday: Bool {
            if case .weeks = self { true } else { false }
        }

        /// The first time after `now` it comes back, from when it was due. Days, weeks and
        /// weekdays come back at `at` (minutes into the day; nil for the time of day it was due),
        /// and weeks on `weekday` (1 is Sunday; nil for the day it was due), on `calendar`'s
        /// clock, whatever daylight saving or a new time zone did to the last time: on the night
        /// clocks go forward, a time in the hour skipped is that much later that day only.
        /// Weekdays skip weekends.
        public func next(after due: Date, now: Date, at minutes: Int? = nil, weekday: Int? = nil, calendar: Calendar = .current) -> Date {
            switch self {
            case .minutes(let n), .hours(let n):
                let period = TimeInterval(n * (self == .hours(n) ? 3600 : 60))
                return due.addingTimeInterval(((now.timeIntervalSince(due) / period).rounded(.down) + 1) * period)
            case .days, .weeks, .weekdays:
                let days = switch self { case .days(let n): n; case .weeks(let n): n * 7; default: 1 }
                let minutes = minutes ?? Wakes.minutes(of: due, calendar: calendar)
                var first = calendar.startOfDay(for: due)
                // The day it keeps nearest to the one it was due (a new time zone can put that
                // the day before or after).
                if keepsWeekday, let weekday {
                    let shift = (weekday - calendar.component(.weekday, from: first) + 7) % 7
                    first = calendar.date(byAdding: .day, value: shift > 3 ? shift - 7 : shift, to: first) ?? first
                }
                // Whole periods missed first, but not one still to come today; then one at a time.
                let missed = calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: now)).day ?? 0
                var periods = max(1, missed / days)
                for _ in 0..<400 {
                    defer { periods += 1 }
                    guard let day = calendar.date(byAdding: .day, value: periods * days, to: first) else { continue }
                    var time = calendar.dateComponents([.year, .month, .day], from: day)
                    time.hour = minutes / 60
                    time.minute = minutes % 60
                    if let next = calendar.date(from: time), next > now, self != .weekdays || !calendar.isDateInWeekend(next) { return next }
                }
                return now.addingTimeInterval(Double(days * 86_400))
            }
        }
    }

    /// A wake-up's file name: its time, a few random letters, and its repeat if it has one, with
    /// the time of day and day of the week it keeps (from `due`, on `calendar`'s clock).
    public static func name(due: Date, every: Repeat?, calendar: Calendar = .current) -> String {
        let letters = String((0..<6).map { _ in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        let repeating = every.map {
            "-" + text(of: $0, at: $0.keepsTimeOfDay ? minutes(of: due, calendar: calendar) : nil, weekday: $0.keepsWeekday ? calendar.component(.weekday, from: due) : nil)
        } ?? ""
        return "\(Int(due.timeIntervalSince1970))-\(letters)" + repeating
    }

    /// A repeat as a wake-up's name has it: 1d@0900 for every day at 9:00, 1w@Mon0900 for every
    /// Monday at 9:00.
    static func text(of every: Repeat, at minutes: Int?, weekday: Int? = nil) -> String {
        let day = weekday.flatMap { dayNames.indices.contains($0 - 1) ? dayNames[$0 - 1] : nil } ?? ""
        return every.text + (minutes.map { "@" + day + String(format: "%02d%02d", $0 / 60, $0 % 60) } ?? "")
    }

    /// The days of the week as names keep them, from Sunday, whatever the language.
    static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// The time of day, and the day of the week, a repeat's name keeps: from 0900 or Mon0900.
    static func kept(_ text: String) -> (minutes: Int, weekday: Int?)? {
        guard text.count == 7, let day = dayNames.firstIndex(of: String(text.prefix(3))) else { return minutes(text).map { ($0, nil) } }
        return minutes(String(text.dropFirst(3))).map { ($0, day + 1) }
    }

    /// Minutes into the day, from 0900.
    static func minutes(_ text: String) -> Int? {
        guard text.count == 4, text.allSatisfy({ $0.isASCII && $0.isNumber }), let hhmm = Int(text), hhmm / 100 < 24, hhmm % 100 < 60 else { return nil }
        return hhmm / 100 * 60 + hhmm % 100
    }

    /// Minutes into the day of a time, on `calendar`'s clock.
    public static func minutes(of date: Date, calendar: Calendar = .current) -> Int {
        let time = calendar.dateComponents([.hour, .minute], from: date)
        return (time.hour ?? 0) * 60 + (time.minute ?? 0)
    }

    /// A watch: every so often its check (a shell command) runs, without the model, and when what
    /// it prints changes, the bot wakes up with the new output. Kept in the bot's `watches`, a
    /// folder for each, named by its letters.
    public struct Watch: Sendable, Hashable, Identifiable {
        public let letters: String
        /// 30m, 2h, 1d.
        public let every: String
        public let check: String
        public let note: String
        public var id: String { letters }

        public init(letters: String, every: String, check: String, note: String) {
            self.letters = letters
            self.every = every
            self.check = check
            self.note = note
        }
    }

    /// The watches `kuvo-wake <bot> check` found changed, by their letters, from what it prints.
    public static func changedWatches(in output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            line.hasPrefix("KUVO-WATCH ") ? String(line.dropFirst("KUVO-WATCH ".count)) : nil
        }
    }

    /// What `kuvo-wake <bot> try <letters>` printed: what the check printed, and why a run like
    /// it wouldn't count (nil when it would). Nil for anything else, like a kuvo-wake without `try`.
    public static func tried(_ output: String) -> (output: String, skipped: String?)? {
        guard output.hasPrefix("KUVO-TRY ") else { return nil }
        let line = output.prefix { $0 != "\n" }
        let why = line.dropFirst("KUVO-TRY ".count).trimmingCharacters(in: .whitespaces)
        return (String(output.dropFirst(line.count + 1)), why.isEmpty ? nil : why)
    }

    /// A changed watch's wake-up, from its folder in the bot's (on this Mac).
    public static func watchMessage(_ letters: String, inBot folder: String) -> String? {
        try? String(contentsOfFile: watchFolder(letters, inBot: folder) + "/message", encoding: .utf8)
    }

    /// The watch's wake-up went: its output is what the bot heard, as kuvo-wake's `delivered` does.
    public static func watchDelivered(_ letters: String, inBot folder: String) {
        let watch = watchFolder(letters, inBot: folder)
        let manager = FileManager.default
        if manager.fileExists(atPath: watch + "/pending") {
            try? manager.removeItem(atPath: watch + "/last")
            try? manager.moveItem(atPath: watch + "/pending", toPath: watch + "/last")
        }
        try? manager.removeItem(atPath: watch + "/message")
    }

    private static func watchFolder(_ letters: String, inBot folder: String) -> String {
        ((folder as NSString).appendingPathComponent("watches") as NSString).appendingPathComponent(letters)
    }

    /// A `kuvo-wake` command a bot ran, read back: what it did, and for `add`, when, how often and
    /// the note; for `watch`, how often (as `when`) and the note.
    public struct Command: Sendable, Equatable {
        public enum Verb: String, Sendable { case add, list, cancel, watch }
        public let verb: Verb
        /// As written: +2h, 2026-10-16T09:00, …
        public let when: String?
        public let note: String?
        public var every: Repeat? = nil
    }

    /// The command, if `line` runs `kuvo-wake` for a bot (by name, or by its full path).
    public static func command(in line: String) -> Command? {
        let pattern = #/kuvo-wake"?\s+(?:"[^"]*"|'[^']*'|\S+)\s+(add|list|cancel|watch)\b\s*(.*)$/#
        guard let match = line.firstMatch(of: pattern), let verb = Command.Verb(rawValue: String(match.1)) else { return nil }
        if verb == .watch {
            // watch <every> <check> <note>: the check is quoted, or one word.
            let rest = match.2.trimmingCharacters(in: .whitespaces)
            let every = rest.prefix { !$0.isWhitespace }
            var after = rest.dropFirst(every.count).drop { $0.isWhitespace }
            if let quote = after.first, quote == "\"" || quote == "'", let end = after.dropFirst().firstIndex(of: quote) {
                after = after[after.index(after: end)...]
            } else {
                after = after.drop { !$0.isWhitespace }
            }
            var note = after.trimmingCharacters(in: .whitespaces)
            if let first = note.first, first == "\"" || first == "'", note.last == first, note.count >= 2 { note = String(note.dropFirst().dropLast()) }
            return Command(verb: .watch, when: every.isEmpty ? nil : String(every), note: note.isEmpty ? nil : note)
        }
        guard verb == .add else { return Command(verb: verb, when: nil, note: nil) }
        let rest = match.2.trimmingCharacters(in: .whitespaces)
        let when = rest.prefix { !$0.isWhitespace }
        var note = rest.dropFirst(when.count).trimmingCharacters(in: .whitespaces)
        var every: Repeat?
        if note.hasPrefix("--every ") {
            let repeating = note.dropFirst("--every ".count).trimmingCharacters(in: .whitespaces)
            let text = repeating.prefix { !$0.isWhitespace }
            every = Repeat(String(text))
            note = repeating.dropFirst(text.count).trimmingCharacters(in: .whitespaces)
        }
        if let first = note.first, first == "\"" || first == "'", note.last == first, note.count >= 2 { note = String(note.dropFirst().dropLast()) }
        return Command(verb: verb, when: when.isEmpty ? nil : String(when), note: note.isEmpty ? nil : note, every: every)
    }

    /// Puts `kuvo-wake` in `$K/bin` on a machine, and the bots' folder beside it (needs `$K`).
    static var installScript: String {
        """
        mkdir -p "$K/bin" "$K/bots"
        cat >"$K/bin/kuvo-wake.new" <<'KUVO_WAKE'
        \(script)
        KUVO_WAKE
        chmod 755 "$K/bin/kuvo-wake.new" && mv -f "$K/bin/kuvo-wake.new" "$K/bin/kuvo-wake"
        """
    }

    #if os(macOS)
    /// Puts `kuvo-wake` on the machine, for an engine started before it was there.
    public static func install(on connection: SSHConnection) async throws {
        try await connection.run(RemoteEngineInstaller.folders + "\n" + installScript)
    }
    #endif

    /// The command, in POSIX sh, for macOS and Linux. A bot is named by its ID, its folder being
    /// in `$KUVO_BOTS` (`~/.kuvo-code/bots` by default), or by its folder's path:
    ///
    ///     kuvo-wake <bot> add <when> [--every <repeat>] <note>
    ///                          when: +30m, +2h, +1d, or 2026-10-16T09:00
    ///                          repeat: 30m, 2h, 1d, 1w (at least 5m) or weekdays, until canceled
    ///     kuvo-wake <bot> list
    ///     kuvo-wake <bot> cancel <id>
    ///     kuvo-wake fire <bots folder> <engine.json>   sends what's due (the watchdog, on a machine)
    public static let script = #"""
    #!/bin/sh
    # Kuvo Code's wake-ups for bots. See `kuvo-wake <bot> help`.
    now=$(date +%s)

    usage() {
      echo "Usage:"
      echo "  kuvo-wake <bot> add <when> [--every <repeat>] <note>"
      echo "      when: +30m, +2h, +1d, or a time like 2026-10-16T09:00 on this computer's clock"
      echo "      repeat: 30m, 2h, 1d, 1w (at least 5m), or weekdays; it keeps coming back until canceled"
      echo "  kuvo-wake <bot> list"
      echo "  kuvo-wake <bot> watch <every> <check> <note>"
      echo "      every 5m or more, 2h, 1d: runs the check, a shell command, and wakes you when what it prints changes"
      echo "  kuvo-wake <bot> cancel <id>"
      echo "Times are on this computer's clock, or in the time zone in the bot's folder's timezone file."
    }

    # A time as seconds since 1970, from +30m, +2h, +1d, an ISO date and time, or seconds.
    seconds() {
      case "$1" in
        +*[mhd])
          n=${1#+}; unit=${n#"${n%?}"}; n=${n%?}
          case "$n" in ''|*[!0-9]*) return 1;; esac
          case "$unit" in m) echo $((now + n * 60));; h) echo $((now + n * 3600));; d) echo $((now + n * 86400));; esac ;;
        *[!0-9]*)
          t=$(echo "$1" | sed 's/T/ /')
          case "$t" in *:*:*) ;; *:*) t="$t:00" ;; esac
          date -d "$t" +%s 2>/dev/null && return 0
          date -j -f "%Y-%m-%d %H:%M:%S" "$t" +%s 2>/dev/null && return 0
          return 1 ;;
        '') return 1 ;;
        *) echo "$1" ;;
      esac
    }

    readable() { date -d "@$1" "+%a %b %-d, %H:%M" 2>/dev/null || date -r "$1" "+%a %b %-d, %H:%M"; }

    # A time (seconds) in a date format, with GNU's date or the BSD one.
    clock() { date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2"; }

    # How far this computer's clock is ahead of UTC at a time, in seconds.
    offset() {
      o_z=$(clock "$1" %z); case "$o_z" in [+-][0-9][0-9][0-9][0-9]) ;; *) echo 0; return ;; esac
      o_h=${o_z#?}; o_m=${o_h#??}; o_h=${o_h%??}
      o_s=$((${o_h#0} * 3600 + ${o_m#0} * 60))
      case "$o_z" in -*) echo $((-o_s)) ;; *) echo "$o_s" ;; esac
    }

    # The day of a time on this computer's clock, counted from January 1, 1970 (a Thursday).
    day() { echo $((($1 + $(offset "$1")) / 86400)); }

    # Whether a day is Monday to Friday.
    weekday() { [ $((($1 + 3) % 7)) -lt 5 ]; }

    # A day's name as a repeat keeps it (Mon), and the day of the week a name is (0 for Monday).
    dayname() { case $((($1 + 3) % 7)) in 0) echo Mon;; 1) echo Tue;; 2) echo Wed;; 3) echo Thu;; 4) echo Fri;; 5) echo Sat;; *) echo Sun;; esac; }
    daynumber() { case "$1" in Mon) echo 0;; Tue) echo 1;; Wed) echo 2;; Thu) echo 3;; Fri) echo 4;; Sat) echo 5;; Sun) echo 6;; *) return 1;; esac; }

    # The time on day $1 at $2 (0900, on this computer's clock). When clocks go back, the first of
    # the two; when they go forward, one in the hour skipped is that much later (2:30 is 3:30).
    daytime() {
      d_h=${2%??}; d_m=${2#??}
      d_l=$(($1 * 86400 + ${d_h#0} * 3600 + ${d_m#0} * 60))
      d_t=$((d_l - $(offset $((d_l - 86400)))))
      if [ $((d_t + $(offset "$d_t"))) -ne "$d_l" ]; then
        d_u=$((d_l - $(offset "$d_t")))
        [ $((d_u + $(offset "$d_u"))) -ne "$d_l" ] || d_t=$d_u
      fi
      echo "$d_t"
    }

    # Whether a repeat reads: 30m, 2h, 1d, 1w (at least 5m), or weekdays; days, weeks and weekdays
    # may say the time of day they keep (1d@0900), and weeks their day too (1w@Mon0900).
    repeats() {
      r_e=${1%@*}
      if [ "$r_e" != "$1" ]; then
        r_at=${1#*@}
        case "$r_e" in *[dw]|weekdays) ;; *) return 1 ;; esac
        case "$r_e" in *w) daynumber "${r_at%????}" >/dev/null && r_at=${r_at#???} ;; esac
        case "$r_at" in [01][0-9][0-5][0-9]|2[0-3][0-5][0-9]) ;; *) return 1 ;; esac
      fi
      case "$r_e" in
        weekdays) return 0 ;;
        *[mhdw]) r_n=${r_e%?}; case "$r_n" in ''|*[!0-9]*) return 1;; esac
          [ "$r_n" -gt 0 ] || return 1
          case "$r_e" in *m) [ "$r_n" -ge 5 ] || return 1;; esac ;;
        *) return 1 ;;
      esac
    }

    # A repeat as a wake-up's name has it, from its time ($1): days, weeks and weekdays with the
    # time of day they keep, and weeks with their day, whatever daylight saving or a new time zone
    # does to the last time (what it keeps already stays).
    kept() {
      k_e=${2%@*}; k_at=${2#*@}; [ "$k_e" != "$2" ] || k_at=$(clock "$1" %H%M)
      case "$k_e" in
        *w) case "$k_at" in [0-9]*) k_at=$(dayname "$(day "$1")")$k_at ;; esac; echo "$k_e@$k_at" ;;
        *d|weekdays) echo "$k_e@$k_at" ;;
        *) echo "$2" ;;
      esac
    }

    # A repeating wake-up's next time after now: $1 the time it was due, $2 its repeat as its name
    # has it (an older one without its time of day or day keeps the ones it was due at).
    next() {
      case "$2" in
        *m|*h)
          n_p=${2%?}; case "$2" in *h) n_p=$((n_p * 3600));; *) n_p=$((n_p * 60));; esac
          echo $(($1 + (($now - $1) / n_p + 1) * n_p)) ;;
        *)
          n_e=${2%@*}; n_at=${2#*@}; [ "$n_e" != "$2" ] || n_at=$(clock "$1" %H%M)
          if n_wd=$(daynumber "${n_at%????}"); then n_at=${n_at#???}; fi
          case "$n_e" in weekdays) n_days=1 n_wd=;; *w) n_days=$((${n_e%?} * 7));; *) n_days=${n_e%?} n_wd=;; esac
          n_day=$(day "$1")
          # The day it keeps nearest to the one it was due (a new time zone can put that the day
          # before or after).
          if [ -n "$n_wd" ]; then
            n_s=$(((n_wd - (n_day + 3) % 7 + 7) % 7)); [ "$n_s" -le 3 ] || n_s=$((n_s - 7))
            n_day=$((n_day + n_s))
          fi
          # Whole periods missed first, but not one still to come today; then one at a time.
          n_k=$((($(day "$now") - n_day) / n_days)); [ "$n_k" -ge 1 ] || n_k=1
          while :; do
            n_t=$(daytime $((n_day + n_k * n_days)) "$n_at")
            [ "$n_t" -gt "$now" ] && { [ "$n_e" != weekdays ] || weekday $((n_day + n_k)); } && break
            n_k=$((n_k + 1))
          done
          echo "$n_t" ;;
      esac
    }

    # What a wake-up's file is called: its time, a few random letters, and its repeat if it has one.
    name() { echo "$1-$(random 6)${2:+-$2}"; }

    # Seconds in a watch's interval: 5m or more, 2h, 1d.
    period() {
      p_n=${1%?}; case "$p_n" in ''|*[!0-9]*) return 1;; esac
      case "$1" in *m) [ "$p_n" -ge 5 ] && echo $((p_n * 60));; *h) [ "$p_n" -ge 1 ] && echo $((p_n * 3600));; *d) [ "$p_n" -ge 1 ] && echo $((p_n * 86400));; *) return 1;; esac
    }

    # Runs a command for at most a minute, where the system lets one say so: sh -c with the
    # arguments given. Its status is the command's, as `timeout` gives it: 124 when out of time,
    # 128 and the signal when killed.
    limited() {
      if command -v timeout >/dev/null 2>&1; then timeout 60 sh -c "$@"
      elif command -v perl >/dev/null 2>&1; then
        # In a group of its own, so the minute's end stops the whole pipeline, not just sh.
        perl -e 'my $p = fork; if (!$p) { setpgrp; exec @ARGV; exit 127 } $SIG{ALRM} = sub { kill "TERM", -$p; sleep 1; kill "KILL", -$p; exit 124 }; alarm 60; waitpid $p, 0; exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' sh -c "$@"
      else sh -c "$@"; fi
    }

    # Goes before a watch's check: its curl, wget and gh write to the file named by $1 (then
    # shifted away) when they fail, but not for an error page (curl's 22, wget's 8), checks still
    # pending (gh's 8) or what reads them stopping early (curl's 23, wget's 3, 141). A curl that
    # writes out its own result (-w '%{http_code}' is 000 when it can't connect) never does.
    noting='kuvo_noted=$1; shift
    kuvo_ran() { case $1 in 0|141|$3|$4) ;; *) echo "$2 $1" >>"$kuvo_noted" ;; esac; return $1; }
    curl() { command curl "$@"; kuvo_s=$?; for kuvo_a; do case $kuvo_a in --write-out*|-w*|-[!-]*w*) return $kuvo_s ;; esac; done; kuvo_ran $kuvo_s curl 22 23; }
    wget() { command wget "$@"; kuvo_ran $? wget 3 8; }
    gh() { command gh "$@"; kuvo_ran $? gh 8 8; }
    '

    # Runs a watch's check once, as its runs do ($1, the watch's folder; $2, the bot's; $3, what
    # its files for the run start with): in the folder the bot works in, for at most a minute.
    # Sets t_out to what it prints (not its errors), and t_why to why the run is no reading, or
    # to nothing when it's one.
    #
    # A check's status alone can't tell an outage from "nothing there": in `curl -s … | grep -o …`
    # it's grep's, 1 both times, and in `curl … | jq …` it's 0. So curl, wget and gh say how they
    # did, and a run is no reading when:
    # - it ran out of time, couldn't run, or was killed (141 is only its output cut short);
    # - a curl or wget in it failed, as when the network is down (an error page is a reading);
    # - it printed nothing, and a gh in it failed, or it exited 2 or more.
    # Printing nothing and exiting 0 or 1, as grep finding nothing does, is a reading: what it
    # looks for isn't there.
    run() {
      t_dir=$(cat "$2/directory" 2>/dev/null); [ -d "$t_dir" ] || t_dir=$2
      t_tmp=$1$3; rm -f "${t_tmp}status" "${t_tmp}failed"
      t_out=$(cd "$t_dir" && { limited "$noting$(cat "${1}check")" sh "${t_tmp}failed" 2>/dev/null </dev/null; echo "$?" >"${t_tmp}status"; } | head -c 4000)
      t_status=$(cat "${t_tmp}status" 2>/dev/null)
      t_failed=$(head -n 1 "${t_tmp}failed" 2>/dev/null); t_lost=$(grep -v '^gh ' "${t_tmp}failed" 2>/dev/null | head -n 1)
      rm -f "${t_tmp}status" "${t_tmp}failed"
      t_why=
      case "$t_status" in
        ''|*[!0-9]*) t_why="the check didn't finish" ;;
        124) t_why="the check ran out of time (a minute)" ;;
        12[5-8]) t_why="the check couldn't run (exit $t_status)" ;;
        *) if [ "$t_status" -gt 128 ] && [ "$t_status" -ne 141 ]; then t_why="the check was stopped (signal $((t_status - 128)))"
          elif [ -n "$t_lost" ]; then t_why="${t_lost% *} failed (exit ${t_lost##* })"
          elif [ -n "$t_out" ]; then :
          elif [ -n "$t_failed" ]; then t_why="${t_failed% *} failed (exit ${t_failed##* }), and the check printed nothing"
          elif [ "$t_status" -ge 2 ]; then t_why="the check failed (exit $t_status) without printing anything"
          fi ;;
      esac
    }

    # A bot's watches that are due ($1, its folder): each runs its check (see `run`) and compares
    # what it prints with `last`, what the bot last heard (at first, its first reading).
    #
    # A run that's no reading (a network that's down, or not back yet after sleep) is never a
    # change, nor what later runs are compared with. A change counts when two readings in a row
    # differ from `last`: the one that saw it (`seen` keeps when) and a second look two minutes
    # later, once a period, on the watch's own times. The two needn't match, so a value that keeps
    # moving (a price, a counter) wakes the bot once a period, with its latest output, while one
    # odd reading between two as before doesn't. The wake-up goes to `message`, its output's sum to
    # `pending`, and "KUVO-WATCH <letters>" is printed; once it's delivered, `delivered` makes it
    # what the bot heard, so a value that changes and stays wakes it once.
    checks() {
      for w in "$1"/watches/*/; do
        [ -f "${w}check" ] || continue
        c_next=$(cat "${w}next" 2>/dev/null); case "$c_next" in ''|*[!0-9]*) c_next=0;; esac
        [ "$c_next" -le "$now" ] || continue
        c_period=$(period "$(cat "${w}every" 2>/dev/null)") || continue
        c_seen=$(cat "${w}seen" 2>/dev/null); case "$c_seen" in ''|*[!0-9]*) c_seen=;; esac
        # A period on, from the run that saw a change when this is its second look.
        c_next=$((${c_seen:-$now} + c_period)); [ "$c_next" -gt "$now" ] || c_next=$((now + c_period))
        printf '%s' "$c_next" >"${w}next"
        run "$w" "$1" run-
        [ -z "$t_why" ] || continue
        # Sums start with "2/", for runs read this way. One from before (errors counted, a quiet
        # grep didn't) is replaced by this reading, silently, so the new way wakes no one.
        c_sum=2/$(printf '%s' "$t_out" | cksum)
        c_last=$(cat "${w}last" 2>/dev/null)
        case "$c_last" in 2/*) ;; *) printf '%s' "$c_sum" >"${w}last"; rm -f "${w}pending" "${w}message" "${w}seen"; continue ;; esac
        # As the bot heard it: no change, and one seen before was a passing one.
        [ "$c_last" != "$c_sum" ] || { rm -f "${w}pending" "${w}message" "${w}seen"; continue; }
        # (One that woke the bot without reaching it yet is told again, as it is now.)
        if [ -z "$c_seen" ] && [ ! -f "${w}pending" ]; then printf '%s' "$now" >"${w}seen"; printf '%s' $((now + 120)) >"${w}next"; continue; fi
        rm -f "${w}seen"
        c_letters=${w%/}; c_letters=${c_letters##*/}
        if [ -n "$t_out" ]; then c_now="now prints:
    $t_out"; else c_now="now prints nothing."; fi
        printf '%s\n\nYour watch (%s, every %s) saw a change. Its check, %s, %s\n' \
          "$(cat "${w}note")" "$c_letters" "$(cat "${w}every")" "$(head -n 1 "${w}check")" "$c_now" >"${w}message"
        printf '%s' "$c_sum" >"${w}pending"
        echo "KUVO-WATCH $c_letters"
      done
    }

    # A watch's wake-up went: its output is what the bot heard ($1, the watch's folder).
    delivered() { [ -f "$1/pending" ] && mv -f "$1/pending" "$1/last"; rm -f "$1/message"; }

    random() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$1"; }

    # A string as JSON.
    json() { printf '%s' "$1" | tr -d '\000-\010\013-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' | awk 'BEGIN { ORS = "" } NR > 1 { print "\\n" } { print }'; }

    if [ "$1" = fire ]; then
      bots=$2; record=$3
      [ -f "$record" ] || exit 0
      port=$(sed -n 's/.*"port":\([0-9]*\).*/\1/p' "$record")
      password=$(sed -n 's/.*"password":"\([^"]*\)".*/\1/p' "$record")
      [ -n "$port" ] && [ -n "$password" ] || exit 0
      # Sends a wake-up's text to the bot's session; true once it's gone.
      deliver() {
        # The bot's folder's tools (its browser, integrations) first: the engine connects them
        # after it opens the folder, and a wake-up sent sooner goes without them. Twenty seconds
        # at most, as an integration's server can take a while the first time.
        if [ -f "${bot}directory" ] && command -v curl >/dev/null 2>&1 && [ -z "$tools" ]; then
          tools=1; waited=; tries=0
          folder=$(sed -e 's/%/%25/g' -e 's/ /%20/g' "${bot}directory")
          while [ "$tries" -lt 80 ]; do
            tries=$((tries + 1))
            curl -sf -m 5 -u "opencode:$password" -H "x-opencode-directory: $folder" "http://127.0.0.1:$port/api/mcp" | grep -q '"pending"' || break
            waited=1; sleep 0.25
          done
          [ -n "$waited" ] && sleep 1.5
        fi
        ms=$(date +%s%3N 2>/dev/null); case "$ms" in *[!0-9]*|'') ms=$((now * 1000));; esac
        id=msg_$(printf '%012x' $(((ms * 4096 + 1) & 0xFFFFFFFFFFFF)))$(random 14)
        body="{\"id\":\"$id\",\"text\":\"$(json "[Wake-up] $1")\",\"delivery\":\"queue\"}"
        url="http://127.0.0.1:$port/api/session/$session/prompt"
        if command -v curl >/dev/null 2>&1; then
          curl -sf -m 20 -u "opencode:$password" -H 'Content-Type: application/json' --data-binary "$body" "$url" >/dev/null
        elif command -v wget >/dev/null 2>&1; then
          auth=$(printf 'opencode:%s' "$password" | base64 | tr -d '\n')
          wget -q -T 20 -O /dev/null --header="Authorization: Basic $auth" --header='Content-Type: application/json' --post-data="$body" "$url"
        else
          return 1
        fi
      }
      for bot in "$bots"/*/; do
        # Paused by you: its wake-ups wait.
        [ -e "${bot}paused" ] && continue
        tools=
        session=$(cat "$bot/session" 2>/dev/null) || continue
        [ -n "$session" ] || continue
        for wake in "$bot"wakes/*; do
          [ -f "$wake" ] || continue
          file=${wake##*/}; rest=${file#*-}; due=${file%%-*}
          case "$rest" in *-*) every=${rest#*-};; *) every=;; esac
          case "$due" in ''|*[!0-9]*) continue;; esac
          [ "$due" -le "$now" ] || continue
          # Sent: a repeating one comes back at its next time (in the user's time zone, which the
          # bot's folder names), keeping its letters, time of day and day of the week (one made
          # before it kept those, the ones it was due at); others are done.
          if deliver "$(cat "$wake")"; then
            if [ -n "$every" ] && repeats "$every"; then
              tz=$(cat "${bot}timezone" 2>/dev/null)
              mv -f "$wake" "${bot}wakes/$( [ -n "$tz" ] && export TZ="$tz"
                every=$(kept "$due" "$every")
                echo "$(next "$due" "$every")-${rest%%-*}-$every" )"
            else
              rm -f "$wake"
            fi
          fi
        done
      done
      # Then their watches (a slow check never holds up a wake-up): what changed wakes the bot,
      # with what its check prints now; one that can't go is tried again at the next check.
      for bot in "$bots"/*/; do
        [ -e "${bot}paused" ] && continue
        [ -d "${bot}watches" ] || continue
        tools=
        session=$(cat "$bot/session" 2>/dev/null) || continue
        [ -n "$session" ] || continue
        tz=$(cat "${bot}timezone" 2>/dev/null)
        for letters in $( ( [ -n "$tz" ] && export TZ="$tz"; checks "${bot%/}" ) | sed -n 's/^KUVO-WATCH //p'); do
          w="${bot}watches/$letters"
          [ -f "$w/message" ] && deliver "$(cat "$w/message")" && delivered "$w"
        done
      done
      exit 0
    fi

    bot=$1; command=$2
    # A bot's ID is letters, digits, _ and -; a folder is named by its path.
    case "$bot" in */*) ;; -*|*[!A-Za-z0-9_-]*) bot= ;; ?*) bot="${KUVO_BOTS:-$HOME/.kuvo-code/bots}/$bot" ;; esac
    if [ -z "$bot" ] || [ ! -d "$bot" ]; then usage >&2; exit 2; fi
    bot=$(CDPATH= cd -- "$bot" && pwd) || exit 2
    # The user's time zone, when the bot lives on a machine whose clock may be in another.
    if [ -s "$bot/timezone" ]; then TZ=$(cat "$bot/timezone"); export TZ; fi
    case "$command" in
      add)
        due=$(seconds "$3") || { echo "Couldn't read the time \"$3\". Use +30m, +2h, +1d, or a time like 2026-10-16T09:00." >&2; exit 2; }
        shift 3; every=
        if [ "$1" = --every ]; then
          repeats "$2" || { echo "Couldn't read the repeat \"$2\". Use 30m, 2h, 1d, 1w (at least 5m), or weekdays." >&2; exit 2; }
          every=${2%@*}; shift 2
          # On weekdays: the first one too, at the same time of day.
          if [ "$every" = weekdays ] && ! weekday "$(day "$due")"; then
            a_day=$(day "$due"); a_at=$(clock "$due" %H%M)
            while ! weekday "$a_day"; do a_day=$((a_day + 1)); done
            due=$(daytime "$a_day" "$a_at")
          fi
        fi
        note="$*"
        [ -n "$note" ] || { echo "Add a note for yourself: what to do when you wake up." >&2; exit 2; }
        [ "$due" -gt $((now + 30)) ] || { echo "That's not in the future. Wake-ups are for later; do it now instead." >&2; exit 2; }
        mkdir -p "$bot/wakes"
        count=$(ls "$bot/wakes" 2>/dev/null | wc -l)
        [ "$count" -lt 50 ] || { echo "You already have 50 wake-ups waiting. Cancel some first." >&2; exit 2; }
        id=$(name "$due" "${every:+$(kept "$due" "$every")}")
        printf '%s' "$note" >"$bot/wakes/$id"
        echo "Scheduled $id for $(readable "$due")${every:+, then every $every until canceled}." ;;
      watch)
        who=$1; every=$3; check=$4
        period "$every" >/dev/null || { echo "Couldn't read how often, \"$3\". Use 5m or more, 2h or 1d." >&2; exit 2; }
        [ -n "$check" ] || { echo "Give the check: a shell command that prints what you watch, and prints something else when it changes." >&2; exit 2; }
        shift 4; note="$*"
        [ -n "$note" ] || { echo "Add a note for yourself: what to do when it changes." >&2; exit 2; }
        count=$(ls "$bot/watches" 2>/dev/null | wc -l)
        [ "$count" -lt 20 ] || { echo "You already have 20 watches. Cancel some first." >&2; exit 2; }
        letters=$(random 6); w="$bot/watches/$letters"
        mkdir -p "$w" && printf '%s' "$every" >"$w/every" && printf '%s' "$check" >"$w/check" && printf '%s' "$note" >"$w/note" && printf '%s' "$now" >"$w/next"
        echo "Watching ($letters): every $every the check runs, without you, and when what it prints changes (not the first time), you wake up with the new output. Cancel with: kuvo-wake $who cancel $letters" ;;
      check)
        # For the Mac's app: the watches that are due, run now.
        checks "$bot" ;;
      try)
        # For Check Now: a watch's check, by its letters, run as its runs are, without counting.
        # A line with why a run like it wouldn't count (after "KUVO-TRY "), then what it printed.
        case "$3" in ''|*[!A-Za-z0-9]*) w= ;; *) w="$bot/watches/$3/" ;; esac
        [ -n "$w" ] && [ -f "${w}check" ] || { echo "No watch \"$3\". See kuvo-wake $1 list." >&2; exit 2; }
        run "$w" "$bot" try-
        printf 'KUVO-TRY %s\n%s' "$t_why" "$t_out" ;;
      list)
        found=
        for wake in "$bot"/wakes/*; do
          [ -f "$wake" ] || continue
          found=1; id=${wake##*/}
          every=${id#*-}; case "$every" in *-*) every=${every#*-}; every=" (every ${every%@*})";; *) every=;; esac
          echo "$id  $(readable "${id%%-*}")$every  $(head -n 1 "$wake")"
        done
        for w in "$bot"/watches/*/; do
          [ -f "${w}check" ] || continue
          found=1; l=${w%/}; l=${l##*/}
          echo "$l  watch every $(cat "${w}every"): $(head -n 1 "${w}check")  ->  $(head -n 1 "${w}note")"
        done
        [ -n "$found" ] || echo "No wake-ups scheduled." ;;
      cancel)
        # By its letters, which a repeating one keeps as its time moves on: its ID as list shows
        # it, or the letters alone. Nothing else, so it never names a folder outside the bot's.
        letters=${3#*-}; letters=${letters%%-*}; found=
        case "$3" in -*|*[!A-Za-z0-9@-]*) letters= ;; esac
        case "$letters" in *[!A-Za-z0-9]*) letters= ;; esac
        if [ -n "$letters" ]; then
          for f in "$bot"/wakes/*-"$letters" "$bot"/wakes/*-"$letters"-*; do [ -f "$f" ] && rm -f "$f" && found=1; done
          # Or a watch, by its letters alone.
          [ "$letters" = "$3" ] && [ -d "$bot/watches/$letters" ] && rm -rf "$bot/watches/$letters" && found=1
        fi
        [ -n "$found" ] || { echo "No wake-up \"$3\". See kuvo-wake $1 list." >&2; exit 2; }
        echo "Canceled $3." ;;
      *) usage ;;
    esac
    """#
}
