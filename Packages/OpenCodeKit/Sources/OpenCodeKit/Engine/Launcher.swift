import Foundation

/// `kuvo-npx`, in the `bin` folder beside `kuvo-wake`: runs an npm package's command for an MCP
/// server (an integration's), with Node's npx when the computer has it, else the engine's own Bun
/// (`bun x`), so such a server needs nothing installed. What either downloads stays in the
/// engine's cache (`npm_config_cache`, `BUN_INSTALL`).
public enum Launcher {
    public static let name = "kuvo-npx"

    /// The script, running the engine at `engine` for Bun (a path, or a shell word like
    /// "$K/engine/2.0.30/opencode").
    public static func script(engine: String) -> String {
        """
        #!/bin/sh
        # Kuvo Code: runs an npm package's command for an MCP server.
        if command -v npx >/dev/null 2>&1; then exec npx -y "$@"; fi
        BUN_BE_BUN=1 exec \(engine) x "$@"
        """
    }

    /// Writes it into `folder` (this Mac's `bin`), for the engine at `engine`.
    public static func install(in folder: URL, engine: URL) throws {
        let file = folder.appending(path: name)
        let data = Data(script(engine: "\"\(engine.path)\"").utf8)
        if (try? Data(contentsOf: file)) == data { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    /// Puts it in `$K/bin` on a machine (needs `$K`), for its engine.
    static var installScript: String {
        """
        cat >"$K/bin/\(name).new" <<'KUVO_NPX'
        \(script(engine: "\"$HOME/\(RemoteEngineInstaller.root)/engine/\(OpenCodeEngine.version)/opencode\""))
        KUVO_NPX
        chmod 755 "$K/bin/\(name).new" && mv -f "$K/bin/\(name).new" "$K/bin/\(name)"
        """
    }
}
