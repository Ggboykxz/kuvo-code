// The bridge on one of your machines (Linux, over SSH), beside the machine's engine: everything it
// and its agents keep is in Kuvo Code's folder there (`~/.kuvo-code/agents`), and the agents'
// programs are installed in it, at the versions this bridge was written for, rather than looked
// for on the machine. Nothing is installed for the machine as a whole, nothing goes in its home.

import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { brotliDecompressSync } from "node:zlib"
import type { Deps } from "./deps"

/** It runs on a machine, not on this Mac. */
export const onMachine = process.env.KUVO_AGENTS_REMOTE === "1"

/** The machine's Kuvo Code folder (`~/.kuvo-code`). */
export const machineHome = process.env.KUVO_HOME

/** The machine's engine, as its launch wrote it down (`run/engine.json`): its process, where it listens, its password. */
export function machineEngine(): { pid: number; url: string; password: string } | undefined {
  if (!machineHome) return undefined
  try {
    const record = JSON.parse(readFileSync(join(machineHome, "run", "engine.json"), "utf8"))
    if (typeof record.port !== "number" || typeof record.password !== "string") return undefined
    return { pid: record.pid, url: `http://127.0.0.1:${record.port}`, password: record.password }
  } catch {
    return undefined
  }
}

/** The machine's processor, as programs' packages name it. */
const arch = process.arch === "arm64" ? "arm64" : "x64"

/** Its C library is musl (Alpine): programs built for musl first. */
function musl(): boolean {
  try {
    return readdirSync("/lib").some((name) => name.startsWith("ld-musl"))
  } catch {
    return false
  }
}

/** The agents' programs installed on machines: the versions this bridge was written for. */
export const machineVersions = { codex: "0.163.0", grok: "1.0.62" }

/** What an agent's program on a machine says of updates: Kuvo Code keeps it with the bridge. */
export const managedNote = "Kuvo Code keeps it up to date on this machine."

/** Claude Code's own program, from the Claude Agent SDK's package for this machine (installed with it). */
export function claudeProgram(folder: string): string | undefined {
  const base = join(folder, "node_modules", "@anthropic-ai")
  const names = musl() ? [`claude-agent-sdk-linux-${arch}-musl`, `claude-agent-sdk-linux-${arch}`] : [`claude-agent-sdk-linux-${arch}`, `claude-agent-sdk-linux-${arch}-musl`]
  for (const name of names) {
    const path = join(base, name, "claude")
    if (existsSync(path)) return path
  }
  return undefined
}

const codexPackages = [{ name: "@openai/codex", version: machineVersions.codex }]

/** Codex's program, as its package for this machine has it (a static build, with its own sandbox helper). */
export function codexProgram(deps: Deps): string | undefined {
  if (!deps.has("codex", codexPackages)) return undefined
  const triple = arch === "arm64" ? "aarch64-unknown-linux-musl" : "x86_64-unknown-linux-musl"
  const path = join(deps.folder("codex"), "node_modules", "@openai", `codex-linux-${arch}`, "vendor", triple, "bin", "codex")
  return existsSync(path) ? path : undefined
}

export async function installCodex(deps: Deps): Promise<string> {
  await deps.ensure("codex", codexPackages)
  const path = codexProgram(deps)
  if (!path) throw new Error("OpenAI doesn't make Codex for this machine.")
  return path
}

const grokPackage = `@xai-official/grok-linux-${arch}`

/** Grok's CLI, unpacked from its package for this machine. */
export function grokProgram(deps: Deps): string | undefined {
  const path = join(deps.folder("grok"), "bin", "grok")
  try {
    return readFileSync(path + ".version", "utf8") === machineVersions.grok && existsSync(path) ? path : undefined
  } catch {
    return undefined
  }
}

export async function installGrok(deps: Deps): Promise<string> {
  const known = grokProgram(deps)
  if (known) return known
  await deps.ensure("grok", [{ name: grokPackage, version: machineVersions.grok }])
  // Its package keeps it compressed (its own installer unpacks it as npm installs it).
  const packed = join(deps.folder("grok"), "node_modules", grokPackage, "bin", "grok.br")
  if (!existsSync(packed)) throw new Error("xAI doesn't make Grok's CLI for this machine.")
  const path = join(deps.folder("grok"), "bin", "grok")
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path + ".new", brotliDecompressSync(readFileSync(packed)))
  chmodSync(path + ".new", 0o755)
  renameSync(path + ".new", path)
  writeFileSync(path + ".version", machineVersions.grok)
  return path
}
