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
        /// one that repeats, a dash and its repeat.
        public let id: String
        public let due: Date
        public let note: String
        /// How often it comes back, if it does.
        public let every: Repeat?

        public init?(id: String, note: String) {
            let parts = id.split(separator: "-", maxSplits: 2)
            guard let seconds = parts.first.flatMap({ TimeInterval($0) }) else { return nil }
            self.id = id
            due = Date(timeIntervalSince1970: seconds)
            self.note = note
            every = parts.count > 2 ? Repeat(String(parts[2])) : nil
        }

        /// The letters that name it for good: a repeating one keeps them when it comes back.
        public var letters: String { String(id.split(separator: "-").dropFirst().first ?? "") }

        /// The file's name for its next time, after it went at `now`, with the same letters; nil
        /// if it doesn't repeat.
        public func nextID(after now: Date = .now, calendar: Calendar = .current) -> String? {
            guard let every else { return nil }
            let next = every.next(after: due, now: now, calendar: calendar)
            return "\(Int(next.timeIntervalSince1970))-\(letters)-\(every.text)"
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

        /// The first time after `now` it comes back, from when it was due: the same time of day for
        /// days and weeks, across a daylight saving change too, and skipping weekends for weekdays.
        public func next(after due: Date, now: Date, calendar: Calendar = .current) -> Date {
            switch self {
            case .minutes(let n), .hours(let n):
                let period = TimeInterval(n * (self == .hours(n) ? 3600 : 60))
                return due.addingTimeInterval(((now.timeIntervalSince(due) / period).rounded(.down) + 1) * period)
            case .days, .weeks, .weekdays:
                let days = switch self { case .days(let n): n; case .weeks(let n): n * 7; default: 1 }
                var next = due
                // Whole periods missed first, then one at a time.
                let missed = Int(now.timeIntervalSince(due) / Double(days * 86_400))
                if missed > 0 { next = calendar.date(byAdding: .day, value: missed * days, to: due) ?? next }
                repeat {
                    next = calendar.date(byAdding: .day, value: days, to: next) ?? next.addingTimeInterval(Double(days * 86_400))
                } while next <= now || (self == .weekdays && calendar.isDateInWeekend(next))
                return next
            }
        }
    }

    /// A wake-up's file name: its time, a few random letters, and its repeat if it has one.
    public static func name(due: Date, every: Repeat?) -> String {
        let letters = String((0..<6).map { _ in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        return "\(Int(due.timeIntervalSince1970))-\(letters)" + (every.map { "-\($0.text)" } ?? "")
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

    /// Puts `kuvo-wake` on the machine, for an engine started before it was there.
    public static func install(on connection: SSHConnection) async throws {
        try await connection.run(RemoteEngineInstaller.folders + "\n" + installScript)
    }

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

    # Minutes into the day of a time.
    minutes() { set -- $(clock "$1" '%H %M'); echo $((${1#0} * 60 + ${2#0})); }

    # The same time of day, $2 days after $1, across a daylight saving change too.
    later() {
      l_t=$(($1 + $2 * 86400))
      l_d=$(($(minutes "$1") - $(minutes "$l_t")))
      [ "$l_d" -gt 720 ] && l_d=$((l_d - 1440)); [ "$l_d" -lt -720 ] && l_d=$((l_d + 1440))
      echo $((l_t + l_d * 60))
    }

    # Whether a repeat reads: 30m, 2h, 1d, 1w (at least 5m), or weekdays.
    repeats() {
      case "$1" in
        weekdays) return 0 ;;
        *[mhdw]) r_n=${1%?}; case "$r_n" in ''|*[!0-9]*) return 1;; esac
          [ "$r_n" -gt 0 ] || return 1
          case "$1" in *m) [ "$r_n" -ge 5 ] || return 1;; esac ;;
        *) return 1 ;;
      esac
    }

    # A repeating wake-up's next time after now: $1 the time it was due, $2 its repeat.
    next() {
      case "$2" in
        *m|*h)
          n_p=${2%?}; case "$2" in *h) n_p=$((n_p * 3600));; *) n_p=$((n_p * 60));; esac
          echo $(($1 + (($now - $1) / n_p + 1) * n_p)) ;;
        *)
          case "$2" in weekdays) n_days=1;; *w) n_days=$((${2%?} * 7));; *) n_days=${2%?};; esac
          # Whole periods missed first, then one at a time.
          n_skip=$((($now - $1) / (n_days * 86400)))
          n_t=$1; [ "$n_skip" -gt 0 ] && n_t=$(later "$1" $((n_skip * n_days)))
          while :; do
            n_t=$(later "$n_t" "$n_days")
            [ "$n_t" -gt "$now" ] || continue
            [ "$2" != weekdays ] || [ "$(clock "$n_t" %u)" -le 5 ] && break
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

    # Runs a command for at most a minute, where the system lets one say so.
    limited() {
      if command -v timeout >/dev/null 2>&1; then timeout 60 sh -c "$1"
      elif command -v perl >/dev/null 2>&1; then
        # In a group of its own, so the minute's end stops the whole pipeline, not just sh.
        perl -e 'my $p = fork; if (!$p) { setpgrp; exec @ARGV; exit 127 } $SIG{ALRM} = sub { kill "TERM", -$p; sleep 1; kill "KILL", -$p; exit 124 }; alarm 60; waitpid $p, 0; exit($? >> 8)' sh -c "$1"
      else sh -c "$1"; fi
    }

    # A bot's watches that are due ($1, its folder): each runs its check, in the folder the bot
    # works in. One whose output changed since what the bot last heard (not its first run) writes
    # its wake-up to its `message`, the new output's sum to `pending`, and prints
    # "KUVO-WATCH <letters>"; once the wake-up is delivered, `delivered` makes it what the bot heard.
    checks() {
      for w in "$1"/watches/*/; do
        [ -f "${w}check" ] || continue
        c_next=$(cat "${w}next" 2>/dev/null); case "$c_next" in ''|*[!0-9]*) c_next=0;; esac
        [ "$c_next" -le "$now" ] || continue
        c_period=$(period "$(cat "${w}every" 2>/dev/null)") || continue
        printf '%s' $((now + c_period)) >"${w}next"
        c_dir=$(cat "$1/directory" 2>/dev/null); [ -d "$c_dir" ] || c_dir=$1
        c_out=$(cd "$c_dir" && limited "$(cat "${w}check")" 2>&1 </dev/null | head -c 4000)
        c_sum=$(printf '%s' "$c_out" | cksum)
        c_last=$(cat "${w}last" 2>/dev/null)
        # The first run is what it starts from.
        if [ -z "$c_last" ]; then printf '%s' "$c_sum" >"${w}last"; continue; fi
        [ "$c_last" != "$c_sum" ] || { rm -f "${w}pending" "${w}message"; continue; }
        c_letters=${w%/}; c_letters=${c_letters##*/}
        printf '%s\n\nYour watch (%s, every %s) saw a change. Its check, %s, now prints:\n%s\n' \
          "$(cat "${w}note")" "$c_letters" "$(cat "${w}every")" "$(head -n 1 "${w}check")" "$c_out" >"${w}message"
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
        # The bot's folder's tools (its browser) first: the engine connects them a moment after
        # it opens the folder, and a wake-up sent sooner goes without them.
        if [ -f "${bot}directory" ] && command -v curl >/dev/null 2>&1 && [ -z "$tools" ]; then
          tools=1; waited=
          folder=$(sed -e 's/%/%25/g' -e 's/ /%20/g' "${bot}directory")
          for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
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
          # bot's folder names), keeping its letters; others are done.
          if deliver "$(cat "$wake")"; then
            if [ -n "$every" ] && repeats "$every"; then
              tz=$(cat "${bot}timezone" 2>/dev/null)
              mv -f "$wake" "${bot}wakes/$( [ -n "$tz" ] && export TZ="$tz"; next "$due" "$every")-$rest"
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
    case "$bot" in */*) ;; ?*) bot="${KUVO_BOTS:-$HOME/.kuvo-code/bots}/$bot" ;; esac
    if [ -z "$1" ] || [ ! -d "$bot" ]; then usage >&2; exit 2; fi
    # The user's time zone, when the bot lives on a machine whose clock may be in another.
    if [ -s "$bot/timezone" ]; then TZ=$(cat "$bot/timezone"); export TZ; fi
    case "$command" in
      add)
        due=$(seconds "$3") || { echo "Couldn't read the time \"$3\". Use +30m, +2h, +1d, or a time like 2026-10-16T09:00." >&2; exit 2; }
        shift 3; every=
        if [ "$1" = --every ]; then
          repeats "$2" || { echo "Couldn't read the repeat \"$2\". Use 30m, 2h, 1d, 1w (at least 5m), or weekdays." >&2; exit 2; }
          every=$2; shift 2
          # On weekdays: the first one too.
          if [ "$every" = weekdays ]; then while [ "$(clock "$due" %u)" -gt 5 ]; do due=$(later "$due" 1); done; fi
        fi
        note="$*"
        [ -n "$note" ] || { echo "Add a note for yourself: what to do when you wake up." >&2; exit 2; }
        [ "$due" -gt $((now + 30)) ] || { echo "That's not in the future. Wake-ups are for later; do it now instead." >&2; exit 2; }
        mkdir -p "$bot/wakes"
        count=$(ls "$bot/wakes" 2>/dev/null | wc -l)
        [ "$count" -lt 50 ] || { echo "You already have 50 wake-ups waiting. Cancel some first." >&2; exit 2; }
        id=$(name "$due" "$every")
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
      list)
        found=
        for wake in "$bot"/wakes/*; do
          [ -f "$wake" ] || continue
          found=1; id=${wake##*/}
          every=${id#*-}; case "$every" in *-*) every=" (every ${every#*-})";; *) every=;; esac
          echo "$id  $(readable "${id%%-*}")$every  $(head -n 1 "$wake")"
        done
        for w in "$bot"/watches/*/; do
          [ -f "${w}check" ] || continue
          found=1; l=${w%/}; l=${l##*/}
          echo "$l  watch every $(cat "${w}every"): $(head -n 1 "${w}check")  ->  $(head -n 1 "${w}note")"
        done
        [ -n "$found" ] || echo "No wake-ups scheduled." ;;
      cancel)
        # By its letters, which a repeating one keeps as its time moves on.
        letters=${3#*-}; letters=${letters%%-*}; found=
        if [ -n "$letters" ]; then
          for f in "$bot"/wakes/*-"$letters" "$bot"/wakes/*-"$letters"-*; do [ -f "$f" ] && rm -f "$f" && found=1; done
          # Or a watch, by its letters alone.
          [ -d "$bot/watches/$3" ] && rm -rf "$bot/watches/$3" && found=1
        fi
        [ -n "$found" ] || { echo "No wake-up \"$3\". See kuvo-wake $1 list." >&2; exit 2; }
        echo "Canceled $3." ;;
      *) usage ;;
    esac
    """#
}
