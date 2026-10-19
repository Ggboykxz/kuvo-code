// Kuvo Code's agents bridge: sessions with the coding agents you already have (Claude Code, Codex,
// Cursor, Grok, Antigravity), signed in as you, served to the app in the engine's own API.
//
// Started like the engine: it prints `{"url": …}` once it's listening, answers only with the
// password in OPENCODE_PASSWORD, and stops when its stdin closes (so it can't outlive the app).
// It keeps what it has in KUVO_AGENTS_HOME.

import { mkdirSync } from "node:fs"
import { join } from "node:path"
import { AntigravityAgent } from "./agents/antigravity"
import { ClaudeAgent } from "./agents/claude"
import { CodexAgent } from "./agents/codex"
import { CursorAgent } from "./agents/cursor"
import { GrokAgent } from "./agents/grok"
import { Deps } from "./deps"
import { handler } from "./server"
import { Sessions } from "./sessions"
import { Store } from "./store"

const version = "1"
const home = process.env.KUVO_AGENTS_HOME
const password = process.env.OPENCODE_PASSWORD
if (!home || !password) {
  console.error("KUVO_AGENTS_HOME and OPENCODE_PASSWORD are needed.")
  process.exit(2)
}
// Temporary files of its own and the agents' (Claude Code's task output): the app gives it a
// folder in its own temporary folder.
const temporary = process.env.TMPDIR?.replace(/\/$/, "") || join(home, "tmp")
mkdirSync(temporary, { recursive: true })

// An SDK's promise nobody waits for, rejected (Cursor's when a shell fails to start), stops nothing.
process.on("unhandledRejection", (reason) => console.error("unhandled:", reason))

const deps = new Deps(join(home, "runtime"), join(home, "cache"))
const context = { home, temporary, deps }
const agents = [new ClaudeAgent(context), new CodexAgent(context), new CursorAgent(context), new GrokAgent(context), new AntigravityAgent(context)]
const store = new Store(join(home, "sessions"))
const sessions = new Sessions(store, agents)

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  idleTimeout: 0,
  fetch: handler({ agents, sessions, password, version }),
})
console.log(JSON.stringify({ url: `http://127.0.0.1:${server.port}` }))

let stopping = false
function stop() {
  if (stopping) return
  stopping = true
  sessions.closeAll()
  store.flush()
  server.stop(true)
  process.exit(0)
}
process.stdin.on("end", stop)
process.stdin.on("close", stop)
process.stdin.resume()
process.on("SIGTERM", stop)
process.on("SIGINT", stop)
