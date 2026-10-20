// Sessions with outside agents while the bridge runs: what's waiting to be sent, the turn under
// way, what it asks you, and the agents' own conversations behind each. A session can move from
// one agent to another (you pick a model of another, or Auto goes on with the next in your list):
// each agent keeps its own conversation, and gets what it hasn't seen as a handover.
//
// What's waiting goes as the engine sends it, which the app counts on: a message sent while
// nothing runs starts at once ("steer"), or waits for a nudge ("queue"); after a turn that ends
// on its own the next one starts; after Stop, or an error, nothing does until the app says.

import { createHash } from "node:crypto"
import { spawn as spawnProcess } from "node:child_process"
import { readFileSync, statSync } from "node:fs"
import { fileURLToPath } from "node:url"
import type { Agent, PermissionAsk, PromptFile, QuestionAsk, RunInput, RunResult, SubagentRun, SubagentTask, Thread, TurnHooks } from "./agent"
import { failure } from "./agent"
import { Auto, autoProvider, resetTime, type AutoEntry } from "./auto"
import { emit } from "./events"
import { handover, withHandover } from "./handover"
import { messageID, newID } from "./ids"
import type { Roster } from "./roster"
import { matches, ruled } from "./rules"
import type { Record_, Store } from "./store"
import { Turn, type Outcome } from "./turn"
import type { AssistantMessage, Attachment, Decision, FormAnswer, FormRequest, Message, ModelRef, PermissionRequest, PermissionRule, Session, ShellMessage, FileDiff } from "./wire"
import { plain } from "./proc"
import type { Snapshots } from "./snapshots"
import { noTokens } from "./wire"

type Delivery = "steer" | "queue"

interface Input {
  id: string
  text: string
  files: { uri: string; name?: string }[]
  delivery: Delivery
  /** From the app, not you ("you switched the model while it worked"): the agent gets it as a note. */
  synthetic?: { description?: string }
}

interface Live {
  /** Each agent's conversation in this session, by provider. */
  threads: Map<string, Thread>
  /** The one at work now, for Stop. */
  running?: { provider: string; thread: Thread; abandon: () => void }
  turn?: Turn
  abort?: AbortController
  /** Stopped with "resume": the next message you steered starts once it has. */
  resume?: boolean
  permissions: Map<string, { request: PermissionRequest; resolve: (decision: Decision) => void }>
  forms: Map<string, { form: FormRequest; resolve: (answer: FormAnswer | null) => void }>
  /** "Always allow" answers given in this session: an action, on these patterns. */
  always: { action: string; patterns: string[] }[]
  /** Closes its agents' processes once it has been idle a while. */
  idle?: ReturnType<typeof setTimeout>
  /** The slot of the agent that ran last in this turn: it sees the turn's end too. */
  last?: Slot
  /** Its subagents at work, each a session of its own: their turns, by session. */
  subagents: Map<string, Turn>
  /** Settings › Permissions' Blocks as the turn began: what nothing allows (undefined: not known). */
  blocks?: PermissionRule[]
  /** The session's agent of yours (Settings › Agents), as the turn began: what it's told to be. */
  agentPrompt?: string
  /** The session's agent's permissions as the engine has them (its defaults, Settings', the agent's own). */
  agentRules?: PermissionRule[]
  /** Which agent those are. */
  rulesFor?: string
}

/** What the bridge keeps of each agent's conversation in a session. */
interface Slot {
  /** The agent's own state (its conversation's ID, to resume it). */
  state: Record<string, unknown>
  /** The last message it has seen: what comes after goes to it as a handover. */
  seen?: string
}

/** What a session's `agent.json` held before sessions could move between agents. */
const legacyKeys = ["claudeSession", "claudeStarted", "codexThread", "acpSession", "acpInstructed", "cursorAgent", "cursorInstructed"]

/** What an agent that has your message already is told when it's to go on with it on another of its models. */
const carryOn = "Carry on with my last message from where you left off: you're on another model now."

/** How long an agent gets to stop when you press Stop, before its conversation is closed; how long a session's agents keep running with nothing to do (the next message starts them again, in the same conversation). */
export const timing = { stopGrace: 8_000, idleClose: 15 * 60_000 }

/** In plan mode, what changes files: refused, whatever your rules say. */
const changes = new Set(["edit", "write", "patch"])

/** How long a command you run with "!" may take, and how much of what it printed is kept. */
const shellTimeout = 10 * 60_000
const shellOutputLimit = 50_000

/**
 * A command you typed with "!", run through your shell in its own process group: what it printed
 * (its end, when there's a lot), kept as it comes; stopped whole when it runs too long. Its output
 * stops being waited for a moment after it ends (a job it left running may keep it open).
 */
function runCommand(command: string, directory: string): Promise<{ code: number; output: string; truncated: boolean; timedOut: boolean }> {
  return new Promise((resolve) => {
    let output = ""
    let truncated = false
    let timedOut = false
    let done = false
    const take = (chunk: Buffer) => {
      output += chunk.toString("utf8")
      if (output.length > shellOutputLimit * 2) {
        output = output.slice(-shellOutputLimit)
        truncated = true
      }
    }
    const finish = (code: number) => {
      if (done) return
      done = true
      clearTimeout(timer)
      const text = plain(output).trimEnd()
      resolve({ code, output: text.length > shellOutputLimit ? text.slice(-shellOutputLimit) : text, truncated: truncated || text.length > shellOutputLimit, timedOut })
    }
    let child: ReturnType<typeof spawnProcess>
    try {
      child = spawnProcess(process.env.SHELL || "/bin/zsh", ["-c", command], { cwd: directory, detached: true, stdio: ["ignore", "pipe", "pipe"] })
    } catch (error: any) {
      output = String(error?.message ?? error)
      return finish(1)
    }
    const group = (signal: NodeJS.Signals) => {
      try {
        if (child.pid) process.kill(-child.pid, signal)
      } catch {}
    }
    const timer = setTimeout(() => {
      timedOut = true
      group("SIGTERM")
      setTimeout(() => group("SIGKILL"), 5_000)
    }, shellTimeout)
    child.stdout?.on("data", take)
    child.stderr?.on("data", take)
    child.on("error", (error) => {
      output += String(error?.message ?? error)
      finish(1)
    })
    child.on("exit", (code, signal) => setTimeout(() => finish(code ?? (signal ? 128 + 15 : 1)), 500))
  })
}

/** What's kept of the project's files around one of your messages, for Undo. */
interface SnapshotNote {
  /** Before its turn. */
  before?: string
  /** The files its turn changed (the repository's paths), once it ended. */
  files?: string[]
  /** They couldn't be kept: Undo can't put them back. */
  failed?: boolean
}

/** What the engine asks first about whatever else you've set (reading a .env file), for when it can't say its own. */
const engineDefaults: PermissionRule[] = [
  { action: "read", resource: "*.env", effect: "ask" },
  { action: "read", resource: "*.env.*", effect: "ask" },
  { action: "read", resource: "*.env.example", effect: "allow" },
]

/**
 * A command line's commands, each checked on its own as the engine does (it checks every command
 * in the line: `a && b`, `a | b`, `a & b`, `a; b`, `$(b)`, `if a; then b; fi`, `{ b; }`), with
 * the whole line: a rule for one of them holds in any line. What's quoted stays in its command.
 */
export function commandParts(line: string): string[] {
  const whole = line.trim()
  const parts: string[] = []
  splitCommands(whole, parts)
  return [whole, ...new Set(parts.filter((part) => part !== whole))]
}

/** Words that open or close a block around commands, not commands themselves. */
const shellKeywords = new Set(["if", "then", "else", "elif", "do", "while", "until", "!", "time", "{", "}", "fi", "done", "esac"])

function splitCommands(text: string, out: string[]) {
  let current = ""
  const push = () => {
    const words = current.trim().split(/\s+/)
    while (words.length && shellKeywords.has(words[0])) words.shift()
    const part = words.join(" ")
    // A loop's or a case's own line: what runs is inside it.
    if (part && !/^(for|case|select|function)\s/.test(part)) out.push(part)
    current = ""
  }
  // A command inside this one ($(…), <(…), `…`): checked on its own, and kept in this one's text.
  const inner = (start: number, open: number): number => {
    const end = open === -1 ? backtickEnd(text, start) : parenEnd(text, start)
    splitCommands(text.slice(start, end), out)
    return end
  }
  let i = 0
  while (i < text.length) {
    const ch = text[i]
    if (ch === "\\") {
      current += text.slice(i, i + 2)
      i += 2
    } else if (ch === "'") {
      const end = text.indexOf("'", i + 1)
      const stop = end < 0 ? text.length : end + 1
      current += text.slice(i, stop)
      i = stop
    } else if (ch === '"') {
      let j = i + 1
      while (j < text.length && text[j] !== '"') {
        if (text[j] === "\\") j += 2
        else if (text.startsWith("$(", j)) j = inner(j + 2, 0) + 1
        else if (text[j] === "`") j = inner(j + 1, -1) + 1
        else j++
      }
      current += text.slice(i, j + 1)
      i = j + 1
    } else if (text.startsWith("$(", i) || text.startsWith("<(", i) || text.startsWith(">(", i)) {
      const end = inner(i + 2, 0)
      current += text.slice(i, end + 1)
      i = end + 1
    } else if (ch === "`") {
      const end = inner(i + 1, -1)
      current += text.slice(i, end + 1)
      i = end + 1
    } else if (ch === "<" && text.startsWith("<<", i) && text[i + 2] !== "<") {
      // A here-document: its lines are what it reads, not commands.
      const match = /^<<-?\s*(['"]?)([\w.-]+)\1/.exec(text.slice(i))
      if (!match) {
        current += "<<"
        i += 2
        continue
      }
      current += match[0]
      i += match[0].length
      const lineEnd = text.indexOf("\n", i)
      if (lineEnd < 0) continue
      current += text.slice(i, lineEnd)
      let at = lineEnd + 1
      let found = -1
      while (at <= text.length) {
        const next = text.indexOf("\n", at)
        const body = text.slice(at, next < 0 ? text.length : next)
        if (body.trim() === match[2]) {
          found = next < 0 ? text.length : next
          break
        }
        if (next < 0) break
        at = next + 1
      }
      i = found < 0 ? text.length : found
    } else if (ch === "&" && (text[i + 1] === ">" || /[<>]$/.test(current))) {
      // A redirection (2>&1, &>file), not a command of its own.
      current += ch
      i++
    } else if (ch === "|" && /[>]$/.test(current)) {
      current += ch
      i++
    } else if (ch === "&" || ch === "|" || ch === ";" || ch === "\n" || ch === "(" || ch === ")") {
      push()
      i += text[i + 1] === ch || (ch === "|" && text[i + 1] === "&") ? 2 : 1
    } else {
      current += ch
      i++
    }
  }
  push()
}

/** Where the `)` that closes what starts at `start` is (quotes and nesting followed), or the end. */
function parenEnd(text: string, start: number): number {
  let depth = 1
  let i = start
  while (i < text.length) {
    const ch = text[i]
    if (ch === "\\") i += 2
    else if (ch === "'") {
      const end = text.indexOf("'", i + 1)
      i = end < 0 ? text.length : end + 1
    } else if (ch === '"') {
      let j = i + 1
      while (j < text.length && text[j] !== '"') j += text[j] === "\\" ? 2 : 1
      i = j + 1
    } else if (ch === "(") {
      depth++
      i++
    } else if (ch === ")") {
      if (--depth === 0) return i
      i++
    } else i++
  }
  return text.length
}

function backtickEnd(text: string, start: number): number {
  let i = start
  while (i < text.length && text[i] !== "`") i += text[i] === "\\" ? 2 : 1
  return Math.min(i, text.length)
}

/** What an ask is about, a command line's commands one by one. */
function partsOf(ask: PermissionAsk): string[] {
  return isShell(ask.action) ? ask.resources.flatMap(commandParts) : ask.resources
}

function isShell(action: string): boolean {
  return action === "shell" || action === "bash"
}

/**
 * You allowed it before ("Always"): each of its resources is one you allowed as it is, or, for a
 * command line, each command in it is covered (a command allowed doesn't take others along).
 */
function coveredBy(patterns: string[], action: string, resources: string[]): boolean {
  return resources.every((resource) => {
    if (patterns.includes(resource)) return true
    if (!isShell(action)) return patterns.some((pattern) => matches(pattern, resource))
    const [, ...commands] = commandParts(resource)
    return (commands.length ? commands : [resource.trim()]).every((command) => patterns.some((pattern) => matches(pattern, command)))
  })
}

/** What the agents do on their own when nothing is to be approved: a rule about these holds them back. */
const agentActions = new Set(["*", "edit", "write", "patch", "shell", "bash", "read", "webfetch", "websearch", "external_directory"])

/** Actions that only look: asked about while Blocks aren't known only when a rule says so. */
const looks = new Set(["read", "glob", "grep", "list", "websearch", "todowrite", "todoread", "question"])

/** What rules say of each part (the last rule that matches it), the strictest of them: deny, then ask, then allow. */
export function strictest(rules: PermissionRule[], action: string, parts: string[]): "allow" | "deny" | "ask" | undefined {
  let result: "allow" | "ask" | undefined
  for (const part of parts.length ? parts : ["*"]) {
    const effect = ruled(rules, action, [part])
    if (effect === "deny") return "deny"
    if (effect === "ask") result = "ask"
    else if (effect === "allow" && !result) result = "allow"
  }
  return result
}

/** A step of the agent's that did something: wrote to you, or used a tool. */
function didWork(message: Message): boolean {
  return message.type === "assistant" && message.content.some((content) => content.type === "tool" || (content.type === "text" && content.text.trim() !== ""))
}

export class Sessions {
  private live = new Map<string, Live>()
  /** Sessions being deleted: nothing is taken or started for them any more. */
  private removing = new Set<string>()

  constructor(
    private readonly store: Store,
    private readonly roster: Roster,
    readonly auto: Auto,
    /** Runs a model of the engine's own providers in a session here (Auto's, or one you picked). */
    private readonly engine?: (providerID: string) => Agent | undefined,
    /** Settings › Permissions' Blocks for a folder, from the engine. */
    private readonly policies?: (directory: string) => Promise<PermissionRule[] | undefined>,
    /** The session's agent as the engine has it: what it's told, and its permissions. */
    private readonly agentInfo?: (name: string, directory: string) => Promise<{ system?: string; permissions?: PermissionRule[] } | undefined>,
    /** What the project's files were before each of your messages, for undo. */
    private readonly snapshots?: Snapshots,
  ) {
    // Turns a quit or crash cut short: ended, as Stop ends one.
    for (const session of store.all()) this.repair(session.id)
  }

  /** The agent that runs a provider's models: an outside agent's account, or the engine. */
  agent(providerID: string | undefined): Agent | undefined {
    if (!providerID || providerID === autoProvider) return undefined
    return this.roster.find(providerID) ?? this.engine?.(providerID)
  }

  private runs(providerID: string | undefined): boolean {
    if (providerID === autoProvider) return this.auto.list().length > 0
    return Boolean(this.agent(providerID))
  }

  private state(id: string): Live {
    let live = this.live.get(id)
    if (!live) {
      // Blocks aren't known until the engine says (none, without an engine to ask).
      live = { threads: new Map(), permissions: new Map(), forms: new Map(), always: [], subagents: new Map(), blocks: this.policies ? undefined : [] }
      this.live.set(id, live)
    }
    return live
  }

  private record(id: string) {
    const record = this.store.get(id)
    if (!record) throw new NotFound(`No session ${id}.`)
    return record
  }

  private isRunning(id: string) {
    const turn = this.live.get(id)?.turn
    return Boolean(turn && !turn.isEnded) || this.busy.has(id)
  }

  /** Sessions whose files are being kept or put back: a message waits for that as for a turn. */
  private busy = new Set<string>()

  /** What's kept of the project's files around each of your messages, by message. */
  private notes(record: Record_): Record<string, SnapshotNote> {
    const kept = (record.agent.snapshots as Record<string, SnapshotNote | string> | undefined) ?? {}
    // From before notes were kept whole: a tree alone, its turn's files not known.
    for (const [id, value] of Object.entries(kept)) if (typeof value === "string") kept[id] = { before: value, failed: true }
    record.agent.snapshots = kept
    return kept as Record<string, SnapshotNote>
  }

  /** What's waiting to be sent, kept with the session (it outlasts the bridge). */
  private queue(record: Record_): Input[] {
    let queue = record.agent.inbox as Input[] | undefined
    if (!Array.isArray(queue)) record.agent.inbox = queue = []
    return queue
  }

  /** Each agent's slot in a session, made from the single agent's state of before if need be. */
  private slots(record: Record_): Record<string, Slot> {
    let slots = record.agent.threads as Record<string, Slot> | undefined
    if (!slots) {
      slots = {}
      const legacy = Object.fromEntries(legacyKeys.filter((key) => key in record.agent).map((key) => [key, record.agent[key]]))
      // Its one agent wrote its replies (the session's model may have moved since).
      const provider = record.messages.findLast((message): message is AssistantMessage => message.type === "assistant")?.model.providerID ?? record.session.model?.providerID
      if (Object.keys(legacy).length && provider && provider !== autoProvider) {
        // It has seen the whole conversation so far.
        slots[provider] = { state: legacy, seen: record.messages[record.messages.length - 1]?.id }
      }
      for (const key of legacyKeys) delete record.agent[key]
      record.agent.threads = slots
    }
    return slots
  }

  /** A turn the bridge stopped in the middle of (it quit): its steps and tools closed, and its end marked. */
  private repair(id: string) {
    const record = this.store.get(id)
    if (!record) return
    let changed = false
    // A turn starts with your message, or with a note from the app (a mid-turn model switch).
    const lastUser = record.messages.findLastIndex((message) => message.type === "user" || message.type === "synthetic")
    for (const message of record.messages) {
      // A command of yours the bridge stopped with: over.
      if (message.type === "shell" && message.status === "running") {
        message.status = "failed"
        message.time.completed = message.time.created
        changed = true
      }
      if (message.type !== "assistant") continue
      if (!message.time.completed) {
        message.time.completed = message.time.streamed ?? message.time.created
        changed = true
      }
      for (const content of message.content) {
        if (content.type !== "tool" || (content.state.status !== "running" && content.state.status !== "streaming")) continue
        const input = content.state.status === "streaming" ? {} : content.state.input
        const metadata = content.state.status === "running" ? content.state.metadata : undefined
        content.state = { status: "error", input, error: { type: "aborted", message: "Stopped." }, content: [], metadata }
        changed = true
      }
    }
    // A subagent's session can start without a message of yours (its task given elsewhere).
    const lastStep = record.messages.findLastIndex((message) => message.type === "assistant")
    const openStep = record.session.parentID && lastStep > lastUser && !record.messages.slice(lastStep).some((message) => message.type === "idle")
    if ((lastUser >= 0 && !record.messages.slice(lastUser).some((message) => message.type === "idle")) || openStep) {
      const last = record.messages[record.messages.length - 1]
      const at = last?.time.completed ?? last?.time.created ?? Date.now()
      record.messages.push({ type: "idle", id: newID("msg"), time: { created: at }, outcome: "interrupted" })
      record.session.outcome = "interrupted"
      record.session.time.idle = at
      changed = true
    }
    if (changed) this.store.save(id, true)
  }

  // MARK: Sessions

  create(body: { title?: string; agent?: string; model?: ModelRef; location: { directory: string }; permissions?: PermissionRule[] }): Session {
    if (body.model?.providerID === autoProvider && !this.auto.list().length) throw new BadRequest("Your Auto list is empty: add models to it in Settings › Auto.")
    if (!body.model?.id || !this.runs(body.model.providerID)) throw new BadRequest("Pick a model of an agent you've connected.")
    const now = Date.now()
    const directory = body.location.directory
    const session: Session = {
      id: newID("ses"),
      projectID: "prj_" + createHash("sha1").update(directory).digest("hex").slice(0, 16),
      agent: typeof body.agent === "string" && body.agent ? body.agent : "build",
      model: body.model,
      cost: 0,
      tokens: noTokens(),
      time: { created: now, updated: now },
      title: body.title,
      location: { directory },
      permissions: body.permissions,
      metadata: { kuvoAgent: this.kind(body.model.providerID) },
    }
    this.store.add(session)
    emit("session.created", { sessionID: session.id, session }, directory)
    return session
  }

  /** What a session's metadata says runs it: an agent (`claude`…), `auto`, or `engine`. */
  private kind(providerID: string): string {
    if (providerID === autoProvider) return autoProvider
    return this.agent(providerID)?.id ?? "engine"
  }

  /**
   * A new session with this one's conversation before `before` (a message of yours), to try
   * another way from there. The agents' own conversations can't be copied: whichever runs it
   * gets what came before as a handover.
   */
  /**
   * A conversation from the engine, carried on here (you picked a coding agent's model in it): a
   * session with its messages, whose agents are handed all of it as they first run.
   */
  importSession(body: { title?: string; agent?: string; model?: ModelRef; location: { directory: string }; permissions?: PermissionRule[]; messages?: unknown[] }): Session {
    const session = this.create(body)
    const record = this.store.get(session.id)!
    const known = new Set(["user", "assistant", "synthetic", "system", "idle", "model-switched", "agent-switched", "shell"])
    record.messages = (Array.isArray(body.messages) ? body.messages : []).filter(
      (message): message is Message => typeof message === "object" && message !== null && known.has((message as any).type) && typeof (message as any).id === "string",
    )
    // Its last turn is over (a run left open there isn't one here).
    this.repair(session.id)
    session.title = body.title ?? session.title
    session.time.updated = Date.now()
    this.store.save(session.id, true)
    emit("session.updated", { sessionID: session.id, session }, session.location.directory)
    return session
  }

  fork(id: string, before: string): Session {
    const record = this.record(id)
    const at = record.messages.findIndex((message) => message.id === before)
    if (at < 0) throw new NotFound("That message isn't in this session.")
    const now = Date.now()
    const source = record.session
    const session: Session = {
      id: newID("ses"),
      projectID: source.projectID,
      agent: source.agent,
      model: source.model,
      cost: 0,
      tokens: noTokens(),
      time: { created: now, updated: now },
      title: source.title,
      location: { ...source.location },
      permissions: source.permissions,
      metadata: { ...source.metadata },
    }
    this.store.add(session)
    const copy = this.store.get(session.id)!
    copy.messages = structuredClone(record.messages.slice(0, at))
    if (record.agent.kuvoInstructions) copy.agent.kuvoInstructions = structuredClone(record.agent.kuvoInstructions)
    if (Array.isArray(record.agent.autoHeld)) copy.agent.autoHeld = [...(record.agent.autoHeld as string[])]
    this.store.save(session.id, true)
    emit("session.created", { sessionID: session.id, session }, session.location.directory)
    return session
  }

  /** Sessions, newest first: in a folder, and under a session (`parentID`; "null" for those under none). */
  list(directory?: string, parentID?: string | null): Session[] {
    return this.store
      .all()
      .filter((session) => !directory || session.location.directory === directory)
      .filter((session) => parentID === undefined || (parentID === null ? !session.parentID : session.parentID === parentID))
      .sort((a, b) => b.time.updated - a.time.updated || (a.id < b.id ? 1 : -1))
  }

  get(id: string): Session {
    return this.record(id).session
  }

  /** Its conversation, oldest first, with the turn under way as far as it's got. */
  messages(id: string): Message[] {
    return this.record(id).messages
  }

  update(id: string, body: { title?: string; permissions?: PermissionRule[]; metadata?: Record<string, unknown> }) {
    const record = this.record(id)
    const session = record.session
    const directory = session.location.directory
    if (body.title !== undefined) {
      session.title = body.title
      emit("session.renamed", { sessionID: id, title: body.title }, directory)
    }
    if (body.permissions !== undefined) session.permissions = body.permissions
    if (body.metadata !== undefined) {
      // The bridge's own note stays, whatever the app writes.
      session.metadata = { ...body.metadata, kuvoAgent: session.metadata?.kuvoAgent }
      emit("session.metadata.updated", { sessionID: id }, directory)
    }
    session.time.updated = Date.now()
    this.store.save(id, true)
  }

  async remove(id: string) {
    const record = this.store.get(id)
    if (!record || this.removing.has(id)) return
    // Nothing waiting starts as it stops, nor does anything sent meanwhile.
    this.removing.add(id)
    record.agent.inbox = []
    await this.interrupt(id)
    // Its subagents' sessions go with it, unless a fork of it shows them too.
    for (const child of this.list(undefined, id)) if (!this.shownElsewhere(child.id, id)) await this.remove(child.id)
    for (const thread of this.live.get(id)?.threads.values() ?? []) thread.close()
    this.live.delete(id)
    for (const [provider, slot] of Object.entries(this.slots(record))) await this.agent(provider)?.forgetConversation?.(slot.state).catch(() => {})
    this.store.remove(id)
    this.live.delete(id)
    this.removing.delete(id)
    emit("session.deleted", { sessionID: id }, record.session.location.directory)
  }

  /** Whether a session other than `except` has a step that names `child` (a fork of its conversation). */
  private shownElsewhere(child: string, except: string): boolean {
    for (const session of this.store.all()) {
      if (session.id === except || session.id === child) continue
      const record = this.store.get(session.id)
      if (record?.messages.some((message) => message.type === "assistant" && message.content.some((content) => content.type === "tool" && (content.state as any).metadata?.sessionID === child))) return true
    }
    return false
  }

  view(id: string, idle: number) {
    const session = this.record(id).session
    session.time.viewed = Math.max(idle, session.time.viewed ?? 0)
    this.store.save(id)
  }

  active(): string[] {
    const ids = [...this.live.keys()].filter((id) => this.isRunning(id))
    for (const live of this.live.values()) for (const [child, turn] of live.subagents) if (!turn.isEnded) ids.push(child)
    return ids
  }

  /**
   * A command you typed with "!", run in the session's folder as you, right away, without waking
   * the agent: it and what it printed join the conversation, and the agent gets them with your
   * next message.
   */
  runShell(id: string, command: string) {
    const record = this.record(id)
    if (record.session.parentID) throw new BadRequest("This subagent works for the conversation that started it: run it there.")
    const text = command.trim()
    if (!text) throw new BadRequest("Type a command after the !.")
    const directory = record.session.location.directory
    const shellID = newID("shl")
    // Named after its event, as the app names it from the event.
    const event = emit("session.shell.started", { sessionID: id, shell: { id: shellID, command: text, status: "running" } }, directory)
    const message: ShellMessage = { type: "shell", id: messageID(event.id), time: { created: event.created }, shellID, command: text, status: "running" }
    record.messages.push(message)
    record.session.time.updated = Date.now()
    // Run while an agent works: it hasn't seen it when its turn ends, and gets it with your next message.
    if (this.isRunning(id)) record.agent.lateShells = [...((record.agent.lateShells as string[] | undefined) ?? []), message.id]
    this.store.save(id, true)
    void runCommand(text, directory).then((ran) => {
      message.status = ran.code === 0 && !ran.timedOut ? "completed" : "failed"
      message.exit = ran.code
      message.output = { output: ran.timedOut ? `${ran.output}\n(Stopped: it ran past ${shellTimeout / 60_000} minutes.)`.trim() : ran.output, truncated: ran.truncated }
      message.time.completed = Date.now()
      if (!this.store.get(id)) return
      this.store.save(id, true)
      emit("session.shell.ended", { sessionID: id, shell: { id: shellID, command: text, status: message.status, exit: ran.code }, output: message.output }, directory)
    })
  }

  // MARK: Undo

  /**
   * Takes the conversation back to before your message `messageID`, and the files the agents
   * changed since; the next message makes it final, `clearRevert` brings it all back.
   */
  async stageRevert(id: string, messageID: string): Promise<NonNullable<Session["revert"]>> {
    const record = this.record(id)
    if (this.isRunning(id)) throw new BadRequest("Stop the agent first.")
    const at = record.messages.findIndex((message) => message.id === messageID && message.type === "user")
    if (at < 0) throw new NotFound("No such message of yours.")
    const directory = record.session.location.directory
    const notes = this.notes(record)
    // What the turns from it on changed, as the engine's undo puts back: only those files (your
    // own edits elsewhere, and other sessions', stay).
    const files = new Set<string>()
    let kept = false
    for (const message of record.messages.slice(at)) {
      const note = message.type === "user" ? notes[message.id] : undefined
      if (!note) continue
      kept = true
      if (note.failed || !note.before || !note.files) throw new BadRequest("Kuvo Code couldn't keep what the files were around one of these messages, so Undo can't put them back.")
      for (const path of note.files) files.add(path)
    }
    const first = notes[messageID]
    // A message taken partway through a turn (steered) has no files of its own.
    if (kept && !first?.before) throw new BadRequest("This message went into the turn before it: undo from that one.")
    let diffs: FileDiff[] = []
    if (first?.before && files.size && this.snapshots) {
      this.busy.add(id)
      try {
        const now = await this.snapshots.take(directory)
        if (!now) throw new Error("Kuvo Code couldn't keep the files as they are now.")
        // As they were before any undo, and which: what Redo brings back (kept before a file is touched).
        record.agent.revertNow ??= now
        record.agent.revertFiles = [...new Set([...((record.agent.revertFiles as string[] | undefined) ?? []), ...files])]
        this.store.save(id)
        diffs = await this.snapshots.changes(directory, first.before, now, [...files])
        await this.snapshots.restore(directory, first.before, [...files])
      } finally {
        this.busy.delete(id)
      }
    }
    const revert = { messageID, files: diffs }
    record.session.revert = revert
    this.store.save(id, true)
    emit("session.revert.staged", { sessionID: id, revert }, directory)
    this.next(id, "succeeded")
    return revert
  }

  /** Takes an undo back: the conversation and the files, as they were. */
  async clearRevert(id: string) {
    const record = this.record(id)
    if (!record.session.revert) return
    if (this.isRunning(id)) throw new BadRequest("Stop the agent first.")
    const directory = record.session.location.directory
    const now = record.agent.revertNow as string | undefined
    const files = (record.agent.revertFiles as string[] | undefined) ?? []
    if (now && files.length && this.snapshots) {
      this.busy.add(id)
      try {
        // Kept until it has worked: a Redo that failed can be tried again.
        await this.snapshots.restore(directory, now, files)
      } finally {
        this.busy.delete(id)
      }
    }
    delete record.session.revert
    delete record.agent.revertNow
    delete record.agent.revertFiles
    this.store.save(id, true)
    emit("session.revert.cleared", { sessionID: id }, directory)
    this.next(id, "succeeded")
  }

  /** An undo made final: what was taken back goes, and the agents start their conversations over, handed what's left. */
  private commitRevert(id: string, record: Record_, live: Live) {
    const revert = record.session.revert
    if (!revert) return
    const at = record.messages.findIndex((message) => message.id === revert.messageID)
    if (at >= 0) {
      const gone = record.messages.splice(at)
      const kept = this.notes(record)
      for (const message of gone) delete kept[message.id]
    }
    delete record.session.revert
    delete record.agent.revertNow
    delete record.agent.revertFiles
    // Their own conversations still hold what was undone: let go of (an engine model's hidden
    // session too), and started over.
    for (const thread of live.threads.values()) thread.close()
    live.threads.clear()
    for (const [provider, slot] of Object.entries(this.slots(record))) void this.agent(provider)?.forgetConversation?.(slot.state).catch(() => {})
    record.agent.threads = {}
    this.store.save(id, true)
    emit("session.revert.committed", { sessionID: id, to: revert.messageID }, record.session.location.directory)
  }

  setInstruction(id: string, key: string, text: string | undefined) {
    const record = this.record(id)
    const entries = (record.agent.kuvoInstructions as Record<string, string> | undefined) ?? {}
    if (text === undefined) delete entries[key]
    else entries[key] = text
    record.agent.kuvoInstructions = entries
    this.store.save(id, true)
  }

  // MARK: Model and mode

  /** Another model, of this agent or another (Auto too): the next message goes to it, with what it hasn't seen. */
  selectModel(id: string, model: ModelRef) {
    const record = this.record(id)
    const session = record.session
    const previous = session.model
    if (!model?.providerID || !model.id) throw new BadRequest("That isn't a model.")
    if (model.providerID === autoProvider && !this.auto.list().length) throw new BadRequest("Your Auto list is empty: add models to it in Settings › Auto.")
    if (!this.runs(model.providerID)) throw new BadRequest("That model's agent isn't connected.")
    if (previous && previous.providerID === model.providerID && previous.id === model.id && previous.variant === model.variant) return
    // What the session's agent kept, moved to its own slot while it's still the session's.
    this.slots(record)
    session.model = model
    session.metadata = { ...session.metadata, kuvoAgent: this.kind(model.providerID) }
    const event = emit("session.model.selected", { sessionID: id, model, previous }, session.location.directory)
    record.messages.push({ type: "model-switched", id: messageID(event.id), time: { created: event.created }, model, previous })
    this.store.save(id, true)
  }

  selectAgent(id: string, agent: string) {
    const record = this.record(id)
    const session = record.session
    const mode = typeof agent === "string" && agent ? agent : "build"
    const previous = session.agent
    if (previous === mode) return
    session.agent = mode
    const event = emit("session.agent.selected", { sessionID: id, agent: mode, previous }, session.location.directory)
    record.messages.push({ type: "agent-switched", id: messageID(event.id), time: { created: event.created }, agent: mode, previous })
    this.store.save(id, true)
  }

  // MARK: Messages

  inbox(id: string) {
    return this.queue(this.record(id)).map((input) => ({
      id: input.id,
      sessionID: id,
      type: input.synthetic ? "synthetic" : "user",
      payload: input.synthetic ? { text: input.text, description: input.synthetic.description } : { text: input.text, files: input.files },
      delivery: input.delivery,
    }))
  }

  /** A note from the app for the agent, next in line (the app sends one, then Stop with resume, to switch models mid-turn). */
  synthetic(id: string, text: string, description?: string) {
    const record = this.record(id)
    const input: Input = { id: newID("msg"), text, files: [], delivery: "steer", synthetic: { description } }
    this.queue(record).push(input)
    this.store.save(id, true)
    emit("session.inbox.enqueued", { sessionID: id, inboxID: input.id, item: { type: "synthetic", payload: { text, description }, delivery: "steer" } }, record.session.location.directory)
    this.wake(id)
  }

  prompt(id: string, input: Input) {
    if (this.removing.has(id)) throw new NotFound(`No session ${id}.`)
    const record = this.record(id)
    if (record.session.parentID) throw new BadRequest("This subagent works for the conversation that started it: write to it there.")
    const queue = this.queue(record)
    // Sent twice (a retry after a timeout): once is enough.
    if (queue.some((waiting) => waiting.id === input.id) || record.messages.some((message) => message.id === input.id)) return
    // While a turn runs, it waits for it, unless the agent at work takes it partway (Codex does).
    const running = this.live.get(id)?.running
    const steers = this.isRunning(id) && input.delivery !== "queue" && Boolean(running?.thread.steer)
    const delivery: Delivery = steers || (!this.isRunning(id) && input.delivery !== "queue") ? "steer" : "queue"
    queue.push({ ...input, delivery })
    this.store.save(id, true)
    emit("session.inbox.enqueued", { sessionID: id, inboxID: input.id, item: { type: "user", payload: { text: input.text, files: input.files }, delivery } }, record.session.location.directory)
    if (steers) void this.steerNow(id, input)
    else if (delivery === "steer") this.wake(id)
  }

  /** A message of yours into the turn under way, at its next step; it waits for the turn when it can't go. */
  private async steerNow(id: string, input: Input) {
    const running = this.live.get(id)?.running
    const taken = running?.thread.steer ? await running.thread.steer({ text: input.text, files: input.files.map(promptFile) }).catch(() => false) : false
    const record = this.store.get(id)
    if (!record) return
    const queue = this.queue(record)
    const at = queue.findIndex((waiting) => waiting.id === input.id)
    // Cancelled, or sent, meanwhile.
    if (at < 0) return
    if (!taken || !this.isRunning(id)) {
      if (this.isRunning(id)) this.setDelivery(id, input.id, "queue")
      else this.wake(id)
      return
    }
    queue.splice(at, 1)
    const directory = record.session.location.directory
    emit("session.inbox.delivered", { sessionID: id, inboxID: input.id }, directory)
    const attachments: Attachment[] = input.files.map((file) => ({ mime: mime(file.uri), name: file.name, source: { type: "uri", uri: file.uri } }))
    record.messages.push({ type: "user", id: input.id, time: { created: Date.now() }, text: input.text, files: attachments.length ? attachments : undefined })
    record.session.time.updated = Date.now()
    this.store.save(id, true)
  }

  /** Steer (it goes next, and now if nothing runs) or queue (it waits its turn) a waiting message. */
  setDelivery(id: string, inputID: string, delivery: Delivery) {
    const record = this.record(id)
    const input = this.queue(record).find((waiting) => waiting.id === inputID)
    if (!input) throw new NotFound("That message was sent already.")
    if (delivery !== "steer" && delivery !== "queue") throw new BadRequest("Steer or queue.")
    if (input.delivery !== delivery) {
      input.delivery = delivery
      this.store.save(id, true)
      emit("session.inbox.delivery.changed", { sessionID: id, inboxID: inputID, delivery }, record.session.location.directory)
    }
    if (delivery === "steer") this.wake(id)
  }

  cancelInput(id: string, inputID: string) {
    const record = this.store.get(id)
    if (!record) return
    const queue = this.queue(record)
    const index = queue.findIndex((input) => input.id === inputID)
    if (index < 0) return
    queue.splice(index, 1)
    this.store.save(id, true)
    emit("session.inbox.cancelled", { sessionID: id, inboxID: inputID }, record.session.location.directory)
  }

  /** Starts the first message you steered, if nothing runs. */
  private wake(id: string) {
    if (this.isRunning(id) || this.removing.has(id)) return
    const record = this.store.get(id)
    if (!record) return
    const queue = this.queue(record)
    const index = queue.findIndex((input) => input.delivery === "steer")
    if (index < 0) return
    const [input] = queue.splice(index, 1)
    void this.start(id, input)
  }

  /** After a turn: the next message, if it ended on its own (or you stopped it to send one now). */
  private next(id: string, outcome: Outcome) {
    if (this.removing.has(id) || !this.store.get(id)) return
    const live = this.state(id)
    const resume = live.resume
    live.resume = false
    const record = this.store.get(id)
    if (!record || this.isRunning(id)) return
    const queue = this.queue(record)
    let index = -1
    if (outcome === "succeeded") {
      index = queue.findIndex((input) => input.delivery === "steer")
      if (index < 0) index = queue.length ? 0 : -1
    } else if (resume) {
      index = queue.findIndex((input) => input.delivery === "steer")
    }
    if (index < 0) return
    const [input] = queue.splice(index, 1)
    void this.start(id, input)
  }

  /** Runs one message: on its model, or down your Auto list. */
  private async start(id: string, input: Input): Promise<void> {
    const live = this.state(id)
    const record = this.store.get(id)
    if (!record) return
    const session = record.session
    const directory = session.location.directory
    const model = session.model!
    // Marked as running before anything else can come in.
    const turn = new Turn(this.store, id, directory, model, session.agent ?? "build")
    live.turn = turn
    clearTimeout(live.idle)
    const abort = new AbortController()
    live.abort = abort
    emit("session.inbox.delivered", { sessionID: id, inboxID: input.id }, directory)
    // A message after an undo makes it final.
    this.commitRevert(id, record, live)
    const attachments: Attachment[] = input.files.map((file) => ({ mime: mime(file.uri), name: file.name, source: { type: "uri", uri: file.uri } }))
    if (input.synthetic) record.messages.push({ type: "synthetic", id: input.id, time: { created: Date.now() }, text: input.text, description: input.synthetic.description })
    else record.messages.push({ type: "user", id: input.id, time: { created: Date.now() }, text: input.text, files: attachments.length ? attachments : undefined })
    session.time.updated = Date.now()
    this.store.save(id, true)
    // The project's files as they are before it (yours, not a note from the app), and after its
    // turn: what the turn changed, which Undo puts back.
    let note: SnapshotNote | undefined
    if (!input.synthetic && this.snapshots) {
      try {
        const before = await this.snapshots.take(directory)
        if (before) note = { before }
      } catch {
        note = { failed: true }
      }
      if (note) {
        const kept = this.notes(record)
        kept[input.id] = note
        // The last hundred messages' are enough.
        const ids = Object.keys(kept).sort()
        for (const old of ids.slice(0, Math.max(0, ids.length - 100))) delete kept[old]
        this.store.save(id)
      }
    }
    // Blocks as they are now (once the message is in: one sent again meanwhile is known), and
    // what an agent of yours is told to be.
    const blocks = this.policies ? await this.policies(directory).catch(() => undefined) : []
    if (blocks !== undefined) live.blocks = blocks
    const agentName = session.agent ?? "build"
    const info = this.agentInfo ? await this.agentInfo(agentName, directory).catch(() => undefined) : undefined
    // Not known now: the rules kept stand only for the same agent (another's would be wrong).
    if (info?.permissions) live.agentRules = info.permissions
    else if (live.rulesFor !== agentName) live.agentRules = undefined
    live.rulesFor = agentName
    const own = session.agent && session.agent !== "build" && session.agent !== "plan" ? session.agent : undefined
    live.agentPrompt = own ? info?.system : undefined

    let result: RunResult
    try {
      // A text file you attached goes in the message, as the engine puts it (the agent reads the rest).
      const attached = withTextFiles(input.text, input.files.map(promptFile))
      const run: RunInput = { text: attached.text, files: attached.files, model, plan: session.agent === "plan" }
      // A message on a model you picked: what Auto held back before isn't news when it's back on.
      if (model.providerID !== autoProvider) delete record.agent.autoHeld
      result =
        model.providerID === autoProvider
          ? await this.runAuto(id, record, live, { ...run, auto: true }, turn, abort.signal, input.id)
          : await this.runOn(id, record, live, model, run, turn, abort.signal, input.id)
    } catch (error) {
      result = { outcome: "failed", error: failure(error) }
    }
    const outcome: Outcome = abort.signal.aborted ? "interrupted" : result.outcome
    const before = record.messages[record.messages.length - 1]?.id
    turn.finish(outcome, outcome === "interrupted" ? undefined : result.error)
    // Subagents still at work end with it.
    for (const child of [...live.subagents.values()]) child.finish(outcome === "failed" ? "interrupted" : outcome)
    live.subagents.clear()
    // The agent that ended the turn knows how it ended: that's not news to hand it later.
    if (live.last && live.last.seen === before) live.last.seen = record.messages[record.messages.length - 1]?.id
    live.last = undefined
    this.settleAsks(id, live)
    live.running = undefined
    if (live.turn === turn) live.turn = undefined
    // What the turn changed (the session waits for it, as for its turn).
    if (note?.before && this.snapshots) {
      this.busy.add(id)
      try {
        const after = await this.snapshots.take(directory)
        if (after) note.files = await this.snapshots.changed(directory, note.before, after)
      } catch {
        note.failed = true
      } finally {
        this.busy.delete(id)
      }
      if (this.store.get(id)) this.store.save(id)
    }
    this.next(id, outcome)
    if (!this.isRunning(id)) this.closeWhenIdle(id, live)
  }

  /** A while after its last turn, a session's agents stop running: they go on where they left off next time. */
  private closeWhenIdle(id: string, live: Live) {
    clearTimeout(live.idle)
    live.idle = setTimeout(() => {
      if (this.isRunning(id) || this.live.get(id) !== live) return
      for (const thread of live.threads.values()) thread.close()
      live.threads.clear()
    }, timing.idleClose)
  }

  /** The message on one agent's model, with what that agent hasn't seen of the conversation. */
  private async runOn(id: string, record: Record_, live: Live, model: ModelRef, input: RunInput, turn: Turn, signal: AbortSignal, userMessage: string): Promise<RunResult> {
    const agent = this.agent(model.providerID)
    if (!agent) return { outcome: "failed", error: { type: "agent", message: "This model's agent isn't available: sign in to it in Settings › Accounts, or pick another model." } }
    if (signal.aborted) return { outcome: "interrupted" }
    const slots = this.slots(record)
    const slot = (slots[model.providerID] ??= { state: {} })
    let thread = live.threads.get(model.providerID)
    if (!thread) {
      thread = agent.thread(record.session, slot.state)
      live.threads.set(model.providerID, thread)
    }
    const hooks = this.hooks(id, live, turn, signal, slot, input.plan)
    turn.setModel(model)
    // Given up on (it didn't stop when asked): the turn ends without it.
    let abandon!: () => void
    const abandoned = new Promise<RunResult>((resolve) => (abandon = () => resolve({ outcome: "interrupted" })))
    const running = { provider: model.providerID, thread, abandon }
    live.running = running
    const from = record.messages.length
    try {
      // Its conversation, ready (Stop gives up on it as on a run): one it had that couldn't be
      // picked up again starts over, and is handed all that came before.
      if (thread.prepare) {
        const prepared = await Promise.race([thread.prepare({ ...input, model }, hooks), abandoned.then(() => "abandoned" as const)])
        if (prepared === "abandoned") return { outcome: "interrupted" }
        if (prepared?.fresh) slot.seen = undefined
      }
      if (signal.aborted) return { outcome: "interrupted" }
      // What it hasn't seen: what came before your message since it last ran here, and what
      // another agent did on this message before handing it over.
      const at = record.messages.findIndex((message) => message.id === userMessage)
      const seenAt = slot.seen ? record.messages.findIndex((message) => message.id === slot.seen) : -1
      // It has your message already (Auto went on with another of its models): it carries on from
      // what it hasn't seen since, rather than getting the message again.
      const hasMessage = at >= 0 && seenAt >= at
      // Commands you ran while it (or another) worked come along, though it was there for them.
      const late = new Set((record.agent.lateShells as string[] | undefined) ?? [])
      const before = hasMessage ? [] : record.messages.slice(0, at < 0 ? undefined : at).filter((message, index) => index > seenAt || late.has(message.id))
      if (!hasMessage && late.size) delete record.agent.lateShells
      const partway = at < 0 ? [] : record.messages.slice(Math.max(at, seenAt) + 1)
      const handed = handover(before, partway, (message) => this.stepName(message))
      const text = withHandover(hasMessage ? carryOn : input.text, handed)
      const files = hasMessage ? [] : input.files
      const result = await Promise.race([thread.run({ ...input, model, text, files }, turn, hooks), abandoned])
      // It has seen all of it now, its own replies too; but one that failed with nothing done
      // couldn't take your message (its model is gone, it was turned away), and doesn't count as
      // having it: the next time, it or another model of its agent gets it.
      if (result.outcome !== "failed" || result.taken || record.messages.slice(from).some(didWork)) slot.seen = record.messages[record.messages.length - 1]?.id
      live.last = slot
      return result
    } catch (error) {
      // A broken conversation starts over with the next message (the agent's own may resume, and
      // what it missed goes to it as a handover).
      thread.close()
      if (live.threads.get(model.providerID) === thread) live.threads.delete(model.providerID)
      throw error
    } finally {
      if (live.running === running) live.running = undefined
      this.store.save(id, true)
    }
  }

  /** The message on the first model of your Auto list that isn't at a limit, and on down it while they reach theirs. */
  private async runAuto(id: string, record: Record_, live: Live, input: RunInput, turn: Turn, signal: AbortSignal, userMessage: string): Promise<RunResult> {
    // Held back at a limit when this session's last message on Auto ended: one that runs this
    // one is back (its limit reset), and the session says so.
    const heldBefore = new Set(Array.isArray(record.agent.autoHeld) ? (record.agent.autoHeld as string[]) : [])
    try {
      return await this.runAutoList(id, record, live, input, turn, signal, userMessage, heldBefore)
    } finally {
      record.agent.autoHeld = this.auto
        .list()
        .filter((entry) => this.auto.isHeld(entry))
        .map((entry) => Auto.modelKey(entry))
      this.store.save(id)
    }
  }

  private async runAutoList(id: string, record: Record_, live: Live, input: RunInput, turn: Turn, signal: AbortSignal, userMessage: string, heldBefore: Set<string>): Promise<RunResult> {
    const tried = new Set<string>()
    let last: RunResult | undefined
    let note: string | undefined
    for (;;) {
      if (signal.aborted) return { outcome: "interrupted" }
      const entry = await this.nextEntry(tried)
      if (signal.aborted) return { outcome: "interrupted" }
      if (!entry) {
        if (note) turn.notice(note)
        if (last?.limit) return { outcome: "failed", error: { type: "limit", message: `Every model in your Auto list is at a usage limit for now${this.nextReset()}.` } }
        return last ?? { outcome: "failed", error: { type: "limit", message: `No model in your Auto list can run now: each is at a limit, or its agent isn't signed in${this.nextReset()}. Edit the list in Settings › Auto.` } }
      }
      if (!tried.size && heldBefore.has(Auto.modelKey(entry))) turn.notice(`Back on ${this.entryName(entry)}: its limit has reset.`)
      tried.add(Auto.modelKey(entry))
      const model: ModelRef = { providerID: entry.providerID, id: entry.modelID, ...(entry.variant ? { variant: entry.variant } : {}) }
      if (note) {
        turn.stopTools("Stopped: going on with another model.")
        for (const child of live.subagents.values()) child.finish("interrupted")
        live.subagents.clear()
        turn.notice(`${note} Going on with ${this.entryName(entry)}.`)
      }
      const from = record.messages.length
      try {
        last = await this.runOn(id, record, live, model, input, turn, signal, userMessage)
      } catch (error) {
        // It couldn't start (its process, its sign-in): as a model that couldn't take it.
        if (signal.aborted || record.messages.slice(from).some(didWork)) throw error
        last = { outcome: "failed", error: failure(error) }
      }
      if (last.outcome !== "failed" || signal.aborted) return last
      if (!last.limit) {
        // It couldn't take the message at all (its model is gone, its sign-in ended): the next
        // one does, as nothing was done. Once it had done something, the error stands: going
        // on with another could do it twice.
        if (record.messages.slice(from).some(didWork)) return last
        note = `${this.entryName(entry)} couldn't take it: ${last.error?.message ?? "it stopped with an error"}`
        continue
      }
      this.auto.hold(entry, last.limit)
      emit("kuvo.auto.updated", {})
      const whole = last.limit.scope === "provider"
      note = `${this.entryName(entry, whole)} reached ${whole ? "its usage limit" : "this model's limit"}${last.limit.resetsAt ? ` (it resets at ${resetTime(last.limit.resetsAt)})` : ""}.`
    }
  }

  /** The first entry of your list not at a limit, not tried for this message, and signed in. */
  private async nextEntry(tried: Set<string>): Promise<AutoEntry | undefined> {
    for (const entry of this.auto.list()) {
      if (tried.has(Auto.modelKey(entry)) || this.auto.isHeld(entry)) continue
      const agent = this.agent(entry.providerID)
      if (!agent) continue
      // Signed out: skipped (an agent slow to say is tried anyway).
      const account = await Promise.race([agent.account().catch(() => undefined), Bun.sleep(10_000).then(() => undefined)])
      if (account && !account.signedIn) continue
      // A model the engine doesn't offer now (its provider was disconnected): skipped.
      if (agent.id === "engine") {
        const models = await agent.models().catch(() => [])
        if (models.length && !models.some((model) => model.id === entry.modelID)) continue
      }
      return entry
    }
    return undefined
  }

  private nextReset(): string {
    const known = this.auto.limits().filter((limit) => limit.known).map((limit) => limit.until)
    return known.length ? `; the first resets at ${resetTime(Math.min(...known))}` : ""
  }

  /** "Claude Code (opus, high)", or the agent alone. */
  private entryName(entry: AutoEntry, agentOnly = false): string {
    const name = this.agent(entry.providerID)?.name ?? entry.providerID
    return agentOnly ? name : `${name} (${entry.modelID}${entry.variant ? `, ${entry.variant}` : ""})`
  }

  /** Who wrote a step, for a handover: the agent and model. */
  private stepName(message: AssistantMessage): string {
    const agent = this.agent(message.model.providerID)
    return `${agent?.name ?? message.model.providerID}, ${message.model.id}`
  }

  /**
   * Stops the turn under way. With `resume`, the message you steered goes next (Send Now);
   * without, nothing waiting starts until the app says. Idle, `resume` starts it at once.
   */
  async interrupt(id: string, resume = false) {
    const live = this.live.get(id)
    if (!live?.turn || live.turn.isEnded) {
      if (resume) this.wake(id)
      return false
    }
    const turn = live.turn
    live.resume = resume
    live.abort?.abort()
    this.settleAsks(id, live)
    const running = live.running
    // An agent that doesn't stop: its conversation is closed, and the turn ends without it.
    setTimeout(() => {
      if (turn.isEnded || !running || live.running !== running) return
      running.thread.close()
      if (live.threads.get(running.provider) === running.thread) live.threads.delete(running.provider)
      running.abandon()
    }, timing.stopGrace)
    await running?.thread.interrupt().catch(() => {})
    return true
  }

  /** Whatever's still asked of you goes once the turn is over. */
  private settleAsks(id: string, live: Live) {
    const directory = this.store.get(id)?.session.location.directory
    for (const [requestID, pending] of live.permissions) {
      pending.resolve("reject")
      emit("permission.replied", { sessionID: id, requestID }, directory)
    }
    live.permissions.clear()
    for (const [formID, pending] of live.forms) {
      pending.resolve(null)
      emit("form.cancelled", { id: formID, sessionID: id }, directory)
    }
    live.forms.clear()
  }

  // MARK: What the agent asks

  private hooks(id: string, live: Live, turn: Turn, signal: AbortSignal, slot: Slot, plan: boolean): TurnHooks {
    const record = this.record(id)
    return {
      signal,
      state: slot.state,
      saveState: () => this.store.save(id, true),
      instructions: (withAgent = true) =>
        [
          ...Object.values((record.agent.kuvoInstructions as Record<string, string> | undefined) ?? {}),
          withAgent && live.agentPrompt ? `You work as the "${record.session.agent}" agent here. Its instructions:\n\n${live.agentPrompt}` : "",
        ]
          .filter(Boolean)
          .join("\n\n"),
      // Nothing to ask, and nothing refused: an agent may run its tools on its own. With a
      // rule or a block that refuses something (or Blocks not known), or in plan mode, it asks
      // here, and they answer.
      // An agent that can't ask (Cursor) still keeps to known Blocks; only ones not known yet
      // don't hold it back.
      approvesAll: (canAsk = true) => {
        if (plan) return false
        if ((record.session.permissions ?? []).some((rule) => rule.effect === "ask" || rule.effect === "deny")) return false
        const isDefault = (rule: PermissionRule) => engineDefaults.some((other) => other.action === rule.action && other.resource === rule.resource && other.effect === rule.effect)
        if ((live.agentRules ?? []).some((rule) => rule.effect !== "allow" && agentActions.has(rule.action) && !isDefault(rule))) return false
        if (live.blocks === undefined) return !canAsk
        return !live.blocks.some((rule) => rule.effect === "deny")
      },
      check: (ask, ownPlan) => this.checkPermission(live, record.session, ask, plan && !ownPlan),
      permission: (ask) => this.askPermission(id, live, turn, ask, plan),
      question: (ask) => this.askQuestion(id, live, turn, ask),
      subagent: (toolCallID, task) => this.startSubagent(id, live, turn, toolCallID, task),
    }
  }

  /** A subagent's session under `id`, for its tool call there: what it's told, and its turn. */
  private startSubagent(id: string, live: Live, parentTurn: Turn, toolCallID: string, task: SubagentTask): SubagentRun {
    const parent = this.record(id).session
    const directory = parent.location.directory
    const now = Date.now()
    const model = parentTurn.currentModel
    const before = task.sessionID ? this.store.get(task.sessionID) : undefined
    if (before && before.session.parentID === id) {
      // The same subagent, given more to do: its session goes on.
      if (task.prompt) before.messages.push({ type: "user", id: newID("msg"), time: { created: now }, text: task.prompt })
      before.session.time.updated = now
      this.store.save(before.session.id, true)
      return this.subagentRun(live, parentTurn, toolCallID, before.session)
    }
    const session: Session = {
      id: newID("ses"),
      parentID: id,
      projectID: parent.projectID,
      agent: task.agent ?? parent.agent,
      model,
      cost: 0,
      tokens: noTokens(),
      time: { created: now, updated: now },
      title: task.title || "A subagent's task",
      location: { directory },
      metadata: { kuvoAgent: parent.metadata?.kuvoAgent, kuvoSubagent: true },
    }
    this.store.add(session)
    const record = this.store.get(session.id)!
    if (task.prompt) record.messages.push({ type: "user", id: newID("msg"), time: { created: now }, text: task.prompt })
    this.store.save(session.id, true)
    emit("session.created", { sessionID: session.id, session }, directory)
    return this.subagentRun(live, parentTurn, toolCallID, session)
  }

  private subagentRun(live: Live, parentTurn: Turn, toolCallID: string, session: Session): SubagentRun {
    live.subagents.get(session.id)?.finish("succeeded")
    const turn = new Turn(this.store, session.id, session.location.directory, parentTurn.currentModel, session.agent ?? "build")
    live.subagents.set(session.id, turn)
    // Its step in the conversation that started it says which session it is.
    parentTurn.toolProgress(toolCallID, { sessionID: session.id })
    return {
      sessionID: session.id,
      turn,
      end: (outcome, error) => {
        turn.finish(outcome, error)
        if (live.subagents.get(session.id) === turn) live.subagents.delete(session.id)
      },
    }
  }

  /** What Blocks and rules say of an action without asking you: refused, or to ask first. */
  private checkPermission(live: Live, session: Session, ask: PermissionAsk, plan: boolean): "deny" | "ask" | undefined {
    const parts = partsOf(ask)
    if (live.blocks && strictest(live.blocks, ask.action, parts) === "deny") return "deny"
    if (plan && changes.has(ask.action)) return "deny"
    const effect = strictest([...(live.agentRules ?? engineDefaults), ...(session.permissions ?? [])], ask.action, parts)
    if (effect === "deny") return "deny"
    // Blocks not known (the engine didn't answer): asked, which reads them again.
    if (live.blocks === undefined && !looks.has(ask.action)) return "ask"
    return effect === "ask" && !this.allowedBefore(live, ask) ? "ask" : undefined
  }

  private allowedBefore(live: Live, ask: PermissionAsk): boolean {
    return live.always.some((rule) => rule.action === ask.action && coveredBy(rule.patterns, ask.action, ask.resources))
  }

  private async askPermission(id: string, live: Live, turn: Turn, ask: PermissionAsk, plan: boolean): Promise<Decision> {
    const session = this.record(id).session
    const parts = partsOf(ask)
    // Blocks not known yet (the engine was slow, or restarting): read again, and asked about if
    // they still aren't.
    if (live.blocks === undefined && this.policies) {
      const blocks = await this.policies(session.location.directory).catch(() => undefined)
      if (blocks !== undefined) live.blocks = blocks
    }
    const unknown = live.blocks === undefined && !looks.has(ask.action)
    // Blocks win over everything, approvals included; each command of a command line counts.
    if (live.blocks && strictest(live.blocks, ask.action, parts) === "deny") return "reject"
    if (plan && changes.has(ask.action)) return "reject"
    // The engine's asks were weighed by it already: without a rule of yours, they're yours to
    // answer. Others go by the session's agent's permissions as the engine has them (its own
    // defaults, reading a .env file asks first), with the session's rules over them.
    const effect = ask.weighed
      ? strictest(session.permissions ?? [], ask.action, parts)
      : (strictest([...(live.agentRules ?? engineDefaults), ...(session.permissions ?? [])], ask.action, parts) ?? "allow")
    if (effect === "deny") return "reject"
    if (!unknown && (effect === "allow" || this.allowedBefore(live, ask))) return "once"
    if (turn.isEnded || live.abort?.signal.aborted) return "reject"
    const request: PermissionRequest = {
      id: newID("per"),
      sessionID: id,
      action: ask.action,
      resources: ask.resources,
      save: ask.save ?? ask.resources,
      metadata: ask.metadata,
      message: ask.message,
    }
    const step = ask.toolCallID ? turn.toolStep(ask.toolCallID) : undefined
    if (ask.toolCallID && step) request.source = { type: "tool", messageID: step, id: ask.toolCallID }
    return new Promise<Decision>((resolve) => {
      live.permissions.set(request.id, {
        request,
        resolve: (decision) => {
          if (decision === "always") live.always.push({ action: ask.action, patterns: request.save ?? ask.resources })
          resolve(decision)
        },
      })
      emit("permission.asked", request as unknown as Record<string, unknown>, session.location.directory)
    })
  }

  permissions(id: string): PermissionRequest[] {
    this.record(id)
    return [...(this.live.get(id)?.permissions.values() ?? [])].map((pending) => pending.request)
  }

  replyPermission(id: string, requestID: string, decision: Decision) {
    const live = this.live.get(id)
    const pending = live?.permissions.get(requestID)
    if (!live || !pending) throw new NotFound("That request was answered already.")
    if (!["once", "always", "reject"].includes(decision)) throw new BadRequest("Answer once, always or reject.")
    const directory = this.record(id).session.location.directory
    live.permissions.delete(requestID)
    pending.resolve(decision)
    emit("permission.replied", { sessionID: id, requestID }, directory)
    // "Always": what else waits on the same thing goes too, as the engine does.
    if (decision !== "always") return
    const patterns = pending.request.save ?? pending.request.resources
    for (const [otherID, other] of [...live.permissions]) {
      const covered = other.request.action === pending.request.action && coveredBy(patterns, other.request.action, other.request.resources)
      if (!covered) continue
      live.permissions.delete(otherID)
      other.resolve("once")
      emit("permission.replied", { sessionID: id, requestID: otherID }, directory)
    }
  }

  private askQuestion(id: string, live: Live, turn: Turn, ask: QuestionAsk): Promise<FormAnswer | null> {
    const session = this.record(id).session
    if (turn.isEnded || live.abort?.signal.aborted) return Promise.resolve(null)
    const form: FormRequest = { id: newID("frm"), sessionID: id, title: ask.title, metadata: { kind: "question" }, fields: ask.fields }
    return new Promise((resolve) => {
      live.forms.set(form.id, { form, resolve })
      emit("form.created", { form }, session.location.directory)
    })
  }

  forms(id: string): FormRequest[] {
    this.record(id)
    return [...(this.live.get(id)?.forms.values() ?? [])].map((pending) => pending.form)
  }

  replyForm(id: string, formID: string, answer: FormAnswer | null) {
    const live = this.live.get(id)
    const pending = live?.forms.get(formID)
    if (!live || !pending) throw new NotFound("That question was answered already.")
    live.forms.delete(formID)
    pending.resolve(answer)
    emit(answer ? "form.replied" : "form.cancelled", { id: formID, sessionID: id }, this.record(id).session.location.directory)
  }

  /** The bridge is stopping: every turn ends as stopped, and every agent's conversation closes. */
  closeAll() {
    for (const [id, live] of this.live) {
      live.resume = false
      live.abort?.abort()
      this.settleAsks(id, live)
      live.turn?.finish("interrupted")
      for (const child of live.subagents.values()) child.finish("interrupted")
      live.subagents.clear()
      for (const thread of live.threads.values()) thread.close()
    }
  }

  /** An account went: its conversations in sessions close (their sessions go on with another model). */
  forgetProvider(providerID: string) {
    for (const live of this.live.values()) {
      const thread = live.threads.get(providerID)
      if (!thread) continue
      thread.close()
      live.threads.delete(providerID)
    }
  }
}

export class NotFound extends Error {}
export class BadRequest extends Error {}

function mime(uri: string): string {
  if (uri.startsWith("data:")) return uri.slice(5).split(/[;,]/)[0] || "text/plain"
  const extension = uri.split("?")[0].split(".").pop()?.toLowerCase() ?? ""
  return (
    {
      png: "image/png",
      jpg: "image/jpeg",
      jpeg: "image/jpeg",
      gif: "image/gif",
      webp: "image/webp",
      heic: "image/heic",
      pdf: "application/pdf",
      txt: "text/plain",
      md: "text/markdown",
      json: "application/json",
    } as Record<string, string>
  )[extension] ?? "application/octet-stream"
}

/** How much of a text file you attach goes in the message. */
const textFileLimit = 200_000

/** Text files you attached, in the message (as the engine puts them), and the other files. */
export function withTextFiles(text: string, files: PromptFile[]): { text: string; files: PromptFile[] } {
  const others: PromptFile[] = []
  const parts: string[] = []
  for (const file of files) {
    let contents: string | undefined
    if (!file.mime.startsWith("image/") && file.mime !== "application/pdf") {
      try {
        const bytes = file.data ? Buffer.from(file.data, "base64") : file.path && statSync(file.path).isFile() && statSync(file.path).size <= textFileLimit ? readFileSync(file.path) : undefined
        // Text, not something binary that happens to be small.
        if (bytes && !bytes.includes(0)) contents = new TextDecoder("utf-8", { fatal: true }).decode(bytes)
      } catch {}
    }
    if (contents === undefined) {
      others.push(file)
      continue
    }
    parts.push(`<file path="${file.path ?? file.name ?? "pasted"}">\n${contents}\n</file>`)
  }
  return { text: parts.length ? `${text}\n\n${parts.join("\n\n")}` : text, files: others }
}

function promptFile(file: { uri: string; name?: string }): PromptFile {
  const type = mime(file.uri)
  if (file.uri.startsWith("data:")) {
    const comma = file.uri.indexOf(",")
    const isBase64 = file.uri.slice(0, comma).endsWith(";base64")
    const payload = file.uri.slice(comma + 1)
    return { uri: file.uri, mime: type, name: file.name, data: isBase64 ? payload : Buffer.from(decodeURIComponent(payload)).toString("base64") }
  }
  let path: string | undefined
  try {
    path = file.uri.startsWith("file:") ? fileURLToPath(file.uri) : undefined
  } catch {}
  return { uri: file.uri, mime: type, name: file.name, path }
}
