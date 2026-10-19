// Claude Code, with the Claude Agent SDK, as T3 Code runs it: your own `claude`, signed in with
// your own plan or key (`claude auth login`), one long-lived Claude Code per session fed message
// by message, its replies streamed into the session as the engine's own would be.

import { randomUUID } from "node:crypto"
import { existsSync, readFileSync, statSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import { providerID, type AgentAccount } from "../accounts"
import type { Agent, AgentContext, Account, RunInput, RunResult, SignInAttempt, Thread, TurnHooks } from "../agent"
import type { Limit } from "../auto"
import { accountName, failure, model } from "../agent"
import { fileDiff, fromPatch } from "../diff"
import { maintenance, update, type MaintenanceDefinition } from "../maintenance"
import { emit } from "../events"
import { run, which } from "../proc"
import { Queue } from "../queue"
import { commandSignIn } from "../signin"
import type { Turn } from "../turn"
import type { FileDiff, FormField, Model, Session, TokenUsage } from "../wire"

const SDK = [{ name: "@anthropic-ai/claude-agent-sdk", version: "0.3.303" }]
const places = [join(homedir(), ".local/bin"), join(homedir(), ".claude/local"), "/opt/homebrew/bin", "/usr/local/bin"]
/** Kept of a tool's output: enough to read, not a whole file's worth. */
const outputLimit = 30_000

interface Status {
  loggedIn?: boolean
  authMethod?: string
  email?: string
  subscriptionType?: string
  apiProvider?: string
}

export class ClaudeAgent implements Agent {
  id = "claude"
  readonly providerID: string
  get name() {
    return accountName("Claude Code", this.instance)
  }
  install = "curl -fsSL https://claude.ai/install.sh | bash"
  private status?: { at: number; status: Status }
  /**
   * When Claude last turned its sign-in away in a run ("OAuth access token has been revoked"):
   * `claude auth status` still says signed in then. Until Claude Code writes its settings again
   * (as signing in does), the account says it needs a sign-in.
   */
  authFailedAt?: number
  private modelList?: { at: number; models: Model[] }
  private loadingModels?: Promise<void>

  constructor(
    readonly context: AgentContext,
    readonly instance: AgentAccount = { id: "default" },
  ) {
    this.providerID = providerID("claude", instance.id)
  }

  executable(): string | undefined {
    return which("claude", places)
  }

  /** Its own installer puts it in `~/.local/share/claude` (or `~/.claude/local`): `claude update`. */
  private get definition(): MaintenanceDefinition | undefined {
    const executable = this.executable()
    if (!executable) return undefined
    return {
      name: "Claude Code",
      executable,
      npmPackage: "@anthropic-ai/claude-code",
      nativeUpdate: { args: ["update"], isNative: (path) => /\/\.local\/share\/claude\/|\/\.claude\/local\//.test(path) },
    }
  }

  async maintenance(fresh = false) {
    const definition = this.definition
    return definition ? maintenance(definition, fresh) : {}
  }

  async update() {
    const definition = this.definition
    if (!definition) return { updated: false, message: "Claude Code isn't installed." }
    const result = await update(definition, this.context.temporary)
    // Its models are the new Claude Code's.
    if (result.updated) this.modelList = undefined
    return result
  }

  methods() {
    return [
      { type: "oauth" as const, id: "claudeai", label: "Sign in with your Claude plan" },
      { type: "oauth" as const, id: "console", label: "Sign in with Anthropic Console" },
    ]
  }

  private async readStatus(fresh: boolean): Promise<Status> {
    if (!fresh && this.status && Date.now() - this.status.at < 30_000) return this.status.status
    const executable = this.executable()
    if (!executable) return {}
    const result = await run(executable, ["auth", "status", "--json"], { timeout: 20_000, env: this.env() })
    let status: Status = {}
    try {
      status = JSON.parse(result.stdout)
    } catch {}
    this.status = { at: Date.now(), status }
    return status
  }

  async account(fresh = false): Promise<Account> {
    if (!this.executable()) {
      return { installed: false, signedIn: false, message: "Install Claude Code, then sign in here." }
    }
    const status = await this.readStatus(fresh)
    if (!status.loggedIn) return { installed: true, signedIn: false, message: "Sign in to Claude Code with your Claude plan or an Anthropic Console account." }
    // (The run that was turned away writes them too as it ends: a minute's grace for that.)
    if (this.authFailedAt && this.settingsWritten() <= this.authFailedAt + 60_000) {
      return { installed: true, signedIn: false, ended: true, message: "Claude ended this sign-in. Sign in again." }
    }
    const plan = status.subscriptionType ? `${status.subscriptionType.charAt(0).toUpperCase()}${status.subscriptionType.slice(1)} plan` : undefined
    const who = status.email ?? (status.apiProvider && status.apiProvider !== "firstParty" ? status.apiProvider : undefined)
    return { installed: true, signedIn: true, label: [who, plan].filter(Boolean).join(" · ") || "Claude Code" }
  }

  /** Paid per token (an API key), rather than by a plan. */
  usesKey() {
    const method = this.status?.status.authMethod ?? ""
    return method !== "" && method !== "claude.ai"
  }

  /** When Claude Code last wrote its settings (signing in does). */
  private settingsWritten(): number {
    const folder = this.instance.home ?? homedir()
    try {
      return statSync(join(folder, ".claude.json")).mtimeMs
    } catch {
      return 0
    }
  }

  async signIn(methodID: string): Promise<SignInAttempt> {
    const executable = this.executable()
    if (!executable) throw new Error("Install Claude Code first: curl -fsSL https://claude.ai/install.sh | bash")
    // Signing in again: its end says how it went (another Claude Code writing its settings meanwhile isn't it).
    this.authFailedAt = undefined
    return commandSignIn({
      command: executable,
      args: ["auth", "login", methodID === "console" ? "--console" : "--claudeai"],
      env: this.env(),
      home: this.context.home,
      temporary: this.context.temporary,
      instructions: "Finish signing in on Claude's page. Claude Code keeps the sign-in, as when you run claude auth login.",
      signedIn: async () => (await this.account(true)).signedIn,
    })
  }

  async sdk(): Promise<typeof import("@anthropic-ai/claude-agent-sdk")> {
    // Without its own copy of Claude Code: it runs yours.
    await this.context.deps.ensure(this.id, SDK, { optional: false })
    return this.context.deps.load(this.id, SDK[0].name)
  }

  /** Claude Code's environment: an added account's own folder (Claude Code keeps its sign-in in the Keychain, named after it). */
  env(): Record<string, string | undefined> {
    const env: Record<string, string | undefined> = { ...process.env, CLAUDE_CODE_TMPDIR: join(this.context.temporary, "claude") }
    if (this.instance.home) env.CLAUDE_CONFIG_DIR = this.instance.home
    return env
  }

  /** An added account signs out as it goes (its Keychain item with it). */
  async removeAccount() {
    const executable = this.executable()
    if (executable && this.instance.home) await run(executable, ["auth", "logout"], { timeout: 20_000, env: this.env() }).catch(() => {})
  }

  async models(): Promise<Model[]> {
    if (this.modelList && Date.now() - this.modelList.at < 30 * 60_000) return this.modelList.models
    // Claude Code says which models your account has once it starts: asked in the background, the
    // first time with Claude Code's usual ones meanwhile.
    this.loadingModels ??= this.loadModels().finally(() => (this.loadingModels = undefined))
    return this.modelList?.models ?? fallbackModels(this.providerID)
  }

  private async loadModels() {
    const sdk = await this.sdk()
    const abort = new AbortController()
    const idle = (async function* () {
      await new Promise((resolve) => abort.signal.addEventListener("abort", resolve))
    })()
    const q = sdk.query({
      prompt: idle as AsyncIterable<any>,
      options: {
        pathToClaudeCodeExecutable: this.executable(),
        cwd: this.context.temporary,
        persistSession: false,
        abortController: abort,
        allowedTools: [],
        mcpServers: {},
        strictMcpConfig: true,
        settings: { disableAllHooks: true } as any,
        env: this.env(),
        stderr: () => {},
      },
    })
    try {
      const init: any = await Promise.race([q.initializationResult(), Bun.sleep(30_000).then(() => undefined)])
      const list = (init?.models ?? []) as { value: string; displayName: string; description?: string; supportedEffortLevels?: string[] }[]
      if (list.length) {
        this.modelList = {
          at: Date.now(),
          models: list.map((info, index) =>
            model(this.providerID, info.value, modelName(info), {
              family: family(modelName(info)),
              variants: info.supportedEffortLevels,
              images: true,
              context: /1M/i.test(info.description ?? "") ? 1_000_000 : 200_000,
              // Listed in Claude Code's order: the first is its default.
              released: Date.now() - index,
            }),
          ),
        }
        emit("model.updated", {})
      }
    } finally {
      abort.abort()
    }
  }

  forgetModels() {
    this.modelList = undefined
  }

  thread(session: Session, state: Record<string, unknown>): Thread {
    return new ClaudeThread(this, session, state)
  }
}

function modelName(info: { value: string; displayName: string; description?: string }): string {
  // "Default (recommended)" says less than what it is: "Opus 4.8 with 1M context · Most capable…".
  const what = info.description?.split(" · ")[0]?.trim()
  if (what && /^(opus|sonnet|haiku|fable|claude)/i.test(what)) return what
  return info.displayName
}

/** Its family, for its maker's mark and so each shows in the short list: "claude-opus". */
function family(name: string): string {
  return "claude-" + (name.split(/\s+/)[0] ?? "").toLowerCase()
}

function fallbackModels(providerID: string): Model[] {
  return [
    model(providerID, "default", "Claude Code's default", { family: "claude-default", images: true, variants: ["low", "medium", "high", "xhigh", "max"], released: 3 }),
    model(providerID, "sonnet", "Sonnet", { family: "claude-sonnet", images: true, variants: ["low", "medium", "high", "max"], released: 2 }),
    model(providerID, "haiku", "Haiku", { family: "claude-haiku", images: true, released: 1 }),
  ]
}

// MARK: A session

interface Active {
  turn: Turn
  hooks: TurnHooks
  resolve: (result: RunResult) => void
  /** Steps (Claude's messages) already told as they streamed. */
  streamed: Set<string>
  /** The streamed message's tool calls, by their block's index. */
  blockTools: Map<number, string>
  /** Each tool call's Claude name and input, for its result. */
  calls: Map<string, { name: string; input: Record<string, any> }>
  usage?: TokenUsage
  stopReason?: string
  /** Why the turn will fail, if Claude Code says before its result. */
  problem?: string
  /** A usage limit it reached (Auto goes on with the next model). */
  limit?: Limit
  /** On Auto: a limit ends the turn rather than being waited out. */
  auto?: boolean
  /** You pressed Stop. */
  stopping?: boolean
}

class ClaudeThread implements Thread {
  private query?: any
  private input?: Queue<any>
  private active?: Active
  private opened?: { model: string; effort?: string; plan: boolean; append: string }

  constructor(
    private readonly agent: ClaudeAgent,
    private readonly session: Session,
    private readonly state: Record<string, unknown>,
  ) {}

  async run(input: RunInput, turn: Turn, hooks: TurnHooks): Promise<RunResult> {
    const sdk = await this.agent.sdk()
    // Stopped while its SDK was coming.
    if (hooks.signal.aborted) return { outcome: "interrupted" }
    const modelID = input.model.id
    const effort = input.model.variant
    const append = hooks.instructions()
    // What the app adds to its instructions changed (a worktree, the project's folders): Claude
    // Code starts again with them, going on with the same conversation.
    if (this.query && this.opened?.append !== append) this.close()
    if (!this.query) {
      this.open(sdk, modelID, effort, input.plan, append, hooks)
    } else {
      // The same Claude Code goes on, told what changed.
      if (this.opened?.model !== modelID) await this.query.setModel(modelID === "default" ? undefined : modelID).catch(() => {})
      if (this.opened?.effort !== effort) await this.query.applyFlagSettings({ effortLevel: effort ?? null }).catch(() => {})
      if (this.opened?.plan !== input.plan) await this.query.setPermissionMode(input.plan ? "plan" : "default").catch(() => {})
      this.opened = { model: modelID, effort, plan: input.plan, append }
    }
    if (hooks.signal.aborted) return { outcome: "interrupted" }
    return new Promise<RunResult>((resolve) => {
      this.active = { turn, hooks, resolve, streamed: new Set(), blockTools: new Map(), calls: new Map(), auto: input.auto }
      this.input!.push(userMessage(input))
    })
  }

  private open(sdk: any, modelID: string, effort: string | undefined, plan: boolean, append: string, hooks: TurnHooks) {
    let id = this.state.claudeSession as string | undefined
    const resume = Boolean(id && this.state.claudeStarted)
    if (!id) {
      id = randomUUID()
      this.state.claudeSession = id
      hooks.saveState()
    }
    // A new conversation counts its cost from nothing.
    if (!resume) delete this.state.claudeCost
    this.input = new Queue()
    this.opened = { model: modelID, effort, plan, append }
    this.query = sdk.query({
      prompt: this.input,
      options: {
        pathToClaudeCodeExecutable: this.agent.executable(),
        cwd: this.session.location.directory,
        model: modelID === "default" ? undefined : modelID,
        effort,
        includePartialMessages: true,
        permissionMode: plan ? "plan" : "default",
        canUseTool: (name: string, input: Record<string, unknown>, options: any) => this.canUseTool(name, input, options),
        systemPrompt: { type: "preset", preset: "claude_code", ...(append ? { append } : {}) },
        ...(resume ? { resume: id } : { sessionId: id }),
        env: this.agent.env(),
        stderr: () => {},
      },
    })
    void this.read(this.query)
  }

  private async read(query: any) {
    let ended: unknown
    try {
      for await (const message of query) this.handle(message)
    } catch (error) {
      ended = error
    }
    if (this.query === query) {
      this.query = undefined
      this.input = undefined
    }
    // Ended under a turn of this Claude Code (not one started since on a new one).
    const active = this.active
    if (!active || this.query) return
    this.active = undefined
    if (active.stopping || active.hooks.signal.aborted) active.resolve({ outcome: "interrupted" })
    else if (active.limit) active.resolve({ outcome: "failed", error: { type: "limit", message: active.problem ?? "You've reached a Claude usage limit." }, limit: active.limit })
    else active.resolve({ outcome: "failed", error: failure(active.problem ?? ended ?? "Claude Code stopped.") })
  }

  private handle(message: any) {
    if (message.type === "system" && message.subtype === "init") {
      if (!this.state.claudeStarted || this.state.claudeSession !== message.session_id) {
        this.state.claudeSession = message.session_id
        this.state.claudeStarted = true
        this.active?.hooks.saveState()
      }
      return
    }
    const active = this.active
    if (!active) return
    // A subagent's own work shows as its tool call, not in the conversation.
    if (message.parent_tool_use_id) return
    const turn = active.turn
    switch (message.type) {
      case "stream_event":
        return this.stream(active, message.event)
      case "assistant": {
        const content = message.message?.content ?? []
        const id = message.message?.id
        if (message.error === "authentication_failed" || message.message?.error === "authentication_failed") {
          this.agent.authFailedAt = Date.now()
          active.problem = "Claude Code isn't signed in. Sign in again in Settings › Accounts."
        }
        for (const block of content) {
          if (block.type === "tool_use") {
            active.calls.set(block.id, { name: block.name, input: block.input ?? {} })
            const tool = kuvoTool(block.name, block.input ?? {})
            if (!turn.hasTool(block.id)) turn.toolStart(block.id, tool.name)
            turn.toolCalled(block.id, tool.input)
          } else if (!id || !active.streamed.has(id)) {
            // Not streamed (it came whole): told now.
            if (block.type === "text" && block.text) turn.text(block.text)
            else if (block.type === "thinking" && block.thinking) turn.reasoning(block.thinking)
          }
        }
        if (id && !active.streamed.has(id)) turn.endBlock()
        return
      }
      case "user": {
        const content = Array.isArray(message.message?.content) ? message.message.content : []
        const results = content.filter((block: any) => block.type === "tool_result")
        for (const block of results) this.result(active, block, results.length === 1 ? message.tool_use_result : undefined)
        return
      }
      case "rate_limit_event": {
        const info = message.rate_limit_info ?? {}
        // Over the plan's limit, unless extra usage you pay for carries on.
        if (info.status !== "rejected" || info.overageInUse || info.isUsingOverage) return
        const resetsAt = typeof info.resetsAt === "number" ? info.resetsAt * 1000 : undefined
        const oneModel = info.rateLimitType === "seven_day_opus" || info.rateLimitType === "seven_day_sonnet"
        active.limit = { scope: oneModel ? "model" : "provider", resetsAt, message: limitWords(info.rateLimitType) }
        active.problem = limitWords(info.rateLimitType)
        if (active.auto) void this.query?.interrupt().catch(() => {})
        return
      }
      case "system":
        // Waiting out a rate limit to try again: on Auto, the next model goes on instead.
        if (message.subtype === "api_retry" && (message.error === "rate_limit" || message.error === "billing_error") && active.auto) {
          active.limit ??= message.error === "billing_error" ? { scope: "provider" } : { scope: "model", brief: true }
          active.problem ??= "Claude's API is rate limiting this model."
          void this.query?.interrupt().catch(() => {})
        }
        return
      case "result":
        return this.finish(active, message)
    }
  }

  private stream(active: Active, event: any) {
    const turn = active.turn
    switch (event?.type) {
      case "message_start": {
        active.streamed.add(event.message?.id)
        active.blockTools.clear()
        const usage = event.message?.usage ?? {}
        active.usage = {
          input: usage.input_tokens ?? 0,
          output: usage.output_tokens ?? 0,
          reasoning: 0,
          cache: { read: usage.cache_read_input_tokens ?? 0, write: usage.cache_creation_input_tokens ?? 0 },
        }
        active.stopReason = undefined
        turn.startStep()
        return
      }
      case "content_block_start": {
        const block = event.content_block
        if (block?.type === "tool_use") {
          active.blockTools.set(event.index, block.id)
          turn.toolStart(block.id, kuvoTool(block.name, {}).name)
        }
        return
      }
      case "content_block_delta": {
        const delta = event.delta
        if (delta?.type === "text_delta") turn.text(delta.text)
        else if (delta?.type === "thinking_delta") turn.reasoning(delta.thinking)
        else if (delta?.type === "input_json_delta") {
          const id = active.blockTools.get(event.index)
          if (id) turn.toolInputDelta(id, delta.partial_json ?? "")
        }
        return
      }
      case "content_block_stop":
        turn.endBlock()
        return
      case "message_delta":
        if (active.usage && event.usage?.output_tokens !== undefined) active.usage.output = event.usage.output_tokens
        active.stopReason = event.delta?.stop_reason ?? active.stopReason
        return
      case "message_stop":
        turn.endStep({ tokens: active.usage, finish: active.stopReason === "tool_use" ? "tool-calls" : active.stopReason ?? "stop" })
        return
    }
  }

  private result(active: Active, block: any, structured: any) {
    const turn = active.turn
    const id = block.tool_use_id
    const call = active.calls.get(id)
    let text = toolText(block.content)
    if (text.length > outputLimit) text = text.slice(0, outputLimit) + "\n…"
    if (block.is_error) {
      turn.toolFailed(id, text || "The tool failed.")
      return
    }
    const metadata: Record<string, unknown> = {}
    const files = call ? diffs(call.name, call.input, structured) : []
    if (files.length) metadata.files = files
    if (call?.name === "Bash" && structured) {
      const output = [structured.stdout, structured.stderr].filter((part: string) => part).join("\n")
      if (output) text = output.length > outputLimit ? output.slice(0, outputLimit) + "\n…" : output
    }
    turn.toolSucceeded(id, text, Object.keys(metadata).length ? metadata : undefined)
  }

  private finish(active: Active, result: any) {
    this.active = undefined
    this.addCost(active, result)
    const succeeded = result.subtype === "success" && !result.is_error
    // A turn that went through went through, whatever was said of limits on the way.
    if (succeeded && !active.stopping && !active.hooks.signal.aborted) {
      active.resolve({ outcome: "succeeded" })
      return
    }
    // Its words for a limit, when it stopped: "Claude AI usage limit reached|<when it resets>".
    const text = !succeeded && typeof result.result === "string" ? result.result : ""
    const reached = /usage limit reached\|?(\d+)?/i.exec(text)
    if (!succeeded && !active.limit && (reached || result.api_error_status === 429)) {
      const resetsAt = reached?.[1] ? Number(reached[1]) * 1000 : undefined
      active.limit = { scope: "provider", resetsAt }
      active.problem ??= "You've reached your Claude usage limit for now."
    }
    if (active.limit && !active.stopping) {
      active.resolve({ outcome: "failed", error: { type: "limit", message: active.problem ?? "You've reached a Claude usage limit." }, limit: active.limit })
      return
    }
    if (active.stopping || active.hooks.signal.aborted) {
      active.resolve({ outcome: "interrupted" })
      return
    }
    const message =
      active.problem ??
      (typeof result.result === "string" && result.result.trim() ? result.result.trim() : undefined) ??
      (Array.isArray(result.errors) && result.errors.length ? result.errors.join("\n") : undefined) ??
      reason(result)
    active.resolve({ outcome: "failed", error: { type: "agent", message } })
  }

  /**
   * What the turn cost, with an API key: Claude Code says what its whole query has cost so far
   * (from where a resumed conversation's transcript left it), so it's the difference.
   */
  private addCost(active: Active, result: any) {
    const total = typeof result.total_cost_usd === "number" ? result.total_cost_usd : undefined
    if (total === undefined) return
    const before = typeof this.state.claudeCost === "number" ? this.state.claudeCost : 0
    // Smaller than before: it started counting again (a new conversation, /clear).
    const spent = total >= before ? total - before : total
    this.state.claudeCost = total
    active.hooks.saveState()
    if (spent > 0 && this.agent.usesKey()) active.turn.addUsage(undefined, spent)
  }

  private async canUseTool(name: string, input: Record<string, any>, options: any): Promise<any> {
    const active = this.active
    const toolUseID = options?.toolUseID
    if (!active) return { behavior: "deny", message: "There's no turn under way for this.", toolUseID }
    const hooks = active.hooks
    if (name === "AskUserQuestion") {
      const questions = (input.questions ?? []) as { question: string; header?: string; options?: { label: string; description?: string }[]; multiSelect?: boolean }[]
      const fields: FormField[] = questions.map((question, index) => ({
        key: `q${index}`,
        title: question.header ?? `Question ${index + 1}`,
        description: question.question,
        required: true,
        type: question.multiSelect ? "multiselect" : "string",
        options: (question.options ?? []).map((option) => ({ value: option.label, label: option.label, description: option.description })),
        custom: true,
      }))
      const answer = await hooks.question({ title: questions.length === 1 ? questions[0].header ?? "Question" : "Questions", fields, toolCallID: toolUseID })
      if (!answer) return { behavior: "deny", message: "The user dismissed the question.", toolUseID }
      const answers: Record<string, string> = {}
      questions.forEach((question, index) => {
        const value = answer[`q${index}`]
        answers[question.question] = Array.isArray(value) ? value.join(", ") : String(value ?? "")
      })
      return { behavior: "allow", updatedInput: { ...input, answers }, toolUseID }
    }
    if (name === "ExitPlanMode") {
      // The plan shows in the conversation; building starts when you switch to Build and say so.
      return {
        behavior: "deny",
        message: "The plan is shown to the user. Stop here and wait: they'll switch out of plan mode and ask you to build it when they're ready.",
        toolUseID,
      }
    }
    const ask = permissionAsk(name, input)
    const decision = await hooks.permission({ toolCallID: toolUseID, ...ask, message: options?.title ?? options?.description })
    if (decision === "reject") return { behavior: "deny", message: "The user declined this.", toolUseID }
    const result: any = { behavior: "allow", updatedInput: input, toolUseID }
    if (decision === "always" && Array.isArray(options?.suggestions)) {
      result.updatedPermissions = options.suggestions.map((suggestion: any) => ({ ...suggestion, destination: "session" }))
    }
    return result
  }

  async interrupt() {
    const query = this.query
    const active = this.active
    if (!query || !active) return
    active.stopping = true
    await query.interrupt().catch(() => {})
    // Claude Code ends the turn with a result; one that doesn't is stopped (this turn's Claude
    // Code, not one a later message started).
    for (let waited = 0; waited < 5_000 && this.active === active; waited += 100) await Bun.sleep(100)
    if (this.active === active && this.query === query) {
      this.close()
      this.active = undefined
      active.resolve({ outcome: "interrupted" })
    }
  }

  close() {
    this.input?.close()
    try {
      this.query?.close?.()
    } catch {}
    this.query = undefined
    this.input = undefined
  }
}

// MARK: Tools, as the app knows them

/** Claude Code's tool, by the engine's name for its kind, with its input as the app reads it. */
export function kuvoTool(name: string, input: Record<string, any>): { name: string; input: Record<string, unknown> } {
  switch (name) {
    case "Bash":
      return { name: "shell", input: { command: input.command, description: input.description } }
    case "Read":
      return { name: "read", input: { path: input.file_path, offset: input.offset, limit: input.limit } }
    case "Write":
      return { name: "write", input: { path: input.file_path, content: input.content } }
    case "Edit":
      return { name: "edit", input: { path: input.file_path, oldString: input.old_string, newString: input.new_string, replaceAll: input.replace_all } }
    case "MultiEdit":
      return { name: "edit", input: { path: input.file_path, edits: input.edits } }
    case "NotebookEdit":
      return { name: "edit", input: { path: input.notebook_path, newString: input.new_source } }
    case "Glob":
      return { name: "glob", input: { pattern: input.pattern, path: input.path } }
    case "Grep":
      return { name: "grep", input: { pattern: input.pattern, path: input.path, glob: input.glob } }
    case "WebFetch":
      return { name: "webfetch", input: { url: input.url, prompt: input.prompt } }
    case "WebSearch":
      return { name: "websearch", input: { query: input.query } }
    case "Task":
    case "Agent":
      return { name: "subagent", input: { description: input.description, agent: input.subagent_type, prompt: input.prompt } }
    case "TodoWrite":
      return { name: "todowrite", input: { todos: input.todos } }
    case "AskUserQuestion":
      return { name: "question", input: { questions: input.questions } }
    case "Skill":
      return { name: "skill", input: { name: input.skill ?? input.command } }
    case "ExitPlanMode":
      return { name: "plan", input: { plan: input.plan } }
  }
  if (name.startsWith("mcp__")) {
    const [, server, ...rest] = name.split("__")
    return { name: `${server}_${rest.join("__")}`, input }
  }
  return { name: name.toLowerCase(), input }
}

function permissionAsk(name: string, input: Record<string, any>): { action: string; resources: string[]; save?: string[]; metadata?: Record<string, unknown> } {
  switch (name) {
    case "Bash":
      return { action: "shell", resources: [String(input.command ?? "")] }
    case "Edit":
    case "MultiEdit":
    case "Write":
    case "NotebookEdit": {
      const path = String(input.file_path ?? input.notebook_path ?? "")
      const preview = previewDiff(name, input)
      return { action: "edit", resources: [path], metadata: preview ? { files: [preview] } : undefined }
    }
    case "WebFetch":
      return { action: "webfetch", resources: [String(input.url ?? "")] }
    case "WebSearch":
      return { action: "websearch", resources: [String(input.query ?? "")] }
    case "Read":
    case "Glob":
    case "Grep":
    case "LS":
      return { action: "read", resources: [String(input.file_path ?? input.path ?? "*")] }
  }
  return { action: kuvoTool(name, input).name, resources: ["*"] }
}

/** What an edit would do to its file, for the permission card. */
function previewDiff(name: string, input: Record<string, any>): FileDiff | undefined {
  const path = String(input.file_path ?? "")
  if (!path) return undefined
  const before = existsSync(path) ? safeRead(path) : undefined
  if (name === "Write") return fileDiff(path, before, String(input.content ?? ""))
  if (before === undefined) return undefined
  let after = before
  const edits: { old_string: string; new_string: string; replace_all?: boolean }[] = name === "MultiEdit" ? input.edits ?? [] : [input as any]
  for (const edit of edits) {
    if (typeof edit.old_string !== "string") return undefined
    after = edit.replace_all ? after.split(edit.old_string).join(edit.new_string ?? "") : after.replace(edit.old_string, () => edit.new_string ?? "")
  }
  return fileDiff(path, before, after)
}

/** What an edit did, from Claude Code's own account of it. */
function diffs(name: string, input: Record<string, any>, structured: any): FileDiff[] {
  if (!["Edit", "MultiEdit", "Write", "NotebookEdit"].includes(name)) return []
  const path = String(structured?.filePath ?? input.file_path ?? input.notebook_path ?? "")
  if (!path) return []
  if (name === "Write" && structured?.type === "create") return [fileDiff(path, undefined, String(structured.content ?? input.content ?? ""))]
  const hunks = structured?.structuredPatch as { oldStart: number; oldLines: number; newStart: number; newLines: number; lines: string[] }[] | undefined
  if (Array.isArray(hunks) && hunks.length) {
    const patch = hunks.map((hunk) => `@@ -${hunk.oldStart},${hunk.oldLines} +${hunk.newStart},${hunk.newLines} @@\n` + hunk.lines.join("\n") + "\n").join("")
    return [fromPatch(path, patch)]
  }
  if (typeof structured?.originalFile === "string" && existsSync(path)) return [fileDiff(path, structured.originalFile, safeRead(path) ?? "")]
  return []
}

function safeRead(path: string): string | undefined {
  try {
    return readFileSync(path, "utf8")
  } catch {
    return undefined
  }
}

function toolText(content: unknown): string {
  if (typeof content === "string") return content
  if (Array.isArray(content)) {
    return content
      .map((part: any) => (part?.type === "text" ? part.text : part?.type === "image" ? "[image]" : ""))
      .filter(Boolean)
      .join("\n")
  }
  return ""
}

/** What reaching a Claude plan limit means, in words. */
function limitWords(type: string | undefined): string {
  switch (type) {
    case "five_hour":
      return "You've reached your Claude usage limit for the next few hours."
    case "seven_day_opus":
      return "You've reached this week's Opus limit on your Claude plan."
    case "seven_day_sonnet":
      return "You've reached this week's Sonnet limit on your Claude plan."
    default:
      return "You've reached your Claude usage limit for now."
  }
}

function reason(result: any): string {
  switch (result.subtype) {
    case "error_max_turns":
      return "Claude Code stopped after too many steps."
    case "error_max_budget_usd":
      return "Claude Code reached its spending limit."
    default:
      return "Claude Code stopped with an error."
  }
}

function userMessage(input: RunInput): any {
  const content: any[] = []
  const others: string[] = []
  for (const file of input.files) {
    const isImage = /^image\/(png|jpeg|gif|webp)$/.test(file.mime)
    const data = file.data ?? (isImage && file.path ? safeBase64(file.path) : undefined)
    if (isImage && data) content.push({ type: "image", source: { type: "base64", media_type: file.mime, data } })
    else if (file.path) others.push(file.path)
  }
  let text = input.text
  if (others.length) text += `\n\nAttached files:\n${others.map((path) => `- ${path}`).join("\n")}`
  content.push({ type: "text", text })
  return { type: "user", message: { role: "user", content }, parent_tool_use_id: null, uuid: randomUUID() }
}

function safeBase64(path: string): string | undefined {
  try {
    return readFileSync(path).toString("base64")
  } catch {
    return undefined
  }
}
