// Kuvo Code's agents bridge: sessions with the coding agents you already have (Claude Code, Codex,
// Cursor, Grok, Antigravity), signed in as you, served to the app in the engine's own API.
//
// Started like the engine: it prints `{"url": …}` once it's listening, answers only with the
// password in OPENCODE_PASSWORD, and stops when its stdin closes (so it can't outlive the app).
// It keeps what it has in KUVO_AGENTS_HOME.

import { mkdirSync, readdirSync, rmSync } from "node:fs"
import { join } from "node:path"
import { Accounts, parseProvider } from "./accounts"
import { Auto } from "./auto"
import { Deps } from "./deps"
import { EngineAgent, EngineLink } from "./engine"
import { Snapshots } from "./snapshots"
import { Roster } from "./roster"
import { cancelSignIns, handler } from "./server"
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
// What an agent left unpacked when the bridge last stopped without cleaning up (Antigravity's
// agent unpacks itself, about 1 GB, for each run), and half-finished downloads.
rmSync(join(temporary, "antigravity"), { recursive: true, force: true })
try {
  for (const name of readdirSync(join(home, "antigravity"))) if (name.startsWith(".install-")) rmSync(join(home, "antigravity", name), { recursive: true, force: true })
} catch {}

// The engine's binary runs this as Bun when told to: the agents it starts aren't told so.
delete process.env.BUN_BE_BUN
// Nor do they get its password: every agent, and each command one runs, gets this environment,
// and an `env` there would print it, for the model to read and any process here to use.
delete process.env.OPENCODE_PASSWORD

// An SDK's promise nobody waits for, rejected (Cursor's when a shell fails to start), stops nothing.
process.on("unhandledRejection", (reason) => console.error("unhandled:", reason))

const deps = new Deps(join(home, "runtime"), join(home, "cache"))
const context = { home, temporary, deps }
const roster = new Roster(new Accounts(home), context)
const store = new Store(join(home, "sessions"))
const auto = new Auto(home)
// The engine's own models, run in sessions here (the app says where the engine is).
const link = new EngineLink()
const engineAgents = new Map<string, EngineAgent>()
function engineAgent(providerID: string): EngineAgent | undefined {
  if (!link.ready || parseProvider(providerID)) return undefined
  let agent = engineAgents.get(providerID)
  if (!agent) engineAgents.set(providerID, (agent = new EngineAgent(link, providerID)))
  return agent
}
const sessions = new Sessions(
  store,
  roster,
  auto,
  engineAgent,
  (directory) => link.policies(directory),
  (name, directory) => link.agentPrompt(name, directory),
  new Snapshots(join(home, "snapshots")),
)

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  idleTimeout: 0,
  fetch: handler({ roster, sessions, auto, link, password, version }),
})
console.log(JSON.stringify({ url: `http://127.0.0.1:${server.port}` }))

let stopping = false
function stop() {
  if (stopping) return
  stopping = true
  cancelSignIns()
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
