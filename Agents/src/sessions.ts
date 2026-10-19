// Sessions with outside agents while the bridge runs: what's waiting to be sent, the turn under
// way, what it asks you, and the agent's conversation behind each.

import { createHash } from "node:crypto"
import { fileURLToPath } from "node:url"
import type { Agent, PermissionAsk, PromptFile, QuestionAsk, Thread, TurnHooks } from "./agent"
import { failure } from "./agent"
import { emit } from "./events"
import { messageID, newID } from "./ids"
import { evaluate, matches } from "./rules"
import type { Store } from "./store"
import { Turn } from "./turn"
import type { Attachment, Decision, FormAnswer, FormRequest, Message, ModelRef, PermissionRequest, PermissionRule, Session } from "./wire"
import { noTokens } from "./wire"

interface Input {
  id: string
  text: string
  files: { uri: string; name?: string }[]
  delivery: "steer" | "queue"
}

interface Live {
  thread?: Thread
  turn?: Turn
  abort?: AbortController
  queue: Input[]
  permissions: Map<string, { request: PermissionRequest; resolve: (decision: Decision) => void }>
  forms: Map<string, { form: FormRequest; resolve: (answer: FormAnswer | null) => void }>
  /** "Always allow" answers given in this session: an action, on these patterns. */
  always: { action: string; patterns: string[] }[]
}

export class Sessions {
  private live = new Map<string, Live>()

  constructor(
    private readonly store: Store,
    private readonly agents: Agent[],
  ) {}

  agent(providerID: string | undefined): Agent | undefined {
    return this.agents.find((agent) => agent.providerID === providerID)
  }

  private state(id: string): Live {
    let live = this.live.get(id)
    if (!live) {
      live = { queue: [], permissions: new Map(), forms: new Map(), always: [] }
      this.live.set(id, live)
    }
    return live
  }

  private record(id: string) {
    const record = this.store.get(id)
    if (!record) throw new NotFound(`No session ${id}.`)
    return record
  }

  // MARK: Sessions

  create(body: { title?: string; agent?: string; model?: ModelRef; location: { directory: string }; permissions?: PermissionRule[] }): Session {
    const agent = this.agent(body.model?.providerID)
    if (!agent || !body.model) throw new BadRequest("Pick a model of an agent you've connected.")
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
      metadata: { kuvoAgent: agent.id },
    }
    this.store.add(session)
    emit("session.created", { sessionID: session.id, session }, directory)
    return session
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
    await this.interrupt(id)
    this.live.get(id)?.thread?.close()
    this.live.delete(id)
    this.store.remove(id)
    emit("session.deleted", { sessionID: id }, record.session.location.directory)
  }

  view(id: string, idle: number) {
    const session = this.record(id).session
    session.time.viewed = Math.max(idle, session.time.viewed ?? 0)
    this.store.save(id)
  }

  active(): string[] {
    return [...this.live.entries()].filter(([, live]) => live.turn && !live.turn.isEnded).map(([id]) => id)
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

  selectModel(id: string, model: ModelRef) {
    const record = this.record(id)
    const session = record.session
    const previous = session.model
    if (previous && previous.providerID !== model.providerID) {
      throw new BadRequest(`This session runs on ${this.agent(previous.providerID)?.name ?? "another agent"}: start a new session for a model of another.`)
    }
    if (previous && previous.id === model.id && previous.variant === model.variant) return
    session.model = model
    const event = emit("session.model.selected", { sessionID: id, model, previous }, session.location.directory)
    record.messages.push({ type: "model-switched", id: messageID(event.id), time: { created: event.created }, model, previous })
    this.live.get(id)?.turn?.setModel(model)
    this.store.save(id, true)
  }

  selectAgent(id: string, agent: string) {
    const record = this.record(id)
    const session = record.session
    const mode = agent === "plan" ? "plan" : "build"
    const previous = session.agent
    if (previous === mode) return
    session.agent = mode
    emit("session.agent.selected", { sessionID: id, agent: mode, previous }, session.location.directory)
    this.store.save(id, true)
  }

  // MARK: Messages

  inbox(id: string) {
    this.record(id)
    return (this.live.get(id)?.queue ?? []).map((input) => ({
      id: input.id,
      sessionID: id,
      type: "user",
      payload: { text: input.text, files: input.files },
      delivery: input.delivery,
    }))
  }

  prompt(id: string, input: Input) {
    const record = this.record(id)
    const live = this.state(id)
    const directory = record.session.location.directory
    // While a turn runs, it waits for it (these agents take nothing in partway).
    const delivery = live.turn && !live.turn.isEnded ? "queue" : input.delivery
    live.queue.push({ ...input, delivery })
    emit("session.inbox.enqueued", { sessionID: id, inboxID: input.id, item: { type: "user", payload: { text: input.text, files: input.files }, delivery } }, directory)
    if (!live.turn || live.turn.isEnded) void this.next(id)
  }

  cancelInput(id: string, inputID: string) {
    const live = this.live.get(id)
    if (!live) return
    const before = live.queue.length
    live.queue = live.queue.filter((input) => input.id !== inputID)
    if (live.queue.length !== before) emit("session.inbox.cancelled", { sessionID: id, inboxID: inputID }, this.record(id).session.location.directory)
  }

  /** Sends what's waiting, one message a turn. */
  private async next(id: string): Promise<void> {
    const live = this.state(id)
    const input = live.queue.shift()
    if (!input) return
    const record = this.store.get(id)
    if (!record) return
    const session = record.session
    const directory = session.location.directory
    const agent = this.agent(session.model?.providerID)
    emit("session.inbox.delivered", { sessionID: id, inboxID: input.id }, directory)
    const attachments: Attachment[] = input.files.map((file) => ({ mime: mime(file.uri), name: file.name, source: { type: "uri", uri: file.uri } }))
    record.messages.push({ type: "user", id: input.id, time: { created: Date.now() }, text: input.text, files: attachments.length ? attachments : undefined })
    session.time.updated = Date.now()
    this.store.save(id, true)

    const model = session.model!
    const turn = new Turn(this.store, id, directory, model, session.agent ?? "build")
    live.turn = turn
    const abort = new AbortController()
    live.abort = abort
    if (!agent) {
      turn.finish("failed", { type: "agent", message: "This session's agent isn't available." })
      return this.next(id)
    }
    try {
      live.thread ??= agent.thread(session, record.agent)
      const result = await live.thread.run(
        { text: input.text, files: input.files.map(promptFile), model, plan: session.agent === "plan" },
        turn,
        this.hooks(id, live, turn, abort.signal),
      )
      turn.finish(abort.signal.aborted ? "interrupted" : result.outcome, result.error)
    } catch (error) {
      turn.finish(abort.signal.aborted ? "interrupted" : "failed", abort.signal.aborted ? undefined : failure(error))
      // A broken conversation starts over with the next message (the agent's own may resume).
      live.thread?.close()
      live.thread = undefined
    }
    this.settleAsks(id, live)
    if (live.turn === turn) live.turn = undefined
    if (live.queue.length) void this.next(id)
  }

  async interrupt(id: string) {
    const live = this.live.get(id)
    if (!live?.turn || live.turn.isEnded) return false
    live.abort?.abort()
    this.settleAsks(id, live)
    await live.thread?.interrupt().catch(() => {})
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

  private hooks(id: string, live: Live, turn: Turn, signal: AbortSignal): TurnHooks {
    const record = this.record(id)
    return {
      signal,
      state: record.agent,
      saveState: () => this.store.save(id, true),
      instructions: () => Object.values((record.agent.kuvoInstructions as Record<string, string> | undefined) ?? {}).join("\n\n"),
      approvesAll: () => !(record.session.permissions ?? []).some((rule) => rule.effect === "ask"),
      permission: (ask) => this.askPermission(id, live, turn, ask),
      question: (ask) => this.askQuestion(id, live, ask),
    }
  }

  private askPermission(id: string, live: Live, turn: Turn, ask: PermissionAsk): Promise<Decision> {
    const session = this.record(id).session
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
    live.permissions.delete(requestID)
    pending.resolve(decision)
    emit("permission.replied", { sessionID: id, requestID }, this.record(id).session.location.directory)
  }

  private askQuestion(id: string, live: Live, ask: QuestionAsk): Promise<FormAnswer | null> {
    const session = this.record(id).session
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

  /** Closes every agent's conversation (the bridge is stopping). */
  closeAll() {
    for (const live of this.live.values()) {
      live.abort?.abort()
      live.thread?.close()
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
