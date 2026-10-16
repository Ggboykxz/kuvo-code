import Foundation

/// `kuvo-npx`, in the `bin` folder beside `kuvo-wake`: runs an npm package's command for an MCP
/// server (an integration's), with Node's npx when the computer has it, else the engine's own Bun
/// (`bun x`), so such a server needs nothing installed. What either downloads stays in the
/// engine's cache (`npm_config_cache`, `BUN_INSTALL`). The server gets its own keys under their
/// own names (its settings say which); every integration's `KUVO_KEY_…` is taken away first.
/// With Bun, a `node` beside it (in `runtime`) runs the engine's Bun too: a package's command
/// starts with `node`, and without one Bun makes its own in `/tmp`, whatever `TMPDIR` says.
public enum Launcher {
    public static let name = "kuvo-npx"
    /// The folder beside it with `node`.
    public static let runtime = "runtime"

    /// The script, running the engine at `engine` for Bun (a path, or a shell word like
    /// "$K/engine/2.0.30/opencode").
    public static func script(engine: String) -> String {
        """
        #!/bin/sh
        # Kuvo Code: runs an npm package's command for an MCP server.
        for v in $(env | sed 's/=.*//' | grep '^KUVO_KEY_'); do unset "$v" 2>/dev/null; done
        if command -v npx >/dev/null 2>&1; then exec npx -y "$@"; fi
        PATH="$(dirname "$0")/\(runtime):$PATH" BUN_BE_BUN=1 exec \(engine) x "$@"
        """
    }

    /// `node`, for a package's command: the engine's Bun.
    public static func node(engine: String) -> String {
        """
        #!/bin/sh
        # Kuvo Code: the engine's Bun, by Node's name, for an MCP server's command.
        BUN_BE_BUN=1 exec \(engine) "$@"
        """
    }

    /// Writes it into `folder` (this Mac's `bin`), for the engine at `engine`.
    public static func install(in folder: URL, engine: URL) throws {
        let quoted = "\"\(engine.path)\""
        try write(script(engine: quoted), to: folder.appending(path: name))
        try write(node(engine: quoted), to: folder.appending(path: runtime).appending(path: "node"))
    }

    private static func write(_ text: String, to file: URL) throws {
        let data = Data(text.utf8)
        if (try? Data(contentsOf: file)) == data { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    #if os(macOS)
    /// Puts it in `$K/bin` on a machine (needs `$K`), for its engine.
    static var installScript: String {
        let engine = "\"$HOME/\(RemoteEngineInstaller.root)/engine/\(OpenCodeEngine.version)/opencode\""
        return """
        cat >"$K/bin/\(name).new" <<'KUVO_NPX'
        \(script(engine: engine))
        KUVO_NPX
        chmod 755 "$K/bin/\(name).new" && mv -f "$K/bin/\(name).new" "$K/bin/\(name)"
        mkdir -p "$K/bin/\(runtime)"
        cat >"$K/bin/\(runtime)/node.new" <<'KUVO_NODE'
        \(node(engine: engine))
        KUVO_NODE
        chmod 755 "$K/bin/\(runtime)/node.new" && mv -f "$K/bin/\(runtime)/node.new" "$K/bin/\(runtime)/node"
        """
    }
    #endif
}
