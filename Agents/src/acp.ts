// Agents that speak ACP, the Agent Client Protocol (Grok's CLI, Antigravity), as T3 Code drives
// them: one agent process per session, `initialize`, a session it can load again later, a prompt
// per turn, and what it does told in `session/update`s. Each agent says how it starts, signs in,
// picks a model, and anything of its own.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname } from "node:path"
import type { RunInput, RunResult, Thread, TurnHooks } from "./agent"
import { failure } from "./agent"
import type { Limit } from "./auto"
import { fileDiff } from "./diff"
import { newID } from "./ids"
import { RPC, RPCError } from "./rpc"
import type { Turn } from "./turn"
import type { Decision, FormField, Session } from "./wire"

const outputLimit = 30_000
/** An agent's words for a usage limit (not any error that mentions a quota). */
const limitWords = /RESOURCE_EXHAUSTED|usage limit (?:reached|exceeded)|quota exceeded|exceeded your (?:current )?quota|rate limit exceeded|too many requests/i

export interface AcpFlavor {
  /** The command that starts the agent, for this session's approval mode. */
  command(options: { approvesAll: boolean; plan: boolean }): Promise<{
    argv: string[]
    env?: Record<string, string | undefined>
    cleanEnv?: boolean
    cwd?: string
    onExit?: () => void
    /** A file the agent writes when it wants you to sign in (its "browser" writes the page down): it can't go on. */
    signInFile?: string
  }>
  /** Whether the agent may read and write files through the bridge (it asks first itself). */
  fileSystem: boolean
  /** `_meta` sent with `initialize`. */
  initializeMeta?: Record<string, unknown>
  /** The way to sign in, when it asks (`authenticate`). */
  authMethod(advertised: { id: string }[]): string | undefined
  /** Sign in before the first session, rather than when it asks. */
  authenticatesFirst?: boolean
  /** Prefer `session/resume` over `session/load` (which replays the conversation). */
  resumes?: boolean
  /** Selects the model the session is to use. */
  selectModel(rpc: RPC, sessionID: string, modelID: string, setup: any): Promise<void>
  /** Sets the mode the turn needs (Antigravity's yolo, default…), if the agent has one. */
  selectMode?(rpc: RPC, sessionID: string, options: { approvesAll: boolean; plan: boolean }, setup: any): Promise<void>
  /** A line the agent writes that isn't ACP (a sign-in link): false to drop it. */
  filter?(line: string): boolean
  /** A line that means the agent can't go on (it wants a sign-in): why, in words. */
  fatalLine?(line: string): string | undefined
  /** Requests of the agent's own (`x.ai/ask_user_question`…). */
  request?(method: string, params: any, context: AcpContext): Promise<unknown> | undefined
  /** Notifications of the agent's own; true when one ended the prompt. */
  notification?(method: string, params: any, context: AcpContext): void
  /** `_meta` for a prompt. */
  promptMeta?(): Record<string, unknown> | undefined
  /** Restart the agent after a stop (it can't stop a turn and go on). */
  restartAfterInterrupt?: boolean
  /** What a usage limit holds back: the whole account (the default), or the model. */
  limitScope?: "provider" | "model"
  /** Changes when the agent's program was updated: a process started before starts again. */
  program?(): number
}

export interface AcpContext {
  turn?: Turn
  hooks?: TurnHooks
  /** Ends the prompt under way, as its response would. */
  endPrompt(stopReason: string, error?: string): void
}

interface Active {
  turn: Turn
  hooks: TurnHooks
  resolve: (result: RunResult) => void
  /** The agent process it runs on. */
  rpc: RPC
  /** Its to-do list's tool call, kept up to date until the turn ends. */
  plan?: { id: string; todos: unknown[] }
  /** Tool calls as the agent last told them, merged update by update. */
  tools: Map<string, any>
  toolsSinceText: boolean
  ended: boolean
}

export class AcpThread implements Thread {
  private rpc?: RPC
  private sessionID?: string
  private setup: any
  private spawnedWith?: string
  private active?: Active
  private loading = false
  /** A process that was stopped mid-turn and can't go on: the next message starts another. */
  private stale?: RPC

  constructor(
    private readonly flavor: AcpFlavor,
    private readonly session: Session,
    private readonly state: Record<string, unknown>,
    private readonly name: string,
  ) {}

  private async open(input: RunInput, hooks: TurnHooks) {
    const mode = { approvesAll: hooks.approvesAll(), plan: input.plan }
    const key = JSON.stringify({ ...mode, program: this.flavor.program?.() ?? 0 })
    if (this.rpc && !this.rpc.isClosed && this.spawnedWith === key && this.rpc !== this.stale) return this.rpc
    // Started again for another approval mode (the agent takes it as it starts), or an updated program.
    this.close()
    const launch = await this.flavor.command(mode)
    const flavor = this.flavor
    const rpc: RPC = new RPC(launch.argv, {
      cwd: launch.cwd ?? this.session.location.directory,
      env: launch.env,
      cleanEnv: launch.cleanEnv,
      jsonrpc: true,
      firstID: 2 ** 30,
      filter: (line) => {
        const fatal = flavor.fatalLine?.(line)
        if (fatal) {
          // What's waiting on it fails with this, rather than what it last wrote.
          setTimeout(() => {
            rpc.stderr = fatal
            rpc.kill()
          })
          return false
        }
        return flavor.filter?.(line) ?? true
      },
    })
    rpc.onNotification = (method, params) => this.notification(method, params)
    rpc.onRequest = (method, params) => this.request(method, params)
    rpc.onExit = () => {
      launch.onExit?.()
      if (this.rpc === rpc) this.rpc = undefined
      // The turn this process ran, not one a newer process runs.
      const active = this.active
      if (active && !active.ended && active.rpc === rpc) this.end(active, "failed", rpc.stderr.trim().split("\n").slice(-3).join("\n") || `${this.name} stopped.`)
    }
    this.rpc = rpc
    this.spawnedWith = key
    if (launch.signInFile) {
      const file = launch.signInFile
      const watch = setInterval(() => {
        if (rpc.isClosed) return clearInterval(watch)
        if (!existsSync(file)) return
        clearInterval(watch)
        rpc.stderr = `${this.name} needs you to sign in again: Settings › Accounts.`
        rpc.kill()
      }, 500)
    }
    const init: any = await rpc.request(
      "initialize",
      {
        protocolVersion: 1,
        clientCapabilities: { fs: { readTextFile: this.flavor.fileSystem, writeTextFile: this.flavor.fileSystem }, terminal: false },
        clientInfo: { name: "kuvo-code", title: "Kuvo Code", version: "1" },
        ...(this.flavor.initializeMeta ? { _meta: this.flavor.initializeMeta } : {}),
      },
      120_000,
    )
    const advertised = (init?.authMethods ?? []) as { id: string }[]
    const authenticate = async () => {
      const methodId = this.flavor.authMethod(advertised)
      if (!methodId) throw new Error(`${this.name} isn't signed in. Sign in again in Settings › Accounts.`)
      await rpc.request("authenticate", { methodId }, 300_000)
    }
    if (this.flavor.authenticatesFirst) await authenticate()
    const cwd = this.session.location.directory
    const previous = this.state.acpSession as string | undefined
    const openSession = async () => {
      if (previous && this.flavor.resumes && init?.agentCapabilities?.sessionCapabilities?.resume) {
        this.loading = true
        try {
          this.setup = await rpc.request("session/resume", { sessionId: previous, cwd, mcpServers: [] }, 120_000)
          this.sessionID = previous
          return
        } catch {} finally {
          this.loading = false
        }
      }
      if (previous && init?.agentCapabilities?.loadSession) {
        // What it replays of the conversation is already here.
        this.loading = true
        try {
          this.setup = await rpc.request("session/load", { sessionId: previous, cwd, mcpServers: [] }, 120_000)
          this.sessionID = previous
          return
        } catch {} finally {
          this.loading = false
        }
      }
      this.setup = await rpc.request("session/new", { cwd, mcpServers: [] }, 120_000)
      this.sessionID = this.setup?.sessionId
      this.state.acpSession = this.sessionID
      hooks.saveState()
    }
    try {
      await openSession()
    } catch (error) {
      if (!(error instanceof RPCError && error.code === -32000)) throw error
      await authenticate()
      await openSession()
    }
    return rpc
  }

  async run(input: RunInput, turn: Turn, hooks: TurnHooks): Promise<RunResult> {
    const rpc = await this.open(input, hooks)
    // Stopped while the agent was starting.
    if (hooks.signal.aborted) return { outcome: "interrupted" }
    const sessionId = this.sessionID!
    await this.flavor.selectModel(rpc, sessionId, input.model.id, this.setup).catch(() => {})
    await this.flavor.selectMode?.(rpc, sessionId, { approvesAll: hooks.approvesAll(), plan: input.plan }, this.setup).catch(() => {})
    const prompt: any[] = []
    const others: string[] = []
    for (const file of input.files) {
      const data = file.data ?? (file.mime.startsWith("image/") && file.path ? safeBase64(file.path) : undefined)
      if (file.mime.startsWith("image/") && data) prompt.push({ type: "image", data, mimeType: file.mime })
      else if (file.path) others.push(file.path)
    }
    let text = input.text
    const instructions = hooks.instructions()
    // The agent's own instructions can't be added to: they go with the first message, and again
    // when they change (a worktree, the project's other folders).
    const sent = typeof this.state.acpInstructions === "string" ? this.state.acpInstructions : this.state.acpInstructed ? undefined : ""
    if (instructions !== sent && (instructions || sent)) {
      if (instructions) text = `${sent ? "Your instructions from Kuvo Code changed. They're now:\n\n" : ""}${instructions}\n\n${text}`
      this.state.acpInstructions = instructions
      delete this.state.acpInstructed
      hooks.saveState()
    }
    if (others.length) text += `\n\nAttached files:\n${others.map((path) => `- ${path}`).join("\n")}`
    prompt.unshift({ type: "text", text })
    return new Promise<RunResult>((resolve) => {
      const active: Active = { turn, hooks, resolve, rpc, tools: new Map(), toolsSinceText: false, ended: false }
      this.active = active
      turn.startStep()
      const meta = this.flavor.promptMeta?.()
      rpc.request("session/prompt", { sessionId, prompt, ...(meta ? { _meta: meta } : {}) }).then(
        (result: any) => {
          if (result?.stopReason === "rate_limit") this.end(active, "failed", `You've reached your ${this.name} usage limit for now.`, this.limit())
          else this.end(active, result?.stopReason === "cancelled" ? "interrupted" : "succeeded")
        },
        (error) => {
          const limited = (error instanceof RPCError && error.code === -32003) || limitWords.test(errorText(error))
          this.end(active, "failed", limited ? `You've reached your ${this.name} usage limit for now.` : errorText(error), limited ? this.limit(errorText(error)) : undefined)
        },
      )
    })
  }

  private limit(message?: string): Limit {
    return { scope: this.flavor.limitScope ?? "provider", message }
  }

  private end(active: Active, outcome: RunResult["outcome"], message?: string, limit?: Limit) {
    if (active.ended) return
    active.ended = true
    if (this.active === active) this.active = undefined
    if (active.plan) active.turn.toolSucceeded(active.plan.id, "", { todos: active.plan.todos })
    active.turn.endStep()
    if (active.hooks.signal.aborted) active.resolve({ outcome: "interrupted" })
    else if (limit) active.resolve({ outcome: "failed", error: { type: "limit", message: message ?? `You've reached your ${this.name} usage limit for now.` }, limit })
    else active.resolve(outcome === "failed" ? { outcome, error: failure(message ?? `${this.name} stopped with an error.`) } : { outcome })
  }

  private context(): AcpContext {
    const active = this.active
    return {
      turn: active?.turn,
      hooks: active?.hooks,
      endPrompt: (stopReason, error) => {
        if (active) this.end(active, error ? "failed" : stopReason === "cancelled" ? "interrupted" : "succeeded", error, stopReason === "rate_limit" ? this.limit(error) : undefined)
      },
    }
  }

  private notification(method: string, params: any) {
    if (method !== "session/update") {
      this.flavor.notification?.(method, params, this.context())
      return
    }
    const active = this.active
    // What a load replays is already in the conversation.
    if (!active || this.loading || params?._meta?.isReplay) return
    const update = params?.update ?? {}
    const turn = active.turn
    switch (update.sessionUpdate) {
      case "agent_message_chunk":
        this.words(active)
        turn.text(contentText(update.content))
        return
      case "agent_thought_chunk":
        this.words(active)
        turn.reasoning(contentText(update.content))
        return
      case "tool_call":
      case "tool_call_update":
        return this.tool(active, update)
      case "plan": {
        // One to-do list a turn, brought up to date as the agent works through it.
        const todos = (update.entries ?? []).map((entry: any) => ({ content: entry.content, status: entry.status === "in_progress" ? "in_progress" : entry.status }))
        // Its own for each attempt: Auto may go on with another agent in the same turn.
        const id = active.plan?.id ?? newID("call")
        active.plan = { id, todos }
        if (!turn.hasTool(id)) turn.toolStart(id, "todowrite", { todos })
        else turn.toolCalled(id, { todos })
        return
      }
    }
  }

  /** Words after a tool begin a new step. */
  private words(active: Active) {
    if (!active.toolsSinceText) return
    active.toolsSinceText = false
    active.turn.endStep()
    active.turn.startStep()
  }

  private tool(active: Active, update: any) {
    const turn = active.turn
    const id = update.toolCallId
    if (!id) return
    const merged = { ...(active.tools.get(id) ?? {}), ...Object.fromEntries(Object.entries(update).filter(([, value]) => value !== undefined && value !== null)) }
    active.tools.set(id, merged)
    const kuvo = kuvoTool(merged)
    if (!turn.hasTool(id)) {
      active.toolsSinceText = true
      turn.toolStart(id, kuvo.name, kuvo.input)
    } else {
      turn.toolRename(id, kuvo.name)
      if (merged.status !== "completed" && merged.status !== "failed") turn.toolCalled(id, kuvo.input)
    }
    const output = toolOutput(merged)
    const files = (merged.content ?? [])
      .filter((part: any) => part?.type === "diff" && part.path)
      .map((part: any) => fileDiff(part.path, part.oldText ?? undefined, part.newText ?? ""))
    const metadata: Record<string, unknown> = {}
    if (files.length) metadata.files = files
    const exit = merged.rawOutput?.exit_code ?? merged.rawOutput?.exitCode
    if (typeof exit === "number") metadata.exit = exit
    if (output) metadata.output = output
    if (merged.status === "completed") turn.toolSucceeded(id, output, metadata)
    else if (merged.status === "failed") turn.toolFailed(id, output || "The tool failed.", metadata)
    else if (output) turn.toolProgress(id, metadata)
  }

  private async request(method: string, params: any): Promise<unknown> {
    const own = this.flavor.request?.(method, params, this.context())
    if (own) return own
    const active = this.active
    switch (method) {
      case "session/request_permission": {
        const options = (params?.options ?? []) as { optionId: string; name?: string; kind: string }[]
        if (!active) return { outcome: { outcome: "cancelled" } }
        const call = { ...(active.tools.get(params.toolCall?.toolCallId) ?? {}), ...(params.toolCall ?? {}) }
        // Antigravity asks its questions this way: the title is the question, the options its answers.
        if (String(call.toolCallId ?? "").startsWith("interaction_")) {
          const answer = await active.hooks.question({
            title: "Question",
            fields: [{ key: "answer", title: "Question", description: call.title ?? "", required: true, type: "string", options: options.map((option) => ({ value: option.optionId, label: option.name ?? option.optionId })) }],
          })
          const chosen = answer?.answer
          return chosen ? { outcome: { outcome: "selected", optionId: String(chosen) } } : { outcome: { outcome: "cancelled" } }
        }
        const kuvo = kuvoTool(call)
        const files = (call.content ?? []).filter((part: any) => part?.type === "diff" && part.path).map((part: any) => fileDiff(part.path, part.oldText ?? undefined, part.newText ?? ""))
        const decision: Decision = await active.hooks.permission({
          toolCallID: call.toolCallId,
          action: permissionAction(call.kind, kuvo.name),
          resources: resources(call),
          metadata: files.length ? { files } : undefined,
          message: call.title,
        })
        const pick = (kinds: string[]) => kinds.map((kind) => options.find((option) => option.kind === kind)).find(Boolean)
        const option = decision === "reject" ? pick(["reject_once", "reject_always"]) : decision === "always" ? pick(["allow_always", "allow_once"]) : pick(["allow_once", "allow_always"])
        return option ? { outcome: { outcome: "selected", optionId: option.optionId } } : { outcome: { outcome: "cancelled" } }
      }
      case "fs/read_text_file": {
        if (!this.flavor.fileSystem) break
        let content = readFileSync(params.path, "utf8")
        if (params.line || params.limit) {
          const lines = content.split("\n")
          const start = Math.max(0, (params.line ?? 1) - 1)
          content = lines.slice(start, params.limit ? start + params.limit : undefined).join("\n")
        }
        return { content }
      }
      case "fs/write_text_file": {
        if (!this.flavor.fileSystem) break
        mkdirSync(dirname(params.path), { recursive: true })
        writeFileSync(params.path, params.content ?? "")
        return {}
      }
    }
    throw new RPCError(-32601, `Method not found: ${method}`)
  }

  async interrupt() {
    const active = this.active
    const rpc = active?.rpc
    if (!active || !rpc || !this.sessionID) return
    // It can't go on after a stop: the next message starts it again.
    if (this.flavor.restartAfterInterrupt) this.stale = rpc
    rpc.notify("session/cancel", { sessionId: this.sessionID })
    for (let waited = 0; waited < 15_000 && !active.ended; waited += 100) await Bun.sleep(100)
    if (active.ended) return
    this.end(active, "interrupted")
    // Only this turn's process, if nothing newer runs on it.
    if (this.rpc === rpc && (!this.active || this.active.rpc !== rpc)) this.close()
  }

  close() {
    this.rpc?.kill()
    this.rpc = undefined
  }
}

// MARK: Tools, as the app knows them

function kuvoTool(call: any): { name: string; input: Record<string, unknown> } {
  const raw = call.rawInput ?? {}
  const path = call.locations?.[0]?.path ?? raw.path ?? raw.file_path ?? raw.filePath
  const command = Array.isArray(raw.command) ? raw.command.join(" ") : raw.command ?? raw.CommandLine ?? raw.command_line ?? raw.commandLine
  switch (call.kind) {
    case "execute":
      return { name: "shell", input: { command: command ?? backticked(call.title) ?? call.title, description: raw.description } }
    case "read":
      return { name: "read", input: { path } }
    case "edit":
    case "delete":
    case "move":
      return { name: "edit", input: { path } }
    case "search":
      return { name: "grep", input: { pattern: raw.pattern ?? raw.query ?? call.title, path } }
    case "fetch":
      return { name: raw.url ? "webfetch" : "websearch", input: { url: raw.url, query: raw.query ?? call.title } }
    case "think":
      return { name: "think", input: {} }
  }
  return { name: (call.title ?? "tool").toLowerCase().replace(/[^a-z0-9_]+/g, "_").replace(/^_|_$/g, "") || "tool", input: raw }
}

function permissionAction(kind: string | undefined, name: string): string {
  switch (kind) {
    case "execute":
      return "shell"
    case "edit":
    case "delete":
    case "move":
      return "edit"
    case "fetch":
      return "webfetch"
    case "read":
    case "search":
      return "read"
  }
  return name
}

function resources(call: any): string[] {
  const raw = call.rawInput ?? {}
  if (call.kind === "execute") {
    const command = Array.isArray(raw.command) ? raw.command.join(" ") : raw.command ?? backticked(call.title)
    return [command ?? call.title ?? "*"]
  }
  const paths = (call.locations ?? []).map((location: any) => location.path).filter(Boolean)
  if (paths.length) return paths
  return [raw.path ?? raw.url ?? raw.file_path ?? "*"]
}

function backticked(title: unknown): string | undefined {
  return typeof title === "string" ? title.match(/`([^`]+)`/)?.[1] : undefined
}

function contentText(content: any): string {
  if (!content) return ""
  if (typeof content === "string") return content
  if (content.type === "text") return content.text ?? ""
  if (content.type === "resource_link") return content.name ?? content.uri ?? ""
  if (content.type === "resource") return content.resource?.text ?? ""
  return ""
}

function toolOutput(call: any): string {
  const parts: string[] = []
  for (const part of call.content ?? []) {
    if (part?.type === "content") parts.push(contentText(part.content))
    else if (part?.type === "terminal") continue
  }
  const raw = call.rawOutput
  if (!parts.length && raw) {
    for (const key of ["output_for_prompt", "combinedOutput", "combined_output", "output", "stdout", "content"]) {
      const value = raw[key]
      if (typeof value === "string" && value) {
        parts.push(value)
        break
      }
    }
  }
  const text = parts.filter(Boolean).join("\n")
  return text.length > outputLimit ? text.slice(-outputLimit) : text
}

function errorText(error: unknown): string {
  if (error instanceof RPCError) {
    const data = error.data as any
    return data?.message ?? error.message
  }
  return error instanceof Error ? error.message : String(error)
}

function safeBase64(path: string): string | undefined {
  try {
    return readFileSync(path).toString("base64")
  } catch {
    return undefined
  }
}

/** Fields for a question an agent asks (Grok's `ask_user_question`), and its answer back. */
export function questionFields(questions: { id?: string; question: string; header?: string; options?: { label: string; description?: string }[]; multiSelect?: boolean }[]): FormField[] {
  return questions.map((question, index) => ({
    key: question.id ?? `q${index}`,
    title: question.header ?? `Question ${index + 1}`,
    description: question.question,
    required: true,
    type: question.multiSelect ? "multiselect" : "string",
    options: (question.options ?? []).map((option) => ({ value: option.label, label: option.label, description: option.description })),
    custom: true,
  }))
}
