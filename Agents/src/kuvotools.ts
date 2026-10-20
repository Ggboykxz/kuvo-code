// Kuvo Code's own tools (the side panel's browser, show_in_panel, messages to other agents), as
// the app serves them to the engine: an MCP server on this Mac, which the bridge gives each agent
// with the session it's for in a header, so what a tool asks goes to that conversation.

export interface ToolServer {
  url: string
  token: string
  /** How long a call may take, in milliseconds (one that asks you waits for you). */
  timeout: number
}

let server: ToolServer | undefined

export function setToolServer(value: ToolServer | undefined) {
  server = value
}

export const toolServerName = "kuvo-browser"

/** The server, as an agent reaches it for `sessionID`; none until the app says where it is. */
export function kuvoTools(sessionID: string): { name: string; url: string; headers: Record<string, string>; timeout: number } | undefined {
  if (!server) return undefined
  return { name: toolServerName, url: server.url, headers: { Authorization: `Bearer ${server.token}`, "X-Kuvo-Session": sessionID }, timeout: server.timeout }
}

/** Kuvo Code's tools as its server lists them: each one's name, and the arguments it takes. */
let schemas: { url: string; tools: Map<string, Set<string>> } | undefined
let loading: Promise<void> | undefined

/** Reads the server's list of tools (once per server), for telling its calls from an agent's own. */
export function loadKuvoTools(): Promise<void> {
  const at = server
  if (!at || schemas?.url === at.url) return Promise.resolve()
  loading ??= (async () => {
    try {
      const response = await fetch(at.url, {
        method: "POST",
        headers: { Authorization: `Bearer ${at.token}`, "Content-Type": "application/json", Accept: "application/json, text/event-stream" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }),
        signal: AbortSignal.timeout(5_000),
      })
      const answer: any = await response.json()
      const tools = new Map<string, Set<string>>()
      for (const tool of answer?.result?.tools ?? []) if (typeof tool?.name === "string") tools.set(tool.name, new Set(Object.keys(tool.inputSchema?.properties ?? {})))
      if (tools.size) schemas = { url: at.url, tools }
    } catch {}
  })().finally(() => (loading = undefined))
  return loading
}

/**
 * The app's name for a call of one of Kuvo Code's tools (`kuvo-browser_show_widget`), for an
 * agent that names it only as itself ("show_widget"): one it has by that name, called with
 * arguments it takes (an agent's own tool can share a name: Antigravity has a send_message).
 */
export function kuvoToolName(name: string, args: Record<string, unknown>): string | undefined {
  const known = schemas?.tools.get(name)
  if (!known) return undefined
  return Object.keys(args).every((key) => known.has(key)) ? `${toolServerName}_${name}` : undefined
}
