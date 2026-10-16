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

        /// The file's name for its next time, after it went at `now`; nil if it doesn't repeat.
        public func nextID(after now: Date = .now, calendar: Calendar = .current) -> String? {
            guard let every else { return nil }
            let next = every.next(after: due, now: now, calendar: calendar)
            return Wakes.name(due: next, every: every)
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

    /// A `kuvo-wake` command a bot ran, read back: what it did, and for `add`, when, how often and
    /// the note.
    public struct Command: Sendable, Equatable {
        public enum Verb: String, Sendable { case add, list, cancel }
        public let verb: Verb
        /// As written: +2h, 2026-10-16T09:00, …
        public let when: String?
        public let note: String?
        public var every: Repeat? = nil
    }

    /// The command, if `line` runs `kuvo-wake` for a bot (by name, or by its full path).
    public static func command(in line: String) -> Command? {
        let pattern = #/kuvo-wake"?\s+(?:"[^"]*"|'[^']*'|\S+)\s+(add|list|cancel)\b\s*(.*)$/#
        guard let match = line.firstMatch(of: pattern), let verb = Command.Verb(rawValue: String(match.1)) else { return nil }
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
      echo "  kuvo-wake <bot> cancel <id>"
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

    random() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$1"; }

    # A string as JSON.
    json() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' | awk 'BEGIN { ORS = "" } NR > 1 { print "\\n" } { print }'; }

    if [ "$1" = fire ]; then
      bots=$2; record=$3
      [ -f "$record" ] || exit 0
      port=$(sed -n 's/.*"port":\([0-9]*\).*/\1/p' "$record")
      password=$(sed -n 's/.*"password":"\([^"]*\)".*/\1/p' "$record")
      [ -n "$port" ] && [ -n "$password" ] || exit 0
      for bot in "$bots"/*/; do
        # Paused by you: its wake-ups wait.
        [ -e "${bot}paused" ] && continue
        tools=
        session=$(cat "$bot/session" 2>/dev/null) || continue
        [ -n "$session" ] || continue
        for wake in "$bot"wakes/*; do
          [ -f "$wake" ] || continue
          due=${wake##*/}; every=${due#*-}; due=${due%%-*}
          case "$every" in *-*) every=${every#*-};; *) every=;; esac
          case "$due" in ''|*[!0-9]*) continue;; esac
          [ "$due" -le "$now" ] || continue
          # The bot's folder's tools (its browser) first: the engine connects them a moment
          # after it opens the folder, and a wake-up sent sooner goes without them.
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
          body="{\"id\":\"$id\",\"text\":\"$(json "[Wake-up] $(cat "$wake")")\",\"delivery\":\"queue\"}"
          url="http://127.0.0.1:$port/api/session/$session/prompt"
          sent=
          if command -v curl >/dev/null 2>&1; then
            curl -sf -m 20 -u "opencode:$password" -H 'Content-Type: application/json' --data-binary "$body" "$url" >/dev/null && sent=1
          elif command -v wget >/dev/null 2>&1; then
            auth=$(printf 'opencode:%s' "$password" | base64 | tr -d '\n')
            wget -q -T 20 -O /dev/null --header="Authorization: Basic $auth" --header='Content-Type: application/json' --post-data="$body" "$url" && sent=1
          fi
          # Sent: a repeating one comes back at its next time; others are done.
          if [ -n "$sent" ]; then
            if [ -n "$every" ] && repeats "$every"; then mv -f "$wake" "${bot}wakes/$(name "$(next "$due" "$every")" "$every")"; else rm -f "$wake"; fi
          fi
        done
      done
      exit 0
    fi

    bot=$1; command=$2
    case "$bot" in */*) ;; ?*) bot="${KUVO_BOTS:-$HOME/.kuvo-code/bots}/$bot" ;; esac
    if [ -z "$1" ] || [ ! -d "$bot" ]; then usage >&2; exit 2; fi
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
      list)
        found=
        for wake in "$bot"/wakes/*; do
          [ -f "$wake" ] || continue
          found=1; id=${wake##*/}
          every=${id#*-}; case "$every" in *-*) every=" (every ${every#*-})";; *) every=;; esac
          echo "$id  $(readable "${id%%-*}")$every  $(head -n 1 "$wake")"
        done
        [ -n "$found" ] || echo "No wake-ups scheduled." ;;
      cancel)
        [ -n "$3" ] && [ -f "$bot/wakes/$3" ] || { echo "No wake-up \"$3\". See kuvo-wake $1 list." >&2; exit 2; }
        rm -f "$bot/wakes/$3"; echo "Canceled $3." ;;
      *) usage ;;
    esac
    """#
}
