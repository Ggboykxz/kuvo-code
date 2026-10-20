import Foundation
import OpenCodeKit

/// Well-known MCP servers, each from the company behind it as listed in the official MCP
/// Registry (registry.modelcontextprotocol.io), to add in one click. Servers that need an
/// account sign in through the engine when they're first used.
nonisolated enum MCPCatalog {
    struct Server: Identifiable, Sendable {
        /// Its name in the engine's settings, which its tools are named after.
        var id: String
        var title: String
        var summary: String
        var access: Access
        /// The engine's settings for it.
        var settings: JSONValue
    }

    enum Access: Sendable {
        case signIn, open, local

        var title: String {
            switch self {
            case .signIn: "Needs an account"
            case .open: "No account needed"
            case .local: "Runs on this Mac"
            }
        }
    }

    private static func remote(_ url: String) -> JSONValue {
        .object(["type": .string("remote"), "url": .string(url)])
    }

    /// Run through `kuvo-npx`, pinned. In the project's folder, not apart from it: a file it's
    /// asked to save at a path (a screenshot) goes where the project is.
    private static func local(_ command: [String]) -> JSONValue {
        .object(["type": .string("local"), "command": .array(([Launcher.name] + command).map(JSONValue.string))])
    }

    /// Chrome DevTools' server, and how it's run: with a profile of its own for each copy, in the
    /// temporary folder and gone when it closes (not one in your home folder, which a second
    /// project's copy couldn't open).
    private static let chromeDevTools = ["chrome-devtools-mcp@1.11.0", "--isolated"]

    /// Servers that use this Mac's own apps (its Chrome), left out of machines' settings.
    static let macOnly = ["chrome-devtools"]

    /// Chrome DevTools as an older version added it (through npx, unpinned, another version): as
    /// it's offered now, with the options you gave it and anything else set on it.
    @MainActor static func upgrade(_ config: EngineConfig) {
        guard case .object(var server)? = config.value(at: MCPSettings.path + ["chrome-devtools"]),
              case .array(let old)? = server["command"] else { return }
        let words = old.compactMap(\.string)
        guard let at = words.firstIndex(where: { $0 == "chrome-devtools-mcp" || $0.hasPrefix("chrome-devtools-mcp@") }) else { return }
        let options = words[(at + 1)...].filter { !chromeDevTools.contains($0) }
        let command = [Launcher.name] + chromeDevTools + options
        var environment = server["environment"]?.object ?? [:]
        // Set by a build that ran it apart from the project.
        let wasApart = environment.removeValue(forKey: Integrations.apart) != nil
        guard command != words || wasApart else { return }
        server["command"] = .array(command.map(JSONValue.string))
        server["environment"] = environment.isEmpty ? nil : .object(environment)
        config.set(.object(server), at: MCPSettings.path + ["chrome-devtools"])
    }

    static let servers: [Server] = [
        Server(id: "linear", title: "Linear", summary: "Issues, projects and cycles", access: .signIn, settings: remote("https://mcp.linear.app/mcp")),
        Server(id: "sentry", title: "Sentry", summary: "Errors and performance problems in your apps", access: .signIn, settings: remote("https://mcp.sentry.dev/mcp")),
        Server(id: "notion", title: "Notion", summary: "Pages and databases in your workspace", access: .signIn, settings: remote("https://mcp.notion.com/mcp")),
        Server(id: "atlassian", title: "Atlassian", summary: "Jira issues and Confluence pages", access: .signIn, settings: remote("https://mcp.atlassian.com/v2/mcp")),
        Server(id: "stripe", title: "Stripe", summary: "Payments, customers and Stripe's docs", access: .signIn, settings: remote("https://mcp.stripe.com")),
        Server(id: "supabase", title: "Supabase", summary: "Databases, auth and storage in your projects", access: .signIn, settings: remote("https://mcp.supabase.com/mcp")),
        Server(id: "neon", title: "Neon", summary: "Postgres databases and branches", access: .signIn, settings: remote("https://mcp.neon.tech/mcp")),
        Server(id: "context7", title: "Context7", summary: "Current docs and examples for libraries", access: .open, settings: remote("https://mcp.context7.com/mcp")),
        Server(id: "cloudflare-docs", title: "Cloudflare Docs", summary: "Cloudflare's documentation", access: .open, settings: remote("https://docs.mcp.cloudflare.com/mcp")),
        Server(id: "huggingface", title: "Hugging Face", summary: "Models, datasets, Spaces and papers", access: .open, settings: remote("https://huggingface.co/mcp")),
        Server(id: "chrome-devtools", title: "Chrome DevTools", summary: "Inspect and debug pages in Google Chrome", access: .local, settings: local(chromeDevTools)),
    ]
}
