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
