// Codex, as T3 Code runs it: your own `codex`, signed in with ChatGPT or an API key (what
// `codex login` keeps), driven through its app-server (JSON-RPC over stdio). One app-server
// serves every Codex session; each session is one of its threads.

import { existsSync, lstatSync, mkdirSync, readdirSync, readlinkSync, rmSync, symlinkSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import { providerID, type AgentAccount } from "../accounts"
import type { Agent, AgentContext, Account, RunInput, RunResult, SignInAttempt, SubagentRun, Thread, TurnHooks, PromptFile } from "../agent"
import type { Limit } from "../auto"
import { accountName, failure, model } from "../agent"
import { fromPatch } from "../diff"
import { emit } from "../events"
import { kuvoTools } from "../kuvotools"
import { newID } from "../ids"
import { maintenance, update, type MaintenanceDefinition } from "../maintenance"
import { which } from "../proc"
import { RPC, RPCError } from "../rpc"
import type { Turn } from "../turn"
import type { FileDiff, FormField, Model, ModelRef, OAuthStatus, Session, TokenUsage } from "../wire"

const places = ["/opt/homebrew/bin", "/usr/local/bin", join(homedir(), ".local/bin"), join(homedir(), ".codex/bin")]
const outputLimit = 30_000

export class CodexAgent implements Agent {
  id = "codex"
  readonly providerID: string
  get name() {
    return accountName("Codex", this.instance)
  }
  install = "npm install -g @openai/codex"
  private server?: RPC
  private starting?: Promise<RPC>
  private threads = new Map<string, CodexThread>()
  /** One-off answers under way (`generate`), by their thread: what each is told. */
  private oneOffs = new Map<string, (method: string, params: any) => void>()
  private logins = new Map<string, (status: OAuthStatus) => void>()
  private accountCache?: { at: number; account: Account }
  private modelList?: { at: number; models: Model[] }
  /** Your plan's usage windows as Codex last said, by limit ("codex" is the plan's; others, a model's). */
  rateLimits = new Map<string, any>()

  constructor(
    readonly context: AgentContext,
    readonly instance: AgentAccount = { id: "default" },
  ) {
    this.providerID = providerID("codex", instance.id)
  }

  executable(): string | undefined {
    return which("codex", places)
  }

  /** Its own installer puts it in `~/.codex`: `codex update`. */
  private get definition(): MaintenanceDefinition | undefined {
    const executable = this.executable()
    if (!executable) return undefined
    return { name: "Codex", executable, npmPackage: "@openai/codex", nativeUpdate: { args: ["update"], isNative: (path) => path.includes("/.codex/") } }
  }

  async maintenance(fresh = false) {
    const definition = this.definition
    return definition ? maintenance(definition, fresh) : {}
  }

  async update() {
    const definition = this.definition
    if (!definition) return { updated: false, message: "Codex isn't installed." }
    return update(definition, this.context.temporary)
  }

  /** The app-server still running the old Codex. */
  private outdated?: RPC

  /**
   * The new Codex lists the models and runs the sessions once its app-server starts again: now,
   * or once no turn or sign-in is using the old one (a session goes on with its thread there).
   */
  programUpdated() {
    this.modelList = undefined
    this.accountCache = undefined
    this.outdated = this.server
    // One starting now may be the old program's too.
    void this.starting?.then((rpc) => {
      this.outdated ??= rpc
      this.restartIfQuiet()
    }, () => {})
    this.restartIfQuiet()
  }

  /** Restarts the old app-server when no turn but `starting`'s (not on it yet) and no sign-in uses it. */
  private restartIfQuiet(starting?: CodexThread) {
    const server = this.outdated
    if (!server) return
    if (server.isClosed || this.server !== server) {
      this.outdated = undefined
      return
    }
    if (this.logins.size || [...this.threads.values()].some((thread) => thread !== starting && thread.isRunning)) return
    this.outdated = undefined
    this.shutdown()
    // What the old one listed meanwhile, asked anew.
    this.modelList = undefined
    emit("model.updated", {})
  }

  methods() {
    return [
      { type: "oauth" as const, id: "chatgpt", label: "Sign in with ChatGPT" },
      { type: "key" as const, label: "Use an OpenAI API key" },
    ]
  }

  private lastUse = 0
  private idleCheck?: ReturnType<typeof setInterval>

  /** The app-server, started the first time it's needed and again after it stops. */
  async rpc(starting?: CodexThread): Promise<RPC> {
    this.lastUse = Date.now()
    // Stopped when nothing has used it for a while (no session, no sign-in).
    this.idleCheck ??= setInterval(() => {
      this.restartIfQuiet()
      if (!this.server || this.threads.size || this.logins.size || Date.now() - this.lastUse < 15 * 60_000) return
      this.shutdown()
    }, 60_000)
    this.restartIfQuiet(starting)
    if (this.server && !this.server.isClosed) return this.server
    this.starting ??= this.start().finally(() => (this.starting = undefined))
    return this.starting
  }

  private async start(): Promise<RPC> {
    const executable = this.executable()
    if (!executable) throw new Error("Install Codex first: npm install -g @openai/codex")
    // An added account's own CODEX_HOME, with your Codex settings in it: only its sign-in is its own.
    if (this.instance.home) shadowHome(this.instance.home)
    const rpc = new RPC([executable, "app-server"], { cwd: this.context.temporary, env: this.instance.home ? { CODEX_HOME: this.instance.home } : undefined })
    rpc.onNotification = (method, params) => this.notification(method, params)
    rpc.onRequest = (method, params) => this.request(method, params)
    rpc.onExit = () => {
      // Stopped on purpose: the threads were told then (they may be on a newer one by now).
      if (this.server !== rpc) return
      this.server = undefined
      for (const thread of this.threads.values()) thread.serverStopped()
    }
    await rpc.request("initialize", { clientInfo: { name: "kuvo-code", title: "Kuvo Code", version: "1" }, capabilities: { experimentalApi: true, optOutNotificationMethods: ["turn/diff/updated"] } }, 30_000)
    rpc.notify("initialized")
    this.server = rpc
    return rpc
  }

  private notification(method: string, params: any) {
    if (method === "account/login/completed") {
      const done = this.logins.get(params?.loginId)
      if (done) {
        this.logins.delete(params.loginId)
        done(params.success ? { status: "complete" } : { status: "failed", message: params.error ?? "Signing in didn't work." })
      }
      this.accountCache = undefined
      return
    }
    if (method === "account/updated") {
      this.accountCache = undefined
      return
    }
    if (method === "account/rateLimits/updated") {
      const snapshot = params?.rateLimits
      if (snapshot) this.rateLimits.set(snapshot.limitId ?? "codex", snapshot)
      return
    }
    // An agent a session's Codex spawned: its thread says which it came from as it starts.
    if (method === "thread/started") {
      const thread = params?.thread
      const parent = thread?.source?.subAgent?.thread_spawn?.parent_thread_id
      const owner = parent ? this.threadFor(parent) : undefined
      if (owner && thread?.id) {
        this.spawned.set(thread.id, owner)
        owner.spawnStarted(thread.id)
      }
      return
    }
    const threadID = params?.threadId
    const oneOff = threadID ? this.oneOffs.get(threadID) : undefined
    if (oneOff) return oneOff(method, params)
    if (threadID) this.threadFor(threadID)?.notification(method, params)
  }

  private async request(method: string, params: any): Promise<unknown> {
    const thread = params?.threadId ? this.threadFor(params.threadId) : params?.conversationId ? this.threadFor(params.conversationId) : undefined
    if (method === "mcpServer/elicitation/request") return { action: "decline" }
    if (!thread) throw new RPCError(-32601, `No session for ${method}.`)
    return thread.request(method, params)
  }

  private threadFor(nativeID: string): CodexThread | undefined {
    for (const thread of this.threads.values()) if (thread.nativeID === nativeID) return thread
    return this.spawned.get(nativeID)
  }

  /** How much each model holds, as Codex said in a turn. */
  private contexts = new Map<string, number>()

  noteContext(model: string, window: number) {
    if (this.contexts.get(model) === window) return
    this.contexts.set(model, window)
    this.modelList = undefined
    emit("model.updated", {})
  }

  /** Threads of agents a session's Codex spawned: their events and approvals go to that session. */
  private spawned = new Map<string, CodexThread>()

  adopt(threadID: string, thread: CodexThread) {
    this.spawned.set(threadID, thread)
  }

  async account(fresh = false): Promise<Account> {
    if (!this.executable()) return { installed: false, signedIn: false, message: "Install Codex, then sign in here." }
    if (!fresh && this.accountCache && Date.now() - this.accountCache.at < 30_000) return this.accountCache.account
    const rpc = await this.rpc()
    const result: any = await rpc.request("account/read", {}, 20_000)
    const info = result?.account
    let account: Account
    if (!info) {
      account = { installed: true, signedIn: false, message: "Sign in to Codex with ChatGPT or an OpenAI API key." }
    } else if (info.type === "chatgpt") {
      const plan = info.planType ? `ChatGPT ${String(info.planType).charAt(0).toUpperCase()}${String(info.planType).slice(1)}` : "ChatGPT"
      account = { installed: true, signedIn: true, label: [info.email, plan].filter(Boolean).join(" · ") }
    } else {
      account = { installed: true, signedIn: true, label: info.type === "apiKey" ? "OpenAI API key" : String(info.type) }
    }
    this.accountCache = { at: Date.now(), account }
    return account
  }

  async signIn(): Promise<SignInAttempt> {
    const rpc = await this.rpc()
    const result: any = await rpc.request("account/login/start", { type: "chatgpt" }, 30_000)
    let status: OAuthStatus = { status: "pending" }
    this.logins.set(result.loginId, (done) => (status = done))
    return {
      url: result.authUrl,
      instructions: "Finish signing in with ChatGPT in your browser. Codex keeps the sign-in, as when you run codex login.",
      mode: "auto",
      status: () => status,
      cancel: () => {
        this.logins.delete(result.loginId)
        void rpc.request("account/login/cancel", { loginId: result.loginId }).catch(() => {})
      },
    }
  }

  async signInWithKey(key: string) {
    const rpc = await this.rpc()
    await rpc.request("account/login/start", { type: "apiKey", apiKey: key }, 30_000)
    this.accountCache = undefined
  }

  async models(): Promise<Model[]> {
    if (this.modelList && Date.now() - this.modelList.at < 30 * 60_000) return this.modelList.models
    const rpc = await this.rpc()
    const models: Model[] = []
    let cursor: string | undefined
    let order = 1000
    do {
      const page: any = await rpc.request("model/list", cursor ? { cursor } : {}, 30_000)
      for (const info of page?.data ?? []) {
        if (info.hidden) continue
        models.push(
          model(this.providerID, info.model ?? info.id, info.displayName ?? info.model, {
            variants: (info.supportedReasoningEfforts ?? []).map((effort: any) => effort.reasoningEffort),
            images: (info.inputModalities ?? []).includes("image"),
            context: this.contexts.get(info.model ?? info.id) ?? 400_000,
            // Listed in Codex's order: its default first.
            released: info.isDefault ? 2000 : order--,
          }),
        )
      }
      cursor = page?.nextCursor ?? undefined
    } while (cursor)
    // Not kept from the old Codex's app-server: asked again of the new one.
    if (rpc !== this.outdated) this.modelList = { at: Date.now(), models }
    return models
  }

  forgetModels() {
    this.modelList = undefined
  }

  shutdown() {
    const server = this.server
    if (!server) return
    this.server = undefined
    server.kill()
    for (const thread of this.threads.values()) thread.serverStopped()
  }

  /** One answer from Codex on your plan, in a thread kept nowhere, that can only read. */
  async generate(prompt: string, model: ModelRef): Promise<string> {
    const rpc = await this.rpc()
    const started: any = await rpc.request("thread/start", { ephemeral: true, cwd: this.context.temporary, model: model.id, approvalPolicy: "never", sandbox: "read-only" }, 60_000)
    const threadId: string = started.thread.id
    let text = ""
    let timer: ReturnType<typeof setTimeout> | undefined
    const done = new Promise<string>((resolve, reject) => {
      timer = setTimeout(() => reject(new Error("Codex took too long to answer.")), 120_000)
      this.oneOffs.set(threadId, (method, params) => {
        if (method === "item/completed" && params?.item?.type === "agentMessage" && typeof params.item.text === "string") text = params.item.text
        if (method !== "turn/completed") return
        if (params?.turn?.status === "completed") resolve(text.trim())
        else reject(new Error(params?.turn?.error?.message ?? "Codex couldn't answer."))
      })
    })
    // (Settled before it's awaited, it isn't an unhandled failure.)
    done.catch(() => {})
    try {
      await rpc.request("turn/start", { threadId, input: [{ type: "text", text: prompt, text_elements: [] }], ...(model.variant ? { effort: model.variant } : {}) }, 60_000)
      return await done
    } finally {
      clearTimeout(timer)
      this.oneOffs.delete(threadId)
    }
  }

  thread(session: Session, state: Record<string, unknown>): Thread {
    const thread = new CodexThread(this, session, state)
    this.threads.set(session.id, thread)
    return thread
  }

  forget(sessionID: string) {
    const thread = this.threads.get(sessionID)
    this.threads.delete(sessionID)
    // The agents it spawned go with it.
    for (const [spawn, owner] of this.spawned) if (owner === thread) this.spawned.delete(spawn)
  }
}

// MARK: A session

/** Where Codex's items are told: the turn's own, or a spawned agent's session. */
interface Lane {
  turn: Turn
  /** Items whose words came as deltas (their completion doesn't add them again). */
  streamed: Set<string>
  /** File changes, by item, for their approval and their result. */
  changes: Map<string, { path: string; kind: string; diff: string }[]>
  /** A command's output so far, by item. */
  output: Map<string, string>
  /** A tool ran since the last words: the next words start a new step. */
  toolsSinceText: boolean
  usage?: TokenUsage
}

/** An agent Codex spawned: its thread's work, told in a session of its own. */
interface SubagentLane extends Lane {
  run: SubagentRun
  /** The spawn call that started it. */
  call: string
  title: string
  ended: boolean
}

interface Active extends Lane {
  hooks: TurnHooks
  /** The agents it spawned, by their thread. */
  subagents: Map<string, SubagentLane>
  /** Spawn calls under way whose thread isn't known yet, oldest first. */
  spawning: string[]
  /** Its to-do list's tool call, kept up to date until the turn ends. */
  plan?: { id: string; todos: { content: string; status: string }[] }
  resolve: (result: RunResult) => void
  turnID?: string
  /** On Auto: a limit ends the turn rather than being waited out. */
  auto?: boolean
  /** A usage limit it reached (Auto goes on with the next model). */
  limit?: Limit
  /** You pressed Stop. */
  stopping?: boolean
  /** Auto stopped it at a limit, to go on with the next model. */
  stoppedForLimit?: boolean
  model: string
  problem?: string
}

class CodexThread implements Thread {
  nativeID?: string
  private loaded = false
  /** The app's added instructions the thread was loaded with. */
  private instructions?: string | null
  private active?: Active
  /** From a message's start until its turn ends: its app-server isn't to stop meanwhile. */
  private inTurn = false
  /** The thread it had was gone: a new one took its place. */
  private startedOver = false
  /** Where Kuvo Code's tools were when it was loaded. */
  private toolsURL?: string
  /** The agents it spawned, by their thread: their sessions, across turns. */
  private spawnedSessions = new Map<string, { call: string; title: string; sessionID: string }>()
  /** Agents it spawned still at work after the turn that spawned them ended, by their thread. */
  private backgroundLanes = new Map<string, SubagentLane>()

  constructor(
    private readonly agent: CodexAgent,
    private readonly session: Session,
    private readonly state: Record<string, unknown>,
  ) {
    this.nativeID = state.codexThread as string | undefined
  }

  /** The app-server stopped: a thread must be loaded again, and a turn under way is over. */
  serverStopped() {
    this.loaded = false
    const active = this.active
    if (!active) return
    this.active = undefined
    active.resolve(active.hooks.signal.aborted ? { outcome: "interrupted" } : { outcome: "failed", error: failure(active.problem ?? "Codex stopped.") })
  }

  private policy(hooks: TurnHooks, plan: boolean) {
    if (plan) return { approvalPolicy: "untrusted", sandboxPolicy: { type: "readOnly", networkAccess: true } }
    if (hooks.approvesAll()) return { approvalPolicy: "never", sandboxPolicy: { type: "dangerFullAccess" } }
    return { approvalPolicy: "untrusted", sandboxPolicy: { type: "readOnly", networkAccess: true } }
  }

  private async ensureThread(input: RunInput, hooks: TurnHooks) {
    // A turn starting: on the new Codex, when it was updated.
    const rpc = await this.agent.rpc(this)
    const instructions = hooks.instructions() || null
    // Loaded again with what the app adds to its instructions, when that changed.
    const tools = kuvoTools(this.session.id)
    // Loaded again when Kuvo Code's tools moved (the app started again), to reach them.
    if (this.nativeID && this.loaded && instructions === this.instructions && tools?.url === this.toolsURL) return rpc
    this.toolsURL = tools?.url
    this.instructions = instructions
    // Kuvo Code's own tools, as the engine's models have them (a setting for this thread alone).
    const config = tools ? { [`mcp_servers.${tools.name}`]: { url: tools.url, http_headers: tools.headers, tool_timeout_sec: Math.ceil(tools.timeout / 1000) } } : undefined
    const common = { cwd: this.session.location.directory, model: input.model.id, developerInstructions: instructions, ...(config ? { config } : {}) }
    if (this.nativeID) {
      try {
        await rpc.request("thread/resume", { threadId: this.nativeID, excludeTurns: true, ...common }, 60_000)
        this.loaded = true
        return rpc
      } catch (error) {
        if (error instanceof RPCError && /archived|unarchive/i.test(error.message)) {
          await rpc.request("thread/unarchive", { threadId: this.nativeID }).catch(() => {})
          await rpc.request("thread/resume", { threadId: this.nativeID, excludeTurns: true, ...common }, 60_000)
          this.loaded = true
          return rpc
        }
        // Gone (deleted, or another Codex's): a new thread, without what came before.
      }
    }
    const started: any = await rpc.request("thread/start", common, 60_000)
    if (this.nativeID && this.nativeID !== started.thread.id) this.startedOver = true
    this.nativeID = started.thread.id
    this.state.codexThread = this.nativeID
    hooks.saveState()
    this.loaded = true
    return rpc
  }

  get isRunning(): boolean {
    return this.inTurn
  }

  /** Your message, into the turn under way (Codex's turn/steer). */
  async steer(input: { id: string; text: string; files: PromptFile[] }): Promise<boolean> {
    const active = this.active
    if (!active?.turnID || !this.nativeID) return false
    const items: any[] = [{ type: "text", text: input.text, text_elements: [] }]
    const others: string[] = []
    for (const file of input.files) {
      if (file.mime.startsWith("image/") && file.path) items.push({ type: "localImage", path: file.path })
      else if (file.mime.startsWith("image/") && file.data) items.push({ type: "image", url: `data:${file.mime};base64,${file.data}` })
      else if (file.path) others.push(file.path)
    }
    if (others.length) items[0].text += `\n\nAttached files:\n${others.map((path) => `- ${path}`).join("\n")}`
    try {
      const rpc = await this.agent.rpc()
      await rpc.request("turn/steer", { threadId: this.nativeID, input: items, expectedTurnId: active.turnID }, 30_000)
      return this.active === active
    } catch {
      return false
    }
  }

  async prepare(input: RunInput, hooks: TurnHooks) {
    this.inTurn = true
    try {
      await this.ensureThread(input, hooks)
    } finally {
      this.inTurn = false
    }
    const fresh = this.startedOver
    this.startedOver = false
    return { fresh }
  }

  async run(input: RunInput, turn: Turn, hooks: TurnHooks): Promise<RunResult> {
    this.inTurn = true
    try {
      return await this.runTurn(input, turn, hooks)
    } finally {
      this.inTurn = false
    }
  }

  private async runTurn(input: RunInput, turn: Turn, hooks: TurnHooks): Promise<RunResult> {
    const rpc = await this.ensureThread(input, hooks)
    // Stopped while Codex was starting.
    if (hooks.signal.aborted) return { outcome: "interrupted" }
    const items: any[] = [{ type: "text", text: input.text, text_elements: [] }]
    const others: string[] = []
    for (const file of input.files) {
      if (file.mime.startsWith("image/")) {
        if (file.path) items.push({ type: "localImage", path: file.path })
        else if (file.data) items.push({ type: "image", url: `data:${file.mime};base64,${file.data}` })
      } else if (file.path) {
        others.push(file.path)
      }
    }
    if (others.length) items[0].text += `\n\nAttached files:\n${others.map((path) => `- ${path}`).join("\n")}`
    const effort = input.model.variant
    const params: Record<string, unknown> = {
      threadId: this.nativeID,
      input: items,
      cwd: this.session.location.directory,
      model: input.model.id,
      summary: "detailed",
      approvalsReviewer: "user",
      ...this.policy(hooks, input.plan),
      ...(effort ? { effort } : {}),
      collaborationMode: { mode: input.plan ? "plan" : "default", settings: { model: input.model.id, reasoning_effort: effort ?? null, developer_instructions: null } },
    }
    return new Promise<RunResult>((resolve) => {
      const active: Active = { turn, hooks, resolve, streamed: new Set(), changes: new Map(), output: new Map(), toolsSinceText: false, subagents: new Map(), spawning: [], auto: input.auto, model: input.model.id }
      // As it ends, the agents it spawned that are still at work go on in their sessions (a turn
      // stopped or failed stops them: the session ends them with it).
      active.resolve = (result) => {
        if (result.outcome === "succeeded") for (const [threadID, lane] of active.subagents) if (!lane.ended) this.backgroundLanes.set(threadID, lane)
        resolve(result)
      }
      this.active = active
      turn.startStep()
      rpc.request("turn/start", params, 60_000).then(
        (result: any) => {
          if (result?.turn?.id) active.turnID ??= result.turn.id
        },
        (error) => {
          if (this.active !== active) return
          this.active = undefined
          resolve({ outcome: "failed", error: failure(error) })
        },
      )
    })
  }

  notification(method: string, params: any) {
    const active = this.active
    // An agent it spawned: told in its session (one still at work after the turn too).
    if (params?.threadId && this.nativeID && params.threadId !== this.nativeID) return this.subagentNotification(active, params.threadId, method, params)
    if (!active) return
    const turn = active.turn
    // Another turn's (one stopped before, ending late).
    const turnID = params?.turnId ?? params?.turn?.id
    if (active.turnID && turnID && turnID !== active.turnID) return
    switch (method) {
      case "turn/started":
        active.turnID ??= params.turn?.id
        return
      case "item/agentMessage/delta":
        this.words(active)
        active.streamed.add(params.itemId)
        turn.text(params.delta ?? "")
        return
      case "item/reasoning/summaryTextDelta":
        this.words(active)
        turn.reasoning(params.delta ?? "")
        return
      case "item/commandExecution/outputDelta": {
        const output = ((active.output.get(params.itemId) ?? "") + (params.delta ?? "")).slice(-outputLimit)
        active.output.set(params.itemId, output)
        turn.toolProgress(params.itemId, { output })
        return
      }
      case "item/started":
        return this.itemStarted(active, params.item)
      case "item/completed":
        return this.itemCompleted(active, params.item)
      case "turn/plan/updated": {
        // Its to-do list, one a turn, brought up to date as it works through it.
        const todos = ((params.plan ?? []) as { step: string; status: string }[]).map((entry) => ({ content: entry.step, status: entry.status === "inProgress" ? "in_progress" : entry.status }))
        const id = active.plan?.id ?? newID("call")
        active.plan = { id, todos }
        if (!turn.hasTool(id)) turn.toolStart(id, "todowrite", { todos })
        else turn.toolCalled(id, { todos })
        return
      }
      case "thread/tokenUsage/updated": {
        // How much its model holds, as Codex says: the models list it.
        const window = params.tokenUsage?.modelContextWindow
        if (typeof window === "number" && window > 0) this.agent.noteContext(active.model, window)
        const last = params.tokenUsage?.last
        if (last) {
          active.usage = {
            input: Math.max(0, (last.inputTokens ?? 0) - (last.cachedInputTokens ?? 0)),
            output: Math.max(0, (last.outputTokens ?? 0) - (last.reasoningOutputTokens ?? 0)),
            reasoning: last.reasoningOutputTokens ?? 0,
            cache: { read: last.cachedInputTokens ?? 0, write: last.cacheWriteInputTokens ?? 0 },
          }
        }
        return
      }
      case "error": {
        const limit = this.limitOf(params.error, active.model)
        if (limit && params.willRetry) {
          // On Auto, the next model goes on rather than waiting for Codex to try again; otherwise
          // Codex's retry may well go through.
          if (active.auto) {
            active.limit = { ...limit, brief: limit.brief ?? params.error?.codexErrorInfo === "rateLimitExceeded" }
            active.problem = params.error?.message || "Codex is rate limited for now."
            active.stoppedForLimit = true
            void this.stopTurn(active)
          }
          return
        }
        if (limit) {
          active.limit = limit
          active.problem = params.error?.message || "You've reached your Codex usage limit for now."
          return
        }
        if (!params.willRetry) active.problem = params.error?.additionalDetails || params.error?.message
        return
      }
      case "turn/completed": {
        this.active = undefined
        if (active.plan) turn.toolSucceeded(active.plan.id, "", { todos: active.plan.todos })
        turn.endStep({ tokens: active.usage })
        const status = params.turn?.status
        // A limit only when the turn didn't go through: one it got past on a retry doesn't count.
        const limit = status === "failed" ? (active.limit ?? this.limitOf(params.turn?.error, active.model)) : status === "interrupted" && active.stoppedForLimit ? active.limit : undefined
        if (limit && !active.stopping && !active.hooks.signal.aborted) {
          active.resolve({ outcome: "failed", error: { type: "limit", message: active.problem ?? params.turn?.error?.message ?? "You've reached your Codex usage limit for now." }, limit, taken: true })
        } else if (active.hooks.signal.aborted || status === "interrupted") active.resolve({ outcome: "interrupted" })
        else if (status === "failed") active.resolve({ outcome: "failed", error: failure(params.turn?.error?.message ?? active.problem ?? "Codex stopped with an error."), taken: true })
        else active.resolve({ outcome: "succeeded" })
        return
      }
    }
  }

  /** A thread this session's Codex spawned started: the oldest spawn call under way is its. */
  spawnStarted(threadID: string) {
    const active = this.active
    const call = active?.spawning[0]
    if (active && call && !active.subagents.has(threadID)) this.linkSubagent(active, call, threadID)
  }

  /** What a spawned agent's thread says, in its session. */
  private subagentNotification(active: Active | undefined, threadID: string, method: string, params: any) {
    let lane = active?.subagents.get(threadID)
    const kept = this.backgroundLanes.get(threadID)
    if (!lane && kept) {
      lane = kept
      // A turn under way has it now.
      if (active) {
        this.backgroundLanes.delete(threadID)
        active.subagents.set(threadID, kept)
      }
    }
    if (!active && !lane) return
    if (!lane) {
      if (!active) return
      // One spawned in an earlier turn, given more to do: its session goes on.
      const before = this.spawnedSessions.get(threadID)
      if (!before) return
      const run = active.hooks.subagent(before.call, { title: before.title, sessionID: before.sessionID, background: true })
      lane = { turn: run.turn, streamed: new Set(), changes: new Map(), output: new Map(), toolsSinceText: false, run, call: before.call, title: before.title, ended: false }
      active.subagents.set(threadID, lane)
    }
    if (lane.ended) {
      // Given more to do: its session goes on (in a turn of this session's: between turns, it's
      // told when the next one begins).
      if (method !== "turn/started" || !active) return
      lane = this.continueSubagent(active, threadID, lane)
    }
    const turn = lane.turn
    switch (method) {
      case "item/agentMessage/delta":
        this.words(lane)
        lane.streamed.add(params.itemId)
        turn.text(params.delta ?? "")
        return
      case "item/reasoning/summaryTextDelta":
        this.words(lane)
        turn.reasoning(params.delta ?? "")
        return
      case "item/commandExecution/outputDelta": {
        const output = ((lane.output.get(params.itemId) ?? "") + (params.delta ?? "")).slice(-outputLimit)
        lane.output.set(params.itemId, output)
        turn.toolProgress(params.itemId, { output })
        return
      }
      case "item/started":
        return this.itemStarted(lane, params.item)
      case "item/completed":
        return this.itemCompleted(lane, params.item)
      case "thread/tokenUsage/updated": {
        const last = params.tokenUsage?.last
        if (last) lane.usage = { input: Math.max(0, (last.inputTokens ?? 0) - (last.cachedInputTokens ?? 0)), output: Math.max(0, (last.outputTokens ?? 0) - (last.reasoningOutputTokens ?? 0)), reasoning: last.reasoningOutputTokens ?? 0, cache: { read: last.cachedInputTokens ?? 0, write: last.cacheWriteInputTokens ?? 0 } }
        return
      }
      case "turn/completed": {
        const status = params.turn?.status
        this.endSubagent(lane, status === "failed" ? "failed" : status === "interrupted" ? "interrupted" : "succeeded", params.turn?.error?.message)
        this.backgroundLanes.delete(threadID)
        return
      }
    }
  }

  /**
   * An agent spawned (Codex 0.16x says so with a `subAgentActivity` "started", the task itself
   * kept encrypted): a row for it, and a session its thread is told in.
   */
  private spawned(main: Active, item: any) {
    const threadID = item.agentThreadId
    if (typeof threadID !== "string" || main.subagents.has(threadID)) return
    const title = agentTitle(item.agentPath) || "A spawned agent's task"
    main.toolsSinceText = true
    if (!main.turn.hasTool(item.id)) main.turn.toolStart(item.id, "subagent", { description: title, background: true })
    const lane = this.linkSubagent(main, item.id, threadID)
    main.turn.toolSucceeded(item.id, "Started.", { sessionID: lane.run.sessionID })
  }

  /** A spawned agent's session, for its spawn call and thread. */
  private linkSubagent(active: Active, call: string, threadID: string, prompt?: string): SubagentLane {
    const known = active.subagents.get(threadID)
    if (known) return known
    active.spawning = active.spawning.filter((waiting) => waiting !== call)
    const input = (active.turn.toolInput(call) ?? {}) as Record<string, any>
    const title = String(input.description ?? "") || "A spawned agent's task"
    // It works on its own, past the turn that spawned it.
    const run = active.hooks.subagent(call, { title, prompt: prompt ?? input.prompt, background: true })
    const lane: SubagentLane = { turn: run.turn, streamed: new Set(), changes: new Map(), output: new Map(), toolsSinceText: false, run, call, title, ended: false }
    active.subagents.set(threadID, lane)
    this.spawnedSessions.set(threadID, { call, title, sessionID: run.sessionID })
    // Its approvals come to this session's.
    this.agent.adopt(threadID, this)
    return lane
  }

  private continueSubagent(active: Active, threadID: string, lane: SubagentLane): SubagentLane {
    const run = active.hooks.subagent(lane.call, { title: lane.title, sessionID: lane.run.sessionID, background: true })
    const next: SubagentLane = { turn: run.turn, streamed: new Set(), changes: new Map(), output: new Map(), toolsSinceText: false, run, call: lane.call, title: lane.title, ended: false }
    active.subagents.set(threadID, next)
    return next
  }

  private endSubagent(lane: SubagentLane, outcome: "succeeded" | "failed" | "interrupted", message?: string) {
    if (lane.ended) return
    lane.ended = true
    lane.turn.endStep({ tokens: lane.usage })
    lane.run.end(outcome, outcome === "failed" ? { type: "agent", message: message ?? "The agent stopped with an error." } : undefined)
  }

  /** Words after a tool begin a new step, as a model's next answer does. */
  private words(lane: Lane) {
    if (!lane.toolsSinceText) return
    lane.toolsSinceText = false
    lane.turn.endStep({ tokens: lane.usage })
    lane.usage = undefined
    lane.turn.startStep()
  }

  private itemStarted(lane: Lane, item: any) {
    const active = lane
    const turn = lane.turn
    switch (item?.type) {
      case "sleep":
        // It waits a while on purpose.
        active.toolsSinceText = true
        turn.toolStart(item.id, "sleep", { seconds: Math.round((item.durationMs ?? 0) / 1000) })
        return
      case "collabAgentToolCall": {
        // Waiting for the agents it spawned.
        if (item.tool === "wait") {
          active.toolsSinceText = true
          turn.toolStart(item.id, "wait", { description: "Waiting for its subagents" })
          return
        }
        // Another agent spawned for part of the work: a subagent, at work beside this one.
        if (item.tool !== "spawnAgent" || !this.active || lane !== this.active) return
        const main = this.active
        lane.toolsSinceText = true
        const prompt = typeof item.prompt === "string" ? item.prompt : ""
        turn.toolStart(item.id, "subagent", { description: firstLine(prompt) || "A spawned agent's task", prompt, background: true })
        main.spawning.push(item.id)
        const thread = item.receiverThreadIds?.[0]
        if (thread) this.linkSubagent(main, item.id, thread, prompt)
        return
      }
      case "subAgentActivity": {
        const main = this.active
        if (main && lane === main && item.kind === "started") return this.spawned(main, item)
        const spawned = main && lane === main ? main.subagents.get(item.agentThreadId) : undefined
        if (spawned && (item.kind === "completed" || item.kind === "interrupted")) this.endSubagent(spawned, item.kind === "completed" ? "succeeded" : "interrupted")
        return
      }
      case "commandExecution":
        active.toolsSinceText = true
        turn.toolStart(item.id, "shell", { command: unwrapShell(item.command ?? ""), cwd: item.cwd })
        return
      case "fileChange": {
        active.toolsSinceText = true
        const changes = (item.changes ?? []).map((change: any) => ({ path: change.path, kind: change.kind?.type ?? "update", diff: change.diff ?? "" }))
        active.changes.set(item.id, changes)
        turn.toolStart(item.id, "patch", { files: changes.map((change: { path: string }) => change.path) })
        return
      }
      case "mcpToolCall":
        active.toolsSinceText = true
        turn.toolStart(item.id, `${item.server}_${item.tool}`, item.arguments ?? {})
        return
      case "dynamicToolCall":
        active.toolsSinceText = true
        turn.toolStart(item.id, item.tool, item.arguments ?? {})
        return
      case "webSearch":
        active.toolsSinceText = true
        turn.toolStart(item.id, "websearch", { query: item.query ?? item.action?.query ?? "" })
        return
    }
  }

  private itemCompleted(lane: Lane, item: any) {
    const active = lane
    const turn = lane.turn
    switch (item?.type) {
      case "sleep":
        if (turn.hasTool(item.id)) turn.toolSucceeded(item.id, `Waited ${Math.round((item.durationMs ?? 0) / 1000)} seconds.`)
        return
      case "collabAgentToolCall": {
        if (item.tool === "wait") {
          if (turn.hasTool(item.id)) item.status === "failed" ? turn.toolFailed(item.id, "It stopped waiting.") : turn.toolSucceeded(item.id, "Done waiting.")
          return
        }
        if (item.tool !== "spawnAgent" || !this.active || lane !== this.active) return
        const main = this.active
        const thread = item.receiverThreadIds?.[0]
        const spawned = thread ? this.linkSubagent(main, item.id, thread, typeof item.prompt === "string" ? item.prompt : undefined) : undefined
        if (item.status === "failed" || !spawned) turn.toolFailed(item.id, "The agent couldn't be started.")
        else turn.toolSucceeded(item.id, "Started.", { sessionID: spawned.run.sessionID })
        return
      }
      case "subAgentActivity": {
        const main = this.active
        if (main && lane === main && item.kind === "started") return this.spawned(main, item)
        const spawned = main && lane === main ? main.subagents.get(item.agentThreadId) : undefined
        if (spawned && (item.kind === "completed" || item.kind === "interrupted")) this.endSubagent(spawned, item.kind === "completed" ? "succeeded" : "interrupted")
        return
      }
      case "agentMessage":
        if (!active.streamed.has(item.id) && item.text) {
          this.words(active)
          turn.text(item.text)
        }
        turn.endBlock()
        return
      case "reasoning":
        turn.endBlock()
        return
      case "plan":
        // Plan mode's proposal: the plan, in words.
        if (item.text) {
          this.words(active)
          turn.text(item.text)
          turn.endBlock()
        }
        return
      case "commandExecution": {
        const output = (item.aggregatedOutput ?? active.output.get(item.id) ?? "").slice(-outputLimit)
        if (item.status === "declined") turn.toolFailed(item.id, "Declined.")
        else if (item.status === "failed" && item.exitCode == null) turn.toolFailed(item.id, output || "The command failed.")
        else turn.toolSucceeded(item.id, output, { output, exit: item.exitCode ?? 0 })
        return
      }
      case "fileChange": {
        const changes: { path: string; kind: string; diff: string }[] = (item.changes ?? []).map((change: any) => ({ path: change.path, kind: change.kind?.type ?? "update", diff: change.diff ?? "" }))
        const files: FileDiff[] = changes.map((change) => fromPatch(change.path, change.diff, change.kind === "add" ? "added" : change.kind === "delete" ? "deleted" : "modified"))
        if (item.status === "declined") turn.toolFailed(item.id, "Declined.", { files })
        else if (item.status === "failed") turn.toolFailed(item.id, "The change couldn't be made.", { files })
        else turn.toolSucceeded(item.id, changes.map((change) => change.path).join("\n"), { files })
        return
      }
      case "mcpToolCall": {
        const text = (item.result?.content ?? []).map((part: any) => part?.text ?? "").filter(Boolean).join("\n")
        if (item.error || item.status === "failed") turn.toolFailed(item.id, item.error?.message ?? text ?? "The tool failed.")
        else turn.toolSucceeded(item.id, text.slice(0, outputLimit))
        return
      }
      case "dynamicToolCall": {
        const text = (item.contentItems ?? []).map((part: any) => part?.text ?? "").filter(Boolean).join("\n")
        if (item.success === false) turn.toolFailed(item.id, text || "The tool failed.")
        else turn.toolSucceeded(item.id, text.slice(0, outputLimit))
        return
      }
      case "webSearch":
        turn.toolSucceeded(item.id, "")
        return
    }
  }

  async request(method: string, params: any): Promise<unknown> {
    const active = this.active
    if (!active) {
      if (method === "item/tool/requestUserInput") return { answers: {} }
      return method.endsWith("Approval") || method.endsWith("/requestApproval") ? (method.startsWith("item/") ? { decision: "decline" } : { decision: "denied" }) : {}
    }
    const hooks = active.hooks
    switch (method) {
      case "item/commandExecution/requestApproval": {
        const decision = await hooks.permission({ toolCallID: params.itemId, action: "shell", resources: [unwrapShell(params.command ?? "")], message: params.reason ?? undefined })
        return { decision: decision === "always" ? "acceptForSession" : decision === "once" ? "accept" : "decline" }
      }
      case "item/fileChange/requestApproval": {
        // A spawned agent's change: its session has it.
        const lane: Lane = (params.threadId && params.threadId !== this.nativeID ? active.subagents.get(params.threadId) : undefined) ?? active
        const changes = lane.changes.get(params.itemId) ?? []
        const files = changes.map((change) => fromPatch(change.path, change.diff, change.kind === "add" ? "added" : change.kind === "delete" ? "deleted" : "modified"))
        const decision = await hooks.permission({
          toolCallID: params.itemId,
          action: "edit",
          resources: changes.length ? changes.map((change) => change.path) : [params.grantRoot ?? "*"],
          metadata: files.length ? { files } : undefined,
          message: params.reason ?? undefined,
        })
        return { decision: decision === "always" ? "acceptForSession" : decision === "once" ? "accept" : "decline" }
      }
      case "item/permissions/requestApproval": {
        const paths = [...(params.permissions?.fileSystem?.read ?? []), ...(params.permissions?.fileSystem?.write ?? [])]
        const decision = await hooks.permission({ toolCallID: params.itemId, action: "external_directory", resources: paths.length ? paths : ["*"], message: params.reason ?? undefined })
        return decision === "reject" ? { permissions: {}, scope: "turn" } : { permissions: params.permissions, scope: decision === "always" ? "session" : "turn" }
      }
      case "execCommandApproval": {
        const command = Array.isArray(params.command) ? params.command.join(" ") : String(params.command ?? "")
        const decision = await hooks.permission({ toolCallID: params.callId, action: "shell", resources: [command], message: params.reason ?? undefined })
        return { decision: decision === "always" ? "approved_for_session" : decision === "once" ? "approved" : "denied" }
      }
      case "applyPatchApproval": {
        const paths = Object.keys(params.fileChanges ?? {})
        const decision = await hooks.permission({ toolCallID: params.callId, action: "edit", resources: paths.length ? paths : ["*"], message: params.reason ?? undefined })
        return { decision: decision === "always" ? "approved_for_session" : decision === "once" ? "approved" : "denied" }
      }
      case "item/tool/requestUserInput": {
        const questions = (params.questions ?? []) as { id: string; header?: string; question: string; options?: { label: string; description?: string }[]; isOther?: boolean }[]
        const fields: FormField[] = questions.map((question) => ({
          key: question.id,
          title: question.header ?? "Question",
          description: question.question,
          required: true,
          type: "string",
          options: question.options?.map((option) => ({ value: option.label, label: option.label, description: option.description })),
          custom: question.isOther ?? !question.options?.length,
        }))
        const answer = await hooks.question({ title: questions.length === 1 ? questions[0].header ?? "Question" : "Questions", fields, toolCallID: params.itemId })
        const answers: Record<string, { answers: string[] }> = {}
        for (const question of questions) {
          const value = answer?.[question.id]
          answers[question.id] = { answers: value === undefined || value === null ? [] : Array.isArray(value) ? value.map(String) : [String(value)] }
        }
        return { answers }
      }
    }
    throw new RPCError(-32601, `Method not found: ${method}`)
  }

  /** A usage or rate limit in Codex's error: the plan's, or one model's (its own limit). */
  private limitOf(error: any, model: string): Limit | undefined {
    const info = error?.codexErrorInfo
    if (info !== "usageLimitExceeded" && info !== "rateLimitExceeded") return undefined
    const reached = (snapshot: any) =>
      Boolean(snapshot?.rateLimitReachedType) || [snapshot?.primary, snapshot?.secondary].some((window) => (window?.usedPercent ?? 0) >= 100)
    const resets = (snapshot: any) => {
      const times = [snapshot?.primary, snapshot?.secondary].filter((window) => (window?.usedPercent ?? 0) >= 100 && window?.resetsAt).map((window) => window.resetsAt * 1000)
      return times.length ? Math.max(...times) : undefined
    }
    // A model with a limit of its own, at it: only that model waits.
    for (const [id, snapshot] of this.agent.rateLimits) {
      if (id === "codex" || !reached(snapshot)) continue
      const slug: string | undefined = snapshot.normalModelSlug
      if (slug && (model === slug || model.startsWith(`${slug}-`))) return { scope: "model", resetsAt: resets(snapshot), message: error?.message }
    }
    const plan = this.agent.rateLimits.get("codex")
    if (info === "rateLimitExceeded" && !reached(plan)) return { scope: "model", brief: true, message: error?.message }
    return { scope: "provider", resetsAt: resets(plan), message: error?.message }
  }

  private async stopTurn(active: Active) {
    const rpc = await this.agent.rpc().catch(() => undefined)
    if (rpc && active.turnID && this.nativeID) await rpc.request("turn/interrupt", { threadId: this.nativeID, turnId: active.turnID }, 10_000).catch(() => {})
  }

  async interrupt() {
    const active = this.active
    if (!active || !this.nativeID) return
    active.stopping = true
    const rpc = await this.agent.rpc().catch(() => undefined)
    for (let waited = 0; waited < 10_000 && !active.turnID && this.active === active; waited += 100) await Bun.sleep(100)
    if (rpc && active.turnID) await rpc.request("turn/interrupt", { threadId: this.nativeID, turnId: active.turnID }, 10_000).catch(() => {})
    for (let waited = 0; waited < 10_000 && this.active === active; waited += 100) await Bun.sleep(100)
    if (this.active === active) {
      this.active = undefined
      active.resolve({ outcome: "interrupted" })
    }
  }

  close() {
    for (const lane of this.backgroundLanes.values()) this.endSubagent(lane, "interrupted")
    this.backgroundLanes.clear()
    this.agent.forget(this.session.id)
    if (this.nativeID && this.loaded) void this.agent.rpc().then((rpc) => rpc.request("thread/unsubscribe", { threadId: this.nativeID }).catch(() => {}), () => {})
  }
}

/** A spawned agent's name from its path ("/root/wait_1" is "Wait 1"). */
export function agentTitle(path: unknown): string {
  const last = typeof path === "string" ? (path.split("/").filter(Boolean).pop() ?? "") : ""
  const words = last.replace(/[_-]+/g, " ").trim()
  return words ? words[0].toUpperCase() + words.slice(1) : ""
}

/**
 * An added account's Codex folder: your own Codex's settings, instructions, skills and history in
 * it as links (as T3 Code makes one), but its own sign-in and its own list of models.
 */
function shadowHome(home: string) {
  const own = join(homedir(), ".codex")
  const kept = new Set(["auth.json", "models_cache.json"])
  mkdirSync(home, { recursive: true, mode: 0o700 })
  const wanted = existsSync(own) ? readdirSync(own).filter((name) => !kept.has(name)) : []
  for (const name of wanted) {
    const link = join(home, name)
    const target = join(own, name)
    try {
      const stat = lstatSync(link, { throwIfNoEntry: false })
      if (stat?.isSymbolicLink() && readlinkSync(link) === target) continue
      // Something of its own there already (it made it before there was one of yours): kept.
      if (stat && !stat.isSymbolicLink()) continue
      if (stat) rmSync(link, { force: true })
      symlinkSync(target, link)
    } catch {}
  }
  // Links to what's gone from yours: gone too.
  for (const name of readdirSync(home)) {
    const link = join(home, name)
    try {
      if (lstatSync(link).isSymbolicLink() && !wanted.includes(name)) rmSync(link, { force: true })
    } catch {}
  }
}

/** The command as you'd type it: Codex runs each in your login shell (`/bin/zsh -lc "…"`). */
export function unwrapShell(command: string): string {
  const match = command.match(/^\/bin\/(?:zsh|bash|sh) -lc (["'])([\s\S]*)\1$/)
  if (!match) return command
  const inner = match[2]
  return match[1] === '"' ? inner.replace(/\\(["\\$`])/g, "$1") : inner.replace(/'"'"'/g, "'")
}

/** The first line of a prompt, short enough for a title. */
function firstLine(text: string): string {
  const line = text.trim().split("\n")[0] ?? ""
  return line.length > 80 ? line.slice(0, 79) + "…" : line
}
