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

    /// Run through `kuvo-npx`, pinned, and apart from the project (its .npmrc, bunfig.toml or
    /// .env), as integrations' packages are.
    private static func local(_ command: [String]) -> JSONValue {
        .object(["type": .string("local"), "command": .array(([Launcher.name] + command).map(JSONValue.string)),
                 "environment": .object([Integrations.apart: .string("1")])])
    }

    /// Servers that use this Mac's own apps (its Chrome), left out of machines' settings.
    static let macOnly = ["chrome-devtools"]

    /// One added as an older version offered it (unpinned, with the project's settings): as it's
    /// offered now, keeping anything else set on it.
    @MainActor static func upgrade(_ config: EngineConfig) {
        guard case .object(var server)? = config.value(at: MCPSettings.path + ["chrome-devtools"]),
              case .array(let command)? = server["command"], command.map(\.string) == [Launcher.name, "chrome-devtools-mcp@latest"],
              case .object(let offered)? = servers.first(where: { $0.id == "chrome-devtools" })?.settings else { return }
        server["command"] = offered["command"]
        var environment = server["environment"]?.object ?? [:]
        environment[Integrations.apart] = .string("1")
        server["environment"] = .object(environment)
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
        Server(id: "chrome-devtools", title: "Chrome DevTools", summary: "Inspect and debug pages in Google Chrome", access: .local, settings: local(["chrome-devtools-mcp@1.11.0"])),
    ]
}
