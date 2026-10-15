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
        /// The file's name: the time it's due, in seconds, a dash and a few random letters.
        public let id: String
        public let due: Date
        public let note: String

        public init?(id: String, note: String) {
            guard let seconds = id.split(separator: "-").first.flatMap({ TimeInterval($0) }) else { return nil }
            self.id = id
            due = Date(timeIntervalSince1970: seconds)
            self.note = note
        }
    }

    /// A `kuvo-wake` command a bot ran, read back: what it did, and for `add`, when and the note.
    public struct Command: Sendable, Equatable {
        public enum Verb: String, Sendable { case add, list, cancel }
        public let verb: Verb
        /// As written: +2h, 2026-10-16T09:00, …
        public let when: String?
        public let note: String?
    }

    /// The command, if `line` runs `kuvo-wake` for a bot (by name, or by its full path).
    public static func command(in line: String) -> Command? {
        let pattern = #/kuvo-wake"?\s+(?:"[^"]*"|'[^']*'|\S+)\s+(add|list|cancel)\b\s*(.*)$/#
        guard let match = line.firstMatch(of: pattern), let verb = Command.Verb(rawValue: String(match.1)) else { return nil }
        guard verb == .add else { return Command(verb: verb, when: nil, note: nil) }
        let rest = match.2.trimmingCharacters(in: .whitespaces)
        let when = rest.prefix { !$0.isWhitespace }
        var note = rest.dropFirst(when.count).trimmingCharacters(in: .whitespaces)
        if let first = note.first, first == "\"" || first == "'", note.last == first, note.count >= 2 { note = String(note.dropFirst().dropLast()) }
        return Command(verb: verb, when: when.isEmpty ? nil : String(when), note: note.isEmpty ? nil : note)
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
    ///     kuvo-wake <bot> add <when> <note>    when: +30m, +2h, +1d, or 2026-10-16T09:00
    ///     kuvo-wake <bot> list
    ///     kuvo-wake <bot> cancel <id>
    ///     kuvo-wake fire <bots folder> <engine.json>   sends what's due (the watchdog, on a machine)
    public static let script = #"""
    #!/bin/sh
    # Kuvo Code's wake-ups for bots. See `kuvo-wake <bot> help`.
    now=$(date +%s)

    usage() {
      echo "Usage:"
      echo "  kuvo-wake <bot> add <when> <note>   when: +30m, +2h, +1d, or a time like 2026-10-16T09:00 on this computer's clock"
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
        session=$(cat "$bot/session" 2>/dev/null) || continue
        [ -n "$session" ] || continue
        for wake in "$bot"wakes/*; do
          [ -f "$wake" ] || continue
          due=${wake##*/}; due=${due%%-*}
          case "$due" in ''|*[!0-9]*) continue;; esac
          [ "$due" -le "$now" ] || continue
          ms=$(date +%s%3N 2>/dev/null); case "$ms" in *[!0-9]*|'') ms=$((now * 1000));; esac
          id=msg_$(printf '%012x' $(((ms * 4096 + 1) & 0xFFFFFFFFFFFF)))$(random 14)
          body="{\"id\":\"$id\",\"text\":\"$(json "[Wake-up] $(cat "$wake")")\",\"delivery\":\"queue\"}"
          url="http://127.0.0.1:$port/api/session/$session/prompt"
          if command -v curl >/dev/null 2>&1; then
            curl -sf -m 20 -u "opencode:$password" -H 'Content-Type: application/json' --data-binary "$body" "$url" >/dev/null && rm -f "$wake"
          elif command -v wget >/dev/null 2>&1; then
            auth=$(printf 'opencode:%s' "$password" | base64 | tr -d '\n')
            wget -q -T 20 -O /dev/null --header="Authorization: Basic $auth" --header='Content-Type: application/json' --post-data="$body" "$url" && rm -f "$wake"
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
        shift 3; note="$*"
        [ -n "$note" ] || { echo "Add a note for yourself: what to do when you wake up." >&2; exit 2; }
        [ "$due" -gt $((now + 30)) ] || { echo "That's not in the future. Wake-ups are for later; do it now instead." >&2; exit 2; }
        mkdir -p "$bot/wakes"
        count=$(ls "$bot/wakes" 2>/dev/null | wc -l)
        [ "$count" -lt 50 ] || { echo "You already have 50 wake-ups waiting. Cancel some first." >&2; exit 2; }
        id=$due-$(random 6)
        printf '%s' "$note" >"$bot/wakes/$id"
        echo "Scheduled $id for $(readable "$due")." ;;
      list)
        found=
        for wake in "$bot"/wakes/*; do
          [ -f "$wake" ] || continue
          found=1; id=${wake##*/}
          echo "$id  $(readable "${id%%-*}")  $(head -n 1 "$wake")"
        done
        [ -n "$found" ] || echo "No wake-ups scheduled." ;;
      cancel)
        [ -n "$3" ] && [ -f "$bot/wakes/$3" ] || { echo "No wake-up \"$3\". See kuvo-wake $1 list." >&2; exit 2; }
        rm -f "$bot/wakes/$3"; echo "Canceled $3." ;;
      *) usage ;;
    esac
    """#
}
