// Grok's CLI, as T3 Code runs it: your own `grok`, signed in with `grok login` (SuperGrok, or an
// xAI key in XAI_API_KEY), each session one `grok agent stdio` speaking ACP.

import { homedir } from "node:os"
import { mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { providerID, type AgentAccount } from "../accounts"
import type { Agent, AgentContext, Account, SignInAttempt, Thread } from "../agent"
import { accountName, model } from "../agent"
import { AcpThread, questionFields } from "../acp"
import { grokProgram, installGrok, managedNote, onMachine } from "../machine"
import { maintenance, update, type MaintenanceDefinition } from "../maintenance"
import { plain, run, which } from "../proc"
import { commandSignIn } from "../signin"
import type { Model, Session } from "../wire"

const places = [join(homedir(), ".grok/bin"), join(homedir(), ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin"]

export class GrokAgent implements Agent {
  id = "grok"
  readonly providerID: string
  get name() {
    return accountName("Grok", this.instance)
  }
  // (On a machine, Kuvo Code installs it.)
  install = onMachine ? undefined : "npm install -g @xai-official/grok"
  private status?: { at: number; signedIn: boolean; models: { id: string; name: string; isDefault: boolean }[] }
  private promptCount = 0

  /** Each model's reasoning efforts and its default, as its sessions said last (kept in Kuvo Code's folder). */
  private get effortsFile() {
    return join(this.context.home, "grok", `efforts-${this.instance.id}.json`)
  }

  private efforts(): Record<string, { values: string[]; default?: string }> {
    try {
      return JSON.parse(readFileSync(this.effortsFile, "utf8"))
    } catch {
      return {}
    }
  }

  /** Keeps what a session says of its models' efforts, for the model picker. */
  saveEfforts(setup: any) {
    const known: Record<string, { values: string[]; default?: string }> = {}
    for (const info of setup?.models?.availableModels ?? []) {
      const levels: any[] = info?._meta?.reasoningEfforts ?? []
      if (!info?.modelId || !levels.length) continue
      known[info.modelId] = { values: levels.map((level) => String(level.value)), default: levels.find((level) => level.default)?.value ?? info._meta?.reasoningEffort }
    }
    if (!Object.keys(known).length || JSON.stringify(known) === JSON.stringify(this.efforts())) return
    try {
      mkdirSync(dirname(this.effortsFile), { recursive: true })
      writeFileSync(this.effortsFile, JSON.stringify(known))
    } catch {}
  }

  constructor(
    readonly context: AgentContext,
    readonly instance: AgentAccount = { id: "default" },
  ) {
    this.providerID = providerID("grok", instance.id)
  }

  executable(): string | undefined {
    return onMachine ? grokProgram(this.context.deps) : which("grok", places)
  }

  /** Its program, installed first on a machine (where Kuvo Code keeps its own copy). */
  async installedProgram(): Promise<string | undefined> {
    return onMachine ? installGrok(this.context.deps) : this.executable()
  }

  /** Its own installer puts it in `~/.grok`: `grok update`. */
  private get definition(): MaintenanceDefinition | undefined {
    const executable = this.executable()
    if (!executable) return undefined
    return { name: "Grok's CLI", executable, npmPackage: "@xai-official/grok", nativeUpdate: { args: ["update"], isNative: (path) => path.includes("/.grok/") } }
  }

  async maintenance(fresh = false) {
    const definition = this.definition
    return definition && !onMachine ? maintenance(definition, fresh) : {}
  }

  async update() {
    if (onMachine) return { updated: false, message: managedNote }
    const definition = this.definition
    if (!definition) return { updated: false, message: "Grok's CLI isn't installed." }
    return update(definition, this.context.temporary)
  }

  /** Counts updates of Grok's CLI: a session's agent started before the last one starts again. */
  program = 0

  /** Its models asked of the new CLI; sessions start it at their next message. */
  programUpdated() {
    this.program++
    this.status = undefined
  }

  methods() {
    return [{ type: "oauth" as const, id: "grok", label: "Sign in with Grok" }]
  }

  env(): Record<string, string | undefined> {
    // An added account's own GROK_HOME: its sign-in and sessions there.
    return { ...process.env, GROK_DISABLE_AUTOUPDATER: "1", ...(this.instance.home ? { GROK_HOME: this.instance.home } : {}) }
  }

  /** `grok models` says whether you're signed in, and lists your models. */
  private async read(fresh: boolean) {
    if (!fresh && this.status && Date.now() - this.status.at < 30_000) return this.status
    const executable = this.executable()!
    const result = await run(executable, ["models"], { env: this.env(), timeout: 20_000, cwd: this.context.temporary })
    const text = plain(result.stdout + "\n" + result.stderr)
    const signedIn = Boolean(process.env.XAI_API_KEY) || (/you are logged in/i.test(text) && !/not authenticated|not logged in/i.test(text))
    const models: { id: string; name: string; isDefault: boolean }[] = []
    for (const line of text.split("\n")) {
      const match = line.match(/^\s*[*-]\s+(\S+)(.*)$/)
      if (match) models.push({ id: match[1], name: match[1], isDefault: /\(default\)/i.test(match[2]) })
    }
    this.status = { at: Date.now(), signedIn, models }
    return this.status
  }

  async account(fresh = false): Promise<Account> {
    if (!this.executable() && onMachine) return { installed: true, signedIn: false, message: "Sign in to Grok with your SuperGrok plan. Kuvo Code installs its CLI on this machine first." }
    if (!this.executable()) return { installed: false, signedIn: false, message: "Install Grok's CLI, then sign in here." }
    const status = await this.read(fresh)
    if (!status.signedIn) return { installed: true, signedIn: false, message: "Sign in to Grok with your SuperGrok plan." }
    return { installed: true, signedIn: true, label: process.env.XAI_API_KEY ? "xAI API key" : "grok.com" }
  }

  async signIn(): Promise<SignInAttempt> {
    const executable = await this.installedProgram()
    if (!executable) throw new Error("Install Grok's CLI first: npm install -g @xai-official/grok")
    return commandSignIn({
      command: executable,
      args: ["login"],
      env: this.env(),
      home: this.context.home,
      temporary: this.context.temporary,
      instructions: "Finish signing in to Grok in your browser. Grok's CLI keeps the sign-in, as when you run grok login.",
      signedIn: async () => (await this.read(true)).signedIn,
    })
  }

  async models(): Promise<Model[]> {
    const status = await this.read(false)
    const efforts = this.efforts()
    // (Before a session has said, the efforts every Grok model has.)
    return status.models.map((info, index) => model(this.providerID, info.id, info.name, { released: info.isDefault ? 1000 : 500 - index, context: 256_000, variants: efforts[info.id]?.values ?? ["low", "medium", "high"] }))
  }

  thread(session: Session, state: Record<string, unknown>): Thread {
    const agent = this
    return new AcpThread(
      {
        fileSystem: false,
        initializeMeta: { clientType: "extension" },
        authMethod: () => (process.env.XAI_API_KEY ? "xai.api_key" : "cached_token"),
        restartAfterInterrupt: true,
        program: () => agent.program,
        async command({ approvesAll, plan }) {
          const executable = await agent.installedProgram()
          if (!executable) throw new Error("Install Grok's CLI first: npm install -g @xai-official/grok")
          const argv = plan
            ? [executable, "--permission-mode", "plan", "agent", "stdio"]
            : approvesAll
              ? [executable, "agent", "--always-approve", "stdio"]
              : [executable, "--permission-mode", "default", "agent", "stdio"]
          return { argv, env: agent.env() }
        },
        async selectModel(rpc, sessionId, modelID, setup, variant) {
          agent.saveEfforts(setup)
          if (setup?.models?.currentModelId !== modelID) {
            await rpc.request("session/set_model", { sessionId, modelId: modelID }, 30_000)
            if (setup?.models) setup.models.currentModelId = modelID
          }
          // Its reasoning effort: the one you picked, or (after one was) the model's own.
          const option = (setup?.configOptions ?? []).find((option: any) => option.id === "reasoning_effort" || option.category === "thought_level")
          const wanted = variant ?? (setup?.kuvoEffort ? agent.efforts()[modelID]?.default : undefined)
          const key = `${modelID}:${variant ?? ""}`
          if (!option || !wanted || setup.kuvoEffort === key) return
          await rpc.request("session/set_config_option", { sessionId, configId: option.id, value: wanted }, 30_000)
          setup.kuvoEffort = variant ? key : undefined
        },
        promptMeta() {
          const id = `kuvo-prompt-${++agent.promptCount}`
          return { promptId: id, requestId: id }
        },
        notification(method, params, context) {
          // Grok can say the prompt is over before answering it.
          const name = method.replace(/^_/, "")
          // One it ran on its own after a task of its own completed: that turn's end.
          if (name === "x.ai/session/prompt_complete" && String(params?.promptId ?? "").startsWith("task-completed-")) context.endOwn()
          if (name === "x.ai/session/prompt_complete" && !String(params?.promptId ?? "").startsWith("task-completed-")) {
            context.endPrompt(params?.stopReason ?? "end_turn", params?.stopReason === "rate_limit" ? "You've reached your Grok usage limit for now." : params?.stopReason === "error" ? String(params?.agentResult ?? "Grok stopped with an error.") : undefined, params?.promptId)
          }
        },
        request(method, params, context) {
          const name = method.replace(/^_/, "")
          const call = params?.params ?? params
          if (name === "x.ai/ask_user_question") {
            return (async () => {
              const questions = call?.questions ?? []
              const answer = context.hooks ? await context.hooks.question({ title: "Question", fields: questionFields(questions), toolCallID: call?.toolCallId }) : null
              if (!answer) return { outcome: "cancelled" }
              const answers: Record<string, string[]> = {}
              questions.forEach((question: any, index: number) => {
                const value = answer[question.id ?? `q${index}`]
                answers[question.question] = Array.isArray(value) ? value.map(String) : value === undefined ? [] : [String(value)]
              })
              return { outcome: "accepted", answers }
            })()
          }
          if (name === "x.ai/exit_plan_mode") {
            // Its plan, shown (it says the plan is in front of you).
            const plan = [call?.plan, call?.planText, call?.content].find((value) => typeof value === "string" && value.trim())
            if (plan && context.turn) {
              context.turn.text(plan)
              context.turn.endBlock()
            }
            return Promise.resolve({ outcome: "abandoned", feedback: "The plan is shown to the user. Stop here and wait: they'll switch out of plan mode and ask you to build it when they're ready." })
          }
          return undefined
        },
      },
      session,
      state,
      this.name,
    )
  }
}
