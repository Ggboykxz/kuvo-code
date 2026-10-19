// Cursor, with Cursor's own agent SDK (`@cursor/sdk`), as T3 Code runs it: signed in with your
// Cursor account in the browser (the SDK makes an API key for Kuvo Code) or with a Cursor API key.
// The SDK is downloaded the first time it's needed; its sign-in and its agents' conversations stay
// in the bridge's folder.

import { existsSync, mkdirSync, readFileSync, rmSync } from "node:fs"
import { join } from "node:path"
import { providerID, type AgentAccount } from "../accounts"
import type { Agent, AgentContext, Account, RunInput, RunResult, SignInAttempt, Thread, TurnHooks } from "../agent"
import { accountName, failure, model } from "../agent"
import type { Limit } from "../auto"
import { fromPatch } from "../diff"
import type { Turn } from "../turn"
import type { Model, OAuthStatus, Session } from "../wire"

// T3 Code's tested version; newer ones resolve differently under Bun.
const SDK = [{ name: "@cursor/sdk", version: "1.0.35" }]
const outputLimit = 30_000

export class CursorAgent implements Agent {
  id = "cursor"
  readonly providerID: string
  get name() {
    return accountName("Cursor", this.instance)
  }
  private accountCache?: { at: number; account: Account }
  private modelList?: { at: number; key: string; models: Model[] }
  private primed = false

  constructor(
    readonly context: AgentContext,
    readonly instance: AgentAccount = { id: "default" },
  ) {
    this.providerID = providerID("cursor", instance.id)
  }

  /** This account's folder: its sign-in and its agents' conversations. */
  private get folder() {
    return this.instance.home ?? join(this.context.home, "cursor")
  }

  /** Where the SDK's sign-in is kept: a file only you can read, in the bridge's folder. */
  private get authFile() {
    return join(this.folder, "auth.json")
  }

  methods() {
    return [
      { type: "oauth" as const, id: "browser", label: "Sign in with Cursor" },
      { type: "key" as const, label: "Use a Cursor API key" },
    ]
  }

  async sdk(): Promise<any> {
    await this.context.deps.ensure(this.id, SDK)
    return this.context.deps.load(this.id, SDK[0].name)
  }

  private async store(sdk: any) {
    mkdirSync(this.folder, { recursive: true, mode: 0o700 })
    return new sdk.FileCredentialStore(this.authFile)
  }

  /** The key to run with: CURSOR_API_KEY's, or the one your sign-in made, while it lasts. */
  async apiKey(sdk?: any): Promise<string | undefined> {
    // CURSOR_API_KEY is your own account's; an added one has only its sign-in.
    const fromEnvironment = this.instance.home ? undefined : process.env.CURSOR_API_KEY?.trim()
    if (fromEnvironment) return fromEnvironment
    if (!existsSync(this.authFile)) return undefined
    const loaded = await (await this.store(sdk ?? (await this.sdk()))).load()
    if (!loaded?.apiKey) return undefined
    if (loaded.apiKeyExpiresAtMs && loaded.apiKeyExpiresAtMs < Date.now()) return undefined
    return loaded.apiKey
  }

  async account(fresh = false): Promise<Account> {
    if ((this.instance.home || !process.env.CURSOR_API_KEY) && !existsSync(this.authFile)) {
      return { installed: true, signedIn: false, message: "Sign in with your Cursor account. Kuvo Code downloads Cursor's agent the first time." }
    }
    if (!fresh && this.accountCache && Date.now() - this.accountCache.at < 60_000) return this.accountCache.account
    const sdk = await this.sdk()
    const apiKey = await this.apiKey(sdk)
    let account: Account
    if (!apiKey) {
      account = { installed: true, signedIn: false, message: "Your Cursor sign-in expired. Sign in again." }
    } else {
      try {
        const me: any = await withTimeout(sdk.Cursor.me({ apiKey }), 15_000)
        account = { installed: true, signedIn: true, label: me?.userEmail ?? (process.env.CURSOR_API_KEY ? "Cursor API key" : "Cursor account") }
      } catch (error: any) {
        const rejected = error instanceof sdk.AuthenticationError || error?.status === 401
        account = rejected ? { installed: true, signedIn: false, message: "Cursor turned the sign-in down. Sign in again." } : { installed: true, signedIn: true, label: "Cursor account" }
      }
    }
    this.accountCache = { at: Date.now(), account }
    return account
  }

  async signIn(): Promise<SignInAttempt> {
    if (!this.instance.home && process.env.CURSOR_API_KEY) throw new Error("CURSOR_API_KEY is set in your environment: Kuvo Code uses that key.")
    const sdk = await this.sdk()
    const pending = new sdk.InMemoryCredentialStore()
    const abort = new AbortController()
    let status: OAuthStatus = { status: "pending" }
    let resolveURL: (url: string) => void = () => {}
    const url = new Promise<string>((resolve) => (resolveURL = resolve))
    sdk.Cursor.auth
      .login({ openBrowser: false, store: pending, signal: abort.signal, apiKeyName: "Kuvo Code", onLoginUrl: (link: string) => resolveURL(link) })
      .then(async () => {
        const credentials = await pending.load()
        if (!credentials) throw new Error("Cursor didn't hand over the sign-in.")
        await (await this.store(sdk)).save(credentials)
        this.accountCache = undefined
        this.modelList = undefined
        status = { status: "complete" }
      })
      .catch((error: unknown) => {
        if (status.status === "pending") status = { status: "failed", message: abort.signal.aborted ? "Cancelled." : failure(error).message }
      })
    const link = await Promise.race([url, Bun.sleep(30_000).then(() => "")])
    return {
      url: link,
      instructions: "Finish signing in to Cursor in your browser. Cursor makes an API key for Kuvo Code, kept on this Mac.",
      mode: "auto",
      status: () => status,
      cancel: () => abort.abort(),
    }
  }

  async signInWithKey(key: string) {
    const sdk = await this.sdk()
    await withTimeout(sdk.Cursor.me({ apiKey: key }), 15_000)
    await (await this.store(sdk)).save({ version: 1, backendUrl: "https://api2.cursor.sh", apiKey: key, createdAtMs: Date.now() })
    this.accountCache = undefined
    this.modelList = undefined
  }

  async signOut() {
    rmSync(this.authFile, { force: true })
    this.accountCache = undefined
    this.modelList = undefined
  }

  async models(): Promise<Model[]> {
    const sdk = await this.sdk()
    const apiKey = await this.apiKey(sdk)
    if (!apiKey) return []
    if (this.modelList && this.modelList.key === apiKey && Date.now() - this.modelList.at < 30 * 60_000) return this.modelList.models
    const list: any[] = await withTimeout(sdk.Cursor.models.list({ apiKey }), 15_000)
    const seen = new Set<string>()
    const models = list
      .filter((info) => info?.id && !seen.has(info.id) && seen.add(info.id))
      .map((info, index) => {
        const effort = (info.parameters ?? []).find((parameter: any) => parameter.id === "effort" || parameter.id === "reasoning")
        return model(this.providerID, info.id, info.id === "default" ? "Auto" : info.displayName ?? info.id, {
          variants: effort?.values?.map((value: any) => String(value.value)) ?? [],
          images: true,
          released: info.id === "default" ? 2000 : 1000 - index,
        })
      })
    this.modelList = { at: Date.now(), key: apiKey, models }
    return models
  }

  forgetModels() {
    this.modelList = undefined
  }

  /** The SDK decides once whether sandboxing works, and the first agent without it would say no. */
  async prime(sdk: any, apiKey: string, cwd: string) {
    if (this.primed) return
    this.primed = true
    try {
      const platform = await sdk.createAgentPlatform({ workspaceRef: cwd })
      const release = await platform.prewarmLocalWorkspace({ apiKey, local: { cwd, settingSources: [], sandboxOptions: { enabled: true } } })
      await release?.()
    } catch {}
  }

  agentStore(sdk: any) {
    const root = join(this.folder, "agents")
    mkdirSync(root, { recursive: true })
    return new sdk.JsonlLocalAgentStore(root)
  }

  thread(session: Session, state: Record<string, unknown>): Thread {
    return new CursorThread(this, session, state)
  }
}

// MARK: A session

interface Active {
  turn: Turn
  hooks: TurnHooks
  run?: any
  toolsSinceText: boolean
  sawText: boolean
  lastShell?: string
  output: Map<string, string>
}

class CursorThread implements Thread {
  private agent?: any
  /** Whether it was started to run its tools without asking. */
  private startedApproving?: boolean
  private active?: Active

  constructor(
    private readonly owner: CursorAgent,
    private readonly session: Session,
    private readonly state: Record<string, unknown>,
  ) {}

  /** The conversation it had couldn't be picked up again: a new one took its place. */
  private startedOver = false

  async prepare(input: RunInput, hooks: TurnHooks) {
    const sdk = await this.owner.sdk()
    const apiKey = await this.owner.apiKey(sdk)
    if (!apiKey || hooks.signal.aborted) return undefined
    if (hooks.approvesAll()) await this.owner.prime(sdk, apiKey, this.session.location.directory)
    await this.ensureAgent(sdk, this.options(sdk, input, hooks, apiKey), hooks)
    const fresh = this.startedOver
    this.startedOver = false
    return { fresh }
  }

  private options(sdk: any, input: RunInput, hooks: TurnHooks, apiKey: string) {
    const approvesAll = hooks.approvesAll()
    const selection = { id: input.model.id, ...(input.model.variant ? { params: [{ id: "effort", value: input.model.variant }] } : {}) }
    const mode = input.plan ? "plan" : "agent"
    const cwd = this.session.location.directory
    return {
      model: selection,
      name: `Kuvo Code: ${this.session.title ?? "session"}`,
      mode,
      apiKey,
      local: {
        cwd,
        autoReview: !approvesAll,
        settingSources: ["project", "user", "team", "mdm", "plugins"],
        sandboxOptions: { enabled: !approvesAll },
        enableAgentRetries: true,
        store: this.owner.agentStore(sdk),
      },
    }
  }

  /** Cursor's agent for this session: the one it had, or a new one (said by `startedOver`). */
  private async ensureAgent(sdk: any, options: any, hooks: TurnHooks) {
    const approvesAll = hooks.approvesAll()
    // Its sandbox and review are set as it starts: another approval mode starts it again.
    if (this.agent && this.startedApproving !== approvesAll) {
      try {
        this.agent.close?.()
      } catch {}
      this.agent = undefined
    }
    if (this.agent) return
    this.startedApproving = approvesAll
    const id = this.state.cursorAgent as string | undefined
    this.agent = id ? await sdk.Agent.resume(id, options).catch(() => undefined) : undefined
    if (!this.agent && id) {
      // In place of one it had: the instructions go again, and what came before is handed over.
      this.startedOver = true
      delete this.state.cursorInstructions
      delete this.state.cursorInstructed
    }
    this.agent ??= await sdk.Agent.create(options)
    if (this.state.cursorAgent !== this.agent.agentId) {
      this.state.cursorAgent = this.agent.agentId
      hooks.saveState()
    }
  }

  async run(input: RunInput, turn: Turn, hooks: TurnHooks): Promise<RunResult> {
    const sdk = await this.owner.sdk()
    const apiKey = await this.owner.apiKey(sdk)
    if (!apiKey) return { outcome: "failed", error: { type: "auth", message: "Sign in to Cursor in Settings › Accounts." } }
    if (hooks.signal.aborted) return { outcome: "interrupted" }
    const cwd = this.session.location.directory
    const approvesAll = hooks.approvesAll()
    const selection = { id: input.model.id, ...(input.model.variant ? { params: [{ id: "effort", value: input.model.variant }] } : {}) }
    const mode = input.plan ? "plan" : "agent"
    const options = this.options(sdk, input, hooks, apiKey)
    if (approvesAll) await this.owner.prime(sdk, apiKey, cwd)
    // Cursor's SDK can't stop to ask: said once, so Ask First isn't taken for what it does.
    if (!approvesAll && !input.plan && !this.state.cursorAskNoted) {
      turn.notice("Cursor can't stop to ask you before it acts here: it runs what its sandbox allows and declines the rest. Use Plan mode to have it propose changes first.")
      this.state.cursorAskNoted = true
      hooks.saveState()
    }
    await this.ensureAgent(sdk, options, hooks)
    const images = input.files
      .filter((file) => file.mime.startsWith("image/"))
      .map((file) => ({ data: file.data ?? (file.path ? readFileSync(file.path).toString("base64") : ""), mimeType: file.mime }))
      .filter((image) => image.data)
    let text = input.text
    const others = input.files.filter((file) => !file.mime.startsWith("image/") && file.path).map((file) => file.path!)
    if (others.length) text += `\n\nAttached files:\n${others.map((path) => `- ${path}`).join("\n")}`
    // The app's added instructions go with the first message, and again when they change.
    const instructions = hooks.instructions()
    const sent = typeof this.state.cursorInstructions === "string" ? this.state.cursorInstructions : this.state.cursorInstructed ? undefined : ""
    let instructed: { value: string } | undefined
    if (instructions !== sent && (instructions || sent)) {
      if (instructions) text = `${sent ? "Your instructions from Kuvo Code changed. They're now:\n\n" : ""}${instructions}\n\n${text}`
      instructed = { value: instructions }
    }
    // Kept as sent once Cursor took the message (not one it turned away before doing anything).
    const instructionsTaken = () => {
      if (!instructed) return
      this.state.cursorInstructions = instructed.value
      delete this.state.cursorInstructed
      hooks.saveState()
      instructed = undefined
    }
    if (hooks.signal.aborted) return { outcome: "interrupted" }
    const active: Active = { turn, hooks, toolsSinceText: false, sawText: false, output: new Map() }
    this.active = active
    turn.startStep()
    // Updates are handled one after another, in the order they came.
    let chain = Promise.resolve()
    const onDelta = async ({ update }: { update: any }) => {
      chain = chain.then(() => this.update(active, update)).catch(() => {})
    }
    try {
      const run = await this.agent.send(images.length ? { text, images } : text, { model: selection, mode, onDelta })
      active.run = run
      // Stopped while it was being sent.
      if (hooks.signal.aborted) await run.cancel().catch(() => {})
      const result = await run.wait()
      await chain
      if (result?.status !== "error" || active.sawText || active.output.size) instructionsTaken()
      if (!active.sawText && typeof result?.result === "string" && result.result.trim()) turn.text(result.result)
      const usage = result?.usage
      turn.endStep({
        tokens: usage
          ? { input: usage.inputTokens ?? 0, output: usage.outputTokens ?? 0, reasoning: 0, cache: { read: usage.cacheReadTokens ?? 0, write: usage.cacheWriteTokens ?? 0 } }
          : undefined,
      })
      if (hooks.signal.aborted || result?.status === "cancelled") return { outcome: "interrupted" }
      if (result?.status === "error") {
        const message = String(result.error?.message ?? "Cursor stopped with an error.")
        const limit = limitOf(message, result.error)
        return limit ? { outcome: "failed", error: { type: "limit", message }, limit } : { outcome: "failed", error: failure(message) }
      }
      return { outcome: "succeeded" }
    } catch (error: any) {
      if (active.sawText || active.output.size) instructionsTaken()
      if (hooks.signal.aborted) return { outcome: "interrupted" }
      const message = String(error?.message ?? error)
      const limit = limitOf(message, error)
      if (limit) return { outcome: "failed", error: { type: "limit", message }, limit }
      if (/Cannot use this model/i.test(message)) return { outcome: "failed", error: failure(`Cursor can't run ${input.model.id} with your account. Pick another of its models.`) }
      return { outcome: "failed", error: failure(error) }
    } finally {
      if (this.active === active) this.active = undefined
    }
  }

  /** Words after a tool begin a new step. */
  private words(active: Active) {
    active.sawText = true
    if (!active.toolsSinceText) return
    active.toolsSinceText = false
    active.turn.endStep()
    active.turn.startStep()
  }

  private async update(active: Active, update: any) {
    const turn = active.turn
    switch (update?.type) {
      case "text-delta":
        this.words(active)
        turn.text(update.text ?? "")
        return
      case "thinking-delta":
        this.words(active)
        turn.reasoning(update.text ?? "")
        return
      case "thinking-completed":
      case "step-completed":
        turn.endBlock()
        return
      case "tool-call-started":
      case "partial-tool-call":
      case "tool-call-completed": {
        const call = update.toolCall ?? {}
        const id = update.callId
        if (!id) return
        const kuvo = kuvoTool(call)
        if (!turn.hasTool(id)) {
          active.toolsSinceText = true
          turn.toolStart(id, kuvo.name, kuvo.input)
          if (call.type === "shell") active.lastShell = id
        } else {
          turn.toolCalled(id, kuvo.input)
        }
        if (update.type !== "tool-call-completed") return
        const result = call.result ?? {}
        const value = result.value ?? {}
        const failed = result.status === "error" || (call.type === "mcp" && value.isError)
        const { output, metadata } = toolResult(call, value, active.output.get(id))
        if (failed) turn.toolFailed(id, output || String(result.error?.message ?? result.error ?? "The tool failed."), metadata)
        else turn.toolSucceeded(id, output, metadata)
        return
      }
      case "shell-output-delta": {
        const id = active.lastShell
        if (!id) return
        const event = update.event ?? {}
        const chunk = [event.text, event.output, event.data, event.stdout, event.stderr, event.chunk].find((part) => typeof part === "string") ?? ""
        const output = ((active.output.get(id) ?? "") + chunk).slice(-outputLimit)
        active.output.set(id, output)
        turn.toolProgress(id, { output })
        return
      }
    }
  }

  async interrupt() {
    const active = this.active
    if (!active?.run) return
    // Not from inside an update: the SDK would stop the bridge.
    await Bun.sleep(10)
    await active.run.cancel().catch(() => {})
    for (let waited = 0; waited < 10_000 && this.active === active; waited += 100) await Bun.sleep(100)
  }

  close() {
    try {
      this.agent?.close?.()
    } catch {}
    this.agent = undefined
  }
}

/** A usage or rate limit in Cursor's error: your plan's. */
function limitOf(message: string, error: any): Limit | undefined {
  const code = String(error?.code ?? error?.name ?? "")
  if (/resource_exhausted|RateLimit/i.test(code) || /resource.?exhausted|usage limit (?:reached|exceeded)|quota exceeded|rate limit exceeded|too many requests/i.test(message)) return { scope: "provider", message }
  return undefined
}

function kuvoTool(call: any): { name: string; input: Record<string, unknown> } {
  const args = call.args ?? {}
  switch (call.type) {
    case "shell":
      return { name: "shell", input: { command: args.command } }
    case "edit":
    case "delete":
      return { name: "edit", input: { path: args.path } }
    case "write":
      return { name: "write", input: { path: args.path, content: args.fileText } }
    case "read":
      return { name: "read", input: { path: args.path } }
    case "glob":
      return { name: "glob", input: { pattern: args.globPattern, path: args.targetDirectory } }
    case "grep":
      return { name: "grep", input: { pattern: args.pattern, path: args.path } }
    case "semSearch":
      return { name: "grep", input: { pattern: args.query } }
    case "ls":
      return { name: "glob", input: { pattern: "*", path: args.path } }
    case "mcp":
      return { name: `${args.providerIdentifier}_${args.toolName}`, input: args.args ?? {} }
    case "updateTodos":
      return { name: "todowrite", input: { todos: args.todos } }
    case "task":
      return { name: "subagent", input: { description: args.description, prompt: args.prompt, agent: args.subagentType?.kind } }
    case "createPlan":
      return { name: "plan", input: { plan: args.plan } }
  }
  return { name: String(call.type ?? "tool"), input: args }
}

function toolResult(call: any, value: any, streamed?: string): { output: string; metadata?: Record<string, unknown> } {
  const args = call.args ?? {}
  switch (call.type) {
    case "shell": {
      const output = [value.stdout, value.stderr].filter((part: unknown) => typeof part === "string" && part).join("\n") || streamed || ""
      return { output: output.slice(-outputLimit), metadata: { output: output.slice(-outputLimit), exit: value.exitCode ?? 0 } }
    }
    case "edit":
      return { output: "", metadata: typeof value.diffString === "string" && value.diffString ? { files: [fromPatch(args.path, value.diffString)] } : undefined }
    case "read":
      return { output: String(value.content ?? "").slice(0, outputLimit) }
    case "glob":
      return { output: (value.files ?? []).join("\n").slice(0, outputLimit) }
    case "mcp":
      return { output: (value.content ?? []).map((part: any) => part?.text?.text ?? "").filter(Boolean).join("\n").slice(0, outputLimit) }
    case "createPlan":
      return { output: String(args.plan ?? "") }
  }
  if (typeof value === "string") return { output: value.slice(0, outputLimit) }
  return { output: "" }
}

function withTimeout<T>(promise: Promise<T>, milliseconds: number): Promise<T> {
  return Promise.race([promise, Bun.sleep(milliseconds).then(() => Promise.reject(new Error("Cursor didn't answer in time.")))])
}
