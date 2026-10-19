// Sessions with outside agents while the bridge runs: what's waiting to be sent, the turn under
// way, what it asks you, and the agents' own conversations behind each. A session can move from
// one agent to another (you pick a model of another, or Auto goes on with the next in your list):
// each agent keeps its own conversation, and gets what it hasn't seen as a handover.
//
// What's waiting goes as the engine sends it, which the app counts on: a message sent while
// nothing runs starts at once ("steer"), or waits for a nudge ("queue"); after a turn that ends
// on its own the next one starts; after Stop, or an error, nothing does until the app says.

import { createHash } from "node:crypto"
import { fileURLToPath } from "node:url"
import type { Agent, PermissionAsk, PromptFile, QuestionAsk, RunInput, RunResult, Thread, TurnHooks } from "./agent"
import { failure } from "./agent"
import { Auto, autoProvider, resetTime, type AutoEntry } from "./auto"
import { emit } from "./events"
import { handover, withHandover } from "./handover"
import { messageID, newID } from "./ids"
import type { Roster } from "./roster"
import { evaluate, matches } from "./rules"
import type { Record_, Store } from "./store"
import { Turn, type Outcome } from "./turn"
import type { AssistantMessage, Attachment, Decision, FormAnswer, FormRequest, Message, ModelRef, PermissionRequest, PermissionRule, Session } from "./wire"
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

/** How long an agent gets to stop when you press Stop, before its conversation is closed; how long a session's agents keep running with nothing to do (the next message starts them again, in the same conversation). */
export const timing = { stopGrace: 8_000, idleClose: 15 * 60_000 }

/** In plan mode, what changes files: refused, whatever your rules say. */
const changes = new Set(["edit", "write", "patch"])

export class Sessions {
  private live = new Map<string, Live>()

  constructor(
    private readonly store: Store,
    private readonly roster: Roster,
    readonly auto: Auto,
    /** Runs a model of the engine's own providers in a session here (Auto's, or one you picked). */
    private readonly engine?: (providerID: string) => Agent | undefined,
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
      live = { threads: new Map(), permissions: new Map(), forms: new Map(), always: [] }
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
    return Boolean(turn && !turn.isEnded)
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
    const lastUser = record.messages.findLastIndex((message) => message.type === "user")
    for (const message of record.messages) {
      if (message.type !== "assistant") continue
      if (!message.time.completed) {
        message.time.completed = message.time.streamed ?? message.time.created
        changed = true
      }
      for (const content of message.content) {
        if (content.type !== "tool" || (content.state.status !== "running" && content.state.status !== "streaming")) continue
        const input = content.state.status === "streaming" ? {} : content.state.input
        content.state = { status: "error", input, error: { type: "aborted", message: "Stopped." }, content: [] }
        changed = true
      }
    }
    if (lastUser >= 0 && !record.messages.slice(lastUser).some((message) => message.type === "idle")) {
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
      agent: body.agent === "plan" ? "plan" : "build",
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

  list(directory?: string): Session[] {
    return this.store
      .all()
      .filter((session) => !directory || session.location.directory === directory)
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
    if (!record) return
    // Nothing waiting starts as it stops.
    record.agent.inbox = []
    await this.interrupt(id)
    for (const thread of this.live.get(id)?.threads.values() ?? []) thread.close()
    this.live.delete(id)
    for (const [provider, slot] of Object.entries(this.slots(record))) await this.agent(provider)?.forgetConversation?.(slot.state).catch(() => {})
    this.store.remove(id)
    emit("session.deleted", { sessionID: id }, record.session.location.directory)
  }

  view(id: string, idle: number) {
    const session = this.record(id).session
    session.time.viewed = Math.max(idle, session.time.viewed ?? 0)
    this.store.save(id)
  }

  active(): string[] {
    return [...this.live.keys()].filter((id) => this.isRunning(id))
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
    const mode = agent === "plan" ? "plan" : "build"
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
    const record = this.record(id)
    const queue = this.queue(record)
    // Sent twice (a retry after a timeout): once is enough.
    if (queue.some((waiting) => waiting.id === input.id) || record.messages.some((message) => message.id === input.id)) return
    // While a turn runs, it waits for it (these agents take nothing in partway).
    const delivery: Delivery = this.isRunning(id) || input.delivery === "queue" ? "queue" : "steer"
    queue.push({ ...input, delivery })
    this.store.save(id, true)
    emit("session.inbox.enqueued", { sessionID: id, inboxID: input.id, item: { type: "user", payload: { text: input.text, files: input.files }, delivery } }, record.session.location.directory)
    if (delivery === "steer") this.wake(id)
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
    if (this.isRunning(id)) return
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
    const attachments: Attachment[] = input.files.map((file) => ({ mime: mime(file.uri), name: file.name, source: { type: "uri", uri: file.uri } }))
    if (input.synthetic) record.messages.push({ type: "synthetic", id: input.id, time: { created: Date.now() }, text: input.text, description: input.synthetic.description })
    else record.messages.push({ type: "user", id: input.id, time: { created: Date.now() }, text: input.text, files: attachments.length ? attachments : undefined })
    session.time.updated = Date.now()
    this.store.save(id, true)

    let result: RunResult
    try {
      const run: RunInput = { text: input.text, files: input.files.map(promptFile), model, plan: session.agent === "plan" }
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
    // The agent that ended the turn knows how it ended: that's not news to hand it later.
    if (live.last && live.last.seen === before) live.last.seen = record.messages[record.messages.length - 1]?.id
    live.last = undefined
    this.settleAsks(id, live)
    live.running = undefined
    if (live.turn === turn) live.turn = undefined
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
    // What it hasn't seen: what came before your message since it last ran here, and what
    // another agent did on this message before handing it over.
    const at = record.messages.findIndex((message) => message.id === userMessage)
    const seenAt = slot.seen ? record.messages.findIndex((message) => message.id === slot.seen) : -1
    const before = record.messages.slice(seenAt + 1, at < 0 ? undefined : at)
    const partway = at < 0 ? [] : record.messages.slice(at + 1)
    const handed = handover(before, partway, (message) => this.stepName(message))
    turn.setModel(model)
    // Given up on (it didn't stop when asked): the turn ends without it.
    let abandon!: () => void
    const abandoned = new Promise<RunResult>((resolve) => (abandon = () => resolve({ outcome: "interrupted" })))
    const running = { provider: model.providerID, thread, abandon }
    live.running = running
    try {
      const result = await Promise.race([thread.run({ ...input, model, text: withHandover(input.text, handed) }, turn, this.hooks(id, live, turn, signal, slot, input.plan)), abandoned])
      // It has seen all of it now, its own replies too.
      slot.seen = record.messages[record.messages.length - 1]?.id
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
      tried.add(Auto.modelKey(entry))
      const model: ModelRef = { providerID: entry.providerID, id: entry.modelID, ...(entry.variant ? { variant: entry.variant } : {}) }
      if (note) {
        turn.stopTools("Stopped: going on with another model.")
        turn.notice(`${note} Going on with ${this.entryName(entry)}.`)
      }
      last = await this.runOn(id, record, live, model, input, turn, signal, userMessage)
      if (last.outcome !== "failed" || !last.limit || signal.aborted) return last
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
      instructions: () => Object.values((record.agent.kuvoInstructions as Record<string, string> | undefined) ?? {}).join("\n\n"),
      // Nothing to ask, and nothing refused: an agent may run its tools on its own. With a
      // rule that refuses something, or in plan mode, it asks here, and the rules answer.
      approvesAll: () => !plan && !(record.session.permissions ?? []).some((rule) => rule.effect === "ask" || rule.effect === "deny"),
      permission: (ask) => this.askPermission(id, live, turn, ask, plan),
      question: (ask) => this.askQuestion(id, live, turn, ask),
    }
  }

  private askPermission(id: string, live: Live, turn: Turn, ask: PermissionAsk, plan: boolean): Promise<Decision> {
    const session = this.record(id).session
    if (plan && changes.has(ask.action)) return Promise.resolve("reject")
    const effect = evaluate(session.permissions, ask.action, ask.resources)
    if (effect === "deny") return Promise.resolve("reject")
    const allowedBefore = live.always.some((rule) => rule.action === ask.action && ask.resources.every((resource) => rule.patterns.some((pattern) => matches(pattern, resource))))
    if (effect === "allow" || allowedBefore) return Promise.resolve("once")
    if (turn.isEnded || live.abort?.signal.aborted) return Promise.resolve("reject")
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
      const covered = other.request.action === pending.request.action && other.request.resources.every((resource) => patterns.some((pattern) => matches(pattern, resource)))
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
