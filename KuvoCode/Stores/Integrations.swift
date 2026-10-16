import Foundation
import OpenCodeKit

/// Services the agent can work with: your mail and calendar, chats, socials, code and work tools.
/// Each one the best way it can: its maker's own MCP server where there is one (you sign in once);
/// else a well-kept open-source server with a key you bring, kept in your Keychain; else the site
/// itself, in the panel's browser, signed in as you. Added, an integration is an MCP server in the
/// engine's settings named by its ID, for every session and bot, on this Mac and its machines.
nonisolated enum Integrations {
    struct Service: Identifiable, Sendable {
        let id: String
        let title: String
        /// What the agent can do with it.
        let summary: String
        let kind: Kind
        let symbol: String
        /// Its site, for the browser, and where to sign in there.
        let site: String
        let way: Way
    }

    enum Kind: String, CaseIterable, Sendable {
        case mail = "Mail and Calendar"
        case chat = "Chat"
        case social = "Social"
        case work = "Code and Work"
    }

    enum Way: Sendable {
        /// Its maker's MCP server at `url`, where you sign in with your account the first time.
        case official(url: String)
        /// Its maker's server, with a token you bring, sent as `Authorization: Bearer`.
        case officialToken(url: String, key: Key, help: String)
        /// Its maker's server, which takes sign-ins only through an app registered with it: you
        /// bring your app's client ID and secret, then sign in.
        case officialApp(url: String, help: String)
        /// An open-source MCP server (an npm package, pinned to a version), run with `kuvo-npx`,
        /// with the keys you bring and settings of its own; `macOnly` for one that uses this Mac's
        /// apps.
        case package(command: [String], keys: [Key], help: String?, by: String, environment: [String: String] = [:], macOnly: Bool = false)
        /// No server worth trusting: the agent uses the site in the panel's browser, signed in as you.
        case browser
    }

    struct Key: Sendable {
        /// The environment variable the server reads (or, for an app, CLIENT_ID and CLIENT_SECRET).
        let name: String
        let label: String
        let prompt: String
    }

    /// Where the engine's own sign-in comes back for a server that signs in through your app.
    static let redirect = "http://127.0.0.1:19876/mcp/oauth/callback"

    /// The keys a service takes, if any.
    static func keys(of way: Way) -> [Key] {
        switch way {
        case .officialToken(_, let key, _): [key]
        case .officialApp: [Key(name: "CLIENT_ID", label: "Client ID", prompt: "From your app"), Key(name: "CLIENT_SECRET", label: "Client secret", prompt: "From your app")]
        case .package(_, let keys, _, _, _, _): keys
        case .official, .browser: []
        }
    }

    /// Its settings in the engine's file. Keys go in as `{env:…}` (their values reach the engine
    /// in memory, never the file).
    static func settings(for service: Service) -> JSONValue? {
        let env = { (name: String) in JSONValue.string("{env:\(IntegrationKeys.variable(service.id, name))}") }
        switch service.way {
        case .official(let url):
            return .object(["type": .string("remote"), "url": .string(url)])
        case .officialToken(let url, let key, _):
            return .object([
                "type": .string("remote"), "url": .string(url), "oauth": .bool(false),
                "headers": .object(["Authorization": .string("Bearer {env:\(IntegrationKeys.variable(service.id, key.name))}")]),
            ])
        case .officialApp(let url, _):
            return .object([
                "type": .string("remote"), "url": .string(url),
                "oauth": .object(["clientId": env("CLIENT_ID"), "clientSecret": env("CLIENT_SECRET")]),
            ])
        case .package(let command, let keys, _, _, let fixed, _):
            var environment = fixed.mapValues(JSONValue.string)
            for key in keys { environment[key.name] = env(key.name) }
            return .object([
                "type": .string("local"),
                "command": .array(([Launcher.name] + command).map(JSONValue.string)),
                "environment": .object(environment),
            ])
        case .browser:
            return nil
        }
    }

    /// Integrations that only work on this Mac, left out of machines' settings: those that use
    /// its apps. (Those you sign in to go too: the sign-in is copied, see `syncSignIns`.)
    static var macOnly: [String] {
        all.compactMap { service in
            if case .package(_, _, _, _, _, true) = service.way { return service.id }
            return nil
        }
    }

    static func service(_ id: String) -> Service? { all.first { $0.id == id } }

    /// Integrations whose servers keep their sign-in in files of their own, in their folder (see
    /// `AppModel.syncSignInFiles`), by the files' names.
    static let signInFiles: [String: [String]] = [
        "microsoft-365": ["token-cache.json", "selected-account.json"],
    ]

    // Checked 2026-10-16: the official servers with their makers' docs; the open-source ones on
    // npm, pinned. Keep them current with the other upstreams.
    static let all: [Service] = [
        // Mail and calendar
        Service(id: "apple-calendar", title: "Apple Calendar and Reminders", summary: "Events and reminders in your Mac's Calendar and Reminders, with every account you have there", kind: .mail, symbol: "calendar", site: "https://www.icloud.com/calendar",
                way: .package(command: ["mcp-server-apple-events@1.6.0"], keys: [], help: nil, by: "FradSer's mcp-server-apple-events", macOnly: true)),
        Service(id: "microsoft-365", title: "Outlook and Microsoft 365", summary: "Mail, calendar, contacts and files; you sign in with a code the first time", kind: .mail, symbol: "envelope", site: "https://outlook.live.com",
                way: .package(command: ["@softeria/ms-365-mcp-server@0.168.0"], keys: [], help: nil, by: "Softeria's ms-365-mcp-server", environment: [
                    // Its sign-in, chosen account and logs in a folder of its own, not the home folder or the keychain.
                    "MS365_MCP_TOKEN_CACHE_PATH": "{env:KUVO_INTEGRATIONS}/microsoft-365/token-cache.json",
                    "MS365_MCP_SELECTED_ACCOUNT_PATH": "{env:KUVO_INTEGRATIONS}/microsoft-365/selected-account.json",
                    "MS365_MCP_LOG_DIR": "{env:KUVO_INTEGRATIONS}/microsoft-365/logs",
                    "MS365_MCP_USE_KEYTAR": "0",
                ])),
        Service(id: "fastmail", title: "Fastmail", summary: "Mail, contacts and calendars", kind: .mail, symbol: "envelope.badge", site: "https://app.fastmail.com",
                way: .official(url: "https://api.fastmail.com/mcp")),
        Service(id: "caldav", title: "Other Calendars", summary: "iCloud, Nextcloud and other CalDAV calendars", kind: .mail, symbol: "calendar.badge.clock", site: "https://www.icloud.com/calendar",
                way: .package(command: ["caldav-mcp@0.10.0"], keys: [
                    Key(name: "CALDAV_BASE_URL", label: "Server", prompt: "https://caldav.icloud.com"),
                    Key(name: "CALDAV_USERNAME", label: "Username", prompt: "you@icloud.com"),
                    Key(name: "CALDAV_PASSWORD", label: "Password", prompt: "An app-specific password"),
                ], help: "https://support.apple.com/en-us/102654", by: "dominik1001's caldav-mcp")),
        Service(id: "gmail", title: "Gmail", summary: "Google's own server, in preview: with an app in your Google Cloud project", kind: .mail, symbol: "envelope.open", site: "https://mail.google.com",
                way: .officialApp(url: "https://gmailmcp.googleapis.com/mcp/v1", help: "https://developers.google.com/workspace/guides/configure-mcp-servers")),
        Service(id: "google-calendar", title: "Google Calendar", summary: "Google's own server, in preview: with an app in your Google Cloud project", kind: .mail, symbol: "calendar.circle", site: "https://calendar.google.com",
                way: .officialApp(url: "https://calendarmcp.googleapis.com/mcp/v1", help: "https://developers.google.com/workspace/guides/configure-mcp-servers")),
        // Chat
        Service(id: "slack", title: "Slack", summary: "Channels, messages and search, through an app you add to your workspace", kind: .chat, symbol: "number", site: "https://app.slack.com",
                way: .officialApp(url: "https://mcp.slack.com/mcp", help: "https://docs.slack.dev/ai/mcp-server/")),
        Service(id: "discord", title: "Discord", summary: "Your servers and messages", kind: .chat, symbol: "bubble.left.and.bubble.right", site: "https://discord.com/app", way: .browser),
        Service(id: "telegram", title: "Telegram", summary: "Your chats", kind: .chat, symbol: "paperplane", site: "https://web.telegram.org", way: .browser),
        Service(id: "whatsapp", title: "WhatsApp", summary: "Your chats", kind: .chat, symbol: "phone.bubble", site: "https://web.whatsapp.com", way: .browser),
        // Social
        Service(id: "x", title: "X", summary: "Posts, replies and messages", kind: .social, symbol: "at", site: "https://x.com", way: .browser),
        Service(id: "linkedin", title: "LinkedIn", summary: "Your feed, posts and messages", kind: .social, symbol: "person.2", site: "https://www.linkedin.com", way: .browser),
        Service(id: "reddit", title: "Reddit", summary: "Posts and comments", kind: .social, symbol: "text.bubble", site: "https://www.reddit.com", way: .browser),
        Service(id: "bluesky", title: "Bluesky", summary: "Posts and replies", kind: .social, symbol: "cloud", site: "https://bsky.app", way: .browser),
        Service(id: "mastodon", title: "Mastodon", summary: "Posts and replies", kind: .social, symbol: "megaphone", site: "https://mastodon.social", way: .browser),
        // Code and work
        Service(id: "github", title: "GitHub", summary: "Repositories, issues, pull requests and Actions", kind: .work, symbol: "chevron.left.forwardslash.chevron.right", site: "https://github.com",
                way: .officialToken(url: "https://api.githubcopilot.com/mcp/", key: Key(name: "TOKEN", label: "Personal access token", prompt: "github_pat_…"), help: "https://github.com/settings/personal-access-tokens/new")),
        Service(id: "gitlab", title: "GitLab", summary: "Projects, issues and merge requests", kind: .work, symbol: "arrow.triangle.branch", site: "https://gitlab.com",
                way: .official(url: "https://gitlab.com/api/v4/mcp")),
        Service(id: "linear", title: "Linear", summary: "Issues, projects and cycles", kind: .work, symbol: "checklist", site: "https://linear.app",
                way: .official(url: "https://mcp.linear.app/mcp")),
        Service(id: "notion", title: "Notion", summary: "Pages and databases", kind: .work, symbol: "doc.text", site: "https://www.notion.so",
                way: .official(url: "https://mcp.notion.com/mcp")),
        Service(id: "atlassian", title: "Jira and Confluence", summary: "Issues and pages at Atlassian", kind: .work, symbol: "square.stack.3d.up", site: "https://www.atlassian.com",
                way: .official(url: "https://mcp.atlassian.com/v2/mcp")),
        Service(id: "todoist", title: "Todoist", summary: "Tasks and projects", kind: .work, symbol: "checkmark.circle", site: "https://app.todoist.com",
                way: .package(command: ["@doist/todoist-mcp@13.5.0"], keys: [Key(name: "TODOIST_API_KEY", label: "API token", prompt: "From Settings › Integrations › Developer")], help: "https://app.todoist.com/app/settings/integrations/developer", by: "Doist's own todoist-mcp")),
        Service(id: "calendly", title: "Calendly", summary: "Your event types, bookings and availability", kind: .work, symbol: "calendar.badge.plus", site: "https://calendly.com/app",
                way: .official(url: "https://mcp.calendly.com")),
        Service(id: "figma", title: "Figma", summary: "Files and frames, to build designs from", kind: .work, symbol: "paintbrush", site: "https://www.figma.com",
                way: .package(command: ["figma-developer-mcp@0.13.2", "--stdio"], keys: [Key(name: "FIGMA_API_KEY", label: "Personal access token", prompt: "figd_…")], help: "https://help.figma.com/hc/en-us/articles/8085703771159", by: "GLips's Figma-Context-MCP")),
        Service(id: "asana", title: "Asana", summary: "Tasks and projects, through an app you register", kind: .work, symbol: "circle.grid.3x3", site: "https://app.asana.com",
                way: .officialApp(url: "https://mcp.asana.com/v2/mcp", help: "https://developers.asana.com/docs/using-asanas-mcp-server")),
        Service(id: "zoom", title: "Zoom", summary: "Meetings, recordings and chat, through an app you register", kind: .work, symbol: "video", site: "https://zoom.us/meeting",
                way: .officialApp(url: "https://mcp.zoom.us/mcp/zoom/streamable", help: "https://developers.zoom.us/docs/mcp/servers/connect-to-zoom-mcp-servers/")),
    ]
}
