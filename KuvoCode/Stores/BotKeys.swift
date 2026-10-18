import Foundation
import OpenCodeKit
import os

/// Keys a bot has of its own for integrations you bring a key for (a GitHub token of its own):
/// in your Keychain beside the shared ones, and used only in its conversation. Where it works, a
/// settings file of its folder's own, `.opencode/opencode.json`, names each such integration's
/// server with its keys over the shared ones, and no other bot's or session's settings name them.
/// A bot that works in a project shares that folder with your sessions there, so it uses the keys
/// they do.
@MainActor
enum BotKeys {
    private static let log = Logger(subsystem: "run.kuvo.code", category: "integrations")

    /// The integrations a bot can have keys of its own for: those you bring a key or token for.
    /// (One you sign in to through your app is the same sign-in everywhere.)
    static var services: [Integrations.Service] {
        Integrations.all.filter { service in
            switch service.way {
            case .officialToken: true
            case .package(_, let keys, _, _, _, let macOnly): !keys.isEmpty && !macOnly
            default: false
            }
        }
    }

    /// The integrations `bot` has every key of its own for, and those with a shared key. (The
    /// Keychain is read off the main thread: it can wait on you.)
    nonisolated static func status(of bot: String) async -> (own: Set<String>, shared: Set<String>) {
        let keyed = await MainActor.run { services.map { (id: $0.id, keys: Integrations.keys(of: $0.way).map(\.name)) } }
        return await Task.detached {
            var own: Set<String> = [], shared: Set<String> = []
            for service in keyed where !service.keys.isEmpty {
                if service.keys.allSatisfy({ IntegrationKeys.value(IntegrationKeys.variable(service.id, $0, bot: bot)) != nil }) { own.insert(service.id) }
                if service.keys.allSatisfy({ IntegrationKeys.value(IntegrationKeys.variable(service.id, $0)) != nil }) { shared.insert(service.id) }
            }
            return (own, shared)
        }.value
    }

    /// Saves `values` as `bot`'s own keys for `service` and puts them to use where it works;
    /// false if they couldn't be saved.
    static func save(_ values: [String: String], for service: Integrations.Service, bot: Bot, app: AppModel) async -> Bool {
        let variables = Integrations.keys(of: service.way).map { (IntegrationKeys.variable(service.id, $0.name, bot: bot.id), values[$0.name]?.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let saved = await Task.detached { variables.allSatisfy { IntegrationKeys.set($0.1, for: $0.0) } }.value
        guard saved else { return false }
        await apply(to: bot, app: app)
        return true
    }

    /// Takes away `bot`'s own keys for `service`: it uses the shared one again, if there is one.
    static func remove(_ service: Integrations.Service, bot: Bot, app: AppModel) async {
        let variables = Integrations.keys(of: service.way).map { IntegrationKeys.variable(service.id, $0.name, bot: bot.id) }
        await Task.detached { for variable in variables { IntegrationKeys.set(nil, for: variable) } }.value
        await apply(to: bot, app: app, removing: variables)
    }

    /// When it's deleted: its keys go from your Keychain, and from its machine, if it's on one
    /// that's connected (its folder, with its settings, goes with it).
    static func forget(_ bot: Bot, app: AppModel?) async {
        let variables = await Task.detached {
            let variables = IntegrationKeys.variables(ofBot: bot.id)
            for variable in variables { IntegrationKeys.set(nil, for: variable) }
            return variables
        }.value
        if let machine = bot.machine, !variables.isEmpty, let engine = app?.machines.engine(machine), engine.isReady {
            await send(variables.map { "DELETE=\($0)" }, to: engine, workspace: (bot.folder as NSString).appendingPathComponent("workspace"))
        }
    }

    /// As an engine starts (on `machine`, or this Mac's): each bot's there, in case its keys or the
    /// integrations' settings changed meanwhile. On this Mac, only bots with keys of their own or
    /// a folder's settings from before; on a machine, every bot there (keys taken away while it
    /// was away leave their settings there).
    static func applyAll(on machine: String?, app: AppModel) async {
        let names = await Task.detached { IntegrationKeys.names }.value
        for bot in app.bots.list where bot.machine == machine && bot.project == nil {
            let hasKeys = !IntegrationKeys.variables(ofBot: bot.id, in: names).isEmpty
            let hadSome = machine != nil || FileManager.default.fileExists(atPath: URL(filePath: bot.directory).appending(path: ".opencode/opencode.json").path)
            if hasKeys || hadSome { await apply(to: bot, app: app) }
        }
    }

    /// Writes its folder's settings where it works, naming a server for each integration it has
    /// its own keys for, or takes them away when it has none; on a machine, with its keys in
    /// their files there (see `RemoteServer.launchScript`). Each of those servers connects again
    /// in its folder. On a machine that isn't connected, this waits for it to be (`AppModel.start`).
    static func apply(to bot: Bot, app: AppModel, removing removed: [String] = []) async {
        guard bot.project == nil else { return }
        let (own, _) = await status(of: bot.id)
        let chosen = services.filter { own.contains($0.id) }
        var servers: [String: JSONValue] = [:]
        for service in chosen { servers[service.id] = Integrations.settings(for: service, bot: bot.id) }
        let touched = Set(chosen.map(\.id) + services.filter { service in removed.contains { $0.hasPrefix(IntegrationKeys.variable(service.id, "")) } }.map(\.id))
        if let machine = bot.machine {
            guard let engine = app.machines.engine(machine), engine.isReady else { return }
            let keys = await Task.detached { IntegrationKeys.variables(ofBot: bot.id).compactMap { name in IntegrationKeys.value(name).map { (name, $0) } } }.value
            var lines = keys.map { "\($0.0)=\($0.1)" }.filter { !$0.contains("\n") }
            lines += removed.map { "DELETE=\($0)" }
            if servers.isEmpty {
                lines.append("REMOVE=1")
            } else if let settings = settingsText(servers, keyVariables: true) {
                lines.append("SETTINGS=" + settings)
            }
            guard await send(lines, to: engine, workspace: (bot.folder as NSString).appendingPathComponent("workspace")) else { return }
            if let api = engine.api { for id in touched { try? await api.connectMCP(id, directory: bot.directory) } }
        } else {
            let folder = URL(filePath: bot.directory).appending(path: ".opencode")
            let file = folder.appending(path: "opencode.json")
            if servers.isEmpty {
                try? FileManager.default.removeItem(at: file)
                // The folder too, if it held only that.
                try? FileManager.default.removeItem(at: folder)
            } else if let text = settingsText(servers, keyVariables: false) {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
            }
            if let api = app.workspace.api(forFolder: bot.directory) { for id in touched { try? await api.connectMCP(id, directory: bot.directory) } }
        }
    }

    /// Its folder's settings: only the servers it has keys of its own for. Slashes as they are:
    /// the engine finds `{file:…}` in the text before it reads it.
    private static func settingsText(_ servers: [String: JSONValue], keyVariables: Bool) -> String? {
        let settings: JSONValue = .object(["mcp": .object(["servers": .object(servers)])])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(settings) else { return nil }
        if keyVariables, let object = try? JSONSerialization.jsonObject(with: data),
           let converted = try? JSONSerialization.data(withJSONObject: Integrations.keyVariables(in: object), options: [.sortedKeys, .withoutEscapingSlashes]) {
            data = converted
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Sends `lines` to `writeScript` on the machine; false if they didn't get there.
    @discardableResult
    private static func send(_ lines: [String], to engine: MachineEngine, workspace: String) async -> Bool {
        let input = FileManager.default.temporaryDirectory.appending(path: Bundle.main.bundleIdentifier ?? "run.kuvo.code").appending(path: "bot-keys-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: input.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Only you can read it, and it's gone as soon as ssh has sent it.
            FileManager.default.createFile(atPath: input.path, contents: Data((lines.joined(separator: "\n") + "\n\n").utf8), attributes: [.posixPermissions: 0o600])
            defer { try? FileManager.default.removeItem(at: input) }
            _ = try await engine.machine.connection.run(writeScript(workspace: workspace), input: input)
            return true
        } catch {
            log.error("A bot's keys didn't reach its machine: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// On its machine: its keys in their files, its folder's settings written (or taken away).
    private static func writeScript(workspace: String) -> String {
        """
        K="$HOME/\(RemoteEngineInstaller.root)"; W=\(SSHConnection.quoted(workspace))
        mkdir -p "$K/keys" && chmod 700 "$K/keys"
        while IFS= read -r line && [ -n "$line" ]; do
          name="${line%%=*}"; value="${line#*=}"
          case "$name" in
            KUVO_KEY_*) (umask 077; printf '%s' "$value" >"$K/keys/$name") ;;
            DELETE) rm -f "$K/keys/$value" ;;
            SETTINGS) mkdir -p "$W/.opencode" && chmod 700 "$W/.opencode" && (umask 077; printf '%s\\n' "$value" >"$W/.opencode/opencode.json") ;;
            REMOVE) rm -f "$W/.opencode/opencode.json"; rmdir "$W/.opencode" 2>/dev/null ;;
          esac
        done
        true
        """
    }
}
