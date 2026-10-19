// Sessions with scripted agents: what's waiting and when it goes, Stop, moving between agents,
// Auto down its list, and what a session keeps. Each test has a folder of its own, removed after.

import { afterAll, afterEach, beforeEach, describe, expect, test } from "bun:test"
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import type { Agent, RunInput, RunResult, Thread, TurnHooks } from "../src/agent"
import { Auto } from "../src/auto"
import { subscribe } from "../src/events"
import type { Roster } from "../src/roster"
import { Sessions, timing } from "../src/sessions"
import { Store } from "../src/store"
import type { Turn } from "../src/turn"
import type { Message, ServerEvent } from "../src/wire"

type Script = (input: RunInput, turn: Turn, hooks: TurnHooks, thread: FakeThread) => Promise<RunResult>

const replies: Script = async (input, turn) => {
  turn.startStep()
  turn.text(`${input.model.providerID}/${input.model.id} on: ${input.text.split("User message:\n").pop()}`)
  turn.endStep()
  return { outcome: "succeeded" }
}

/** Runs until it's stopped. */
const works: Script = (_input, turn, _hooks, thread) => {
  turn.startStep()
  turn.text("working")
  return new Promise((resolve) => (thread.onStop = () => resolve({ outcome: "interrupted" })))
}

class FakeAgent implements Agent {
  id = "fake"
  instance = { id: "default" }
  signedIn = true
  script: Script = replies
  runs: { text: string; model: string; state: Record<string, unknown> }[] = []
  threads: FakeThread[] = []

  constructor(
    readonly providerID: string,
    readonly name: string,
  ) {}

  methods() {
    return []
  }
  async account() {
    return { installed: true, signedIn: this.signedIn }
  }
  async models() {
    return []
  }
  thread(_session: unknown, state: Record<string, unknown>): Thread {
    const thread = new FakeThread(this, state)
    this.threads.push(thread)
    return thread
  }
}

class FakeThread implements Thread {
  interrupted = 0
  closed = false
  onStop?: () => void

  constructor(
    readonly agent: FakeAgent,
    readonly state: Record<string, unknown>,
  ) {}

  run(input: RunInput, turn: Turn, hooks: TurnHooks) {
    this.agent.runs.push({ text: input.text, model: input.model.id, state: this.state })
    return this.agent.script(input, turn, hooks, this)
  }
  async interrupt() {
    this.interrupted++
    this.onStop?.()
  }
  close() {
    this.closed = true
  }
}

const base = mkdtempSync(join(process.env.KUVO_TEST_ROOT ?? tmpdir(), "kuvo-agents-test-"))
afterAll(() => rmSync(base, { recursive: true, force: true }))

let root: string
let store: Store
let auto: Auto
let a: FakeAgent
let b: FakeAgent
let sessions: Sessions
let events: ServerEvent[]
let unsubscribe: () => void

function make() {
  store = new Store(join(root, "sessions"))
  auto = new Auto(root)
  const agents = new Map([a, b].map((agent) => [agent.providerID, agent]))
  sessions = new Sessions(store, { find: (id: string | undefined) => (id ? agents.get(id) : undefined) } as unknown as Roster, auto)
}

beforeEach(() => {
  root = mkdtempSync(join(base, "case-"))
  a = new FakeAgent("alpha", "Alpha")
  b = new FakeAgent("beta", "Beta")
  events = []
  unsubscribe = subscribe((event) => events.push(event))
  make()
})

afterEach(() => {
  unsubscribe()
  sessions.closeAll()
  timing.stopGrace = 8_000
})

async function until(condition: () => boolean, ms = 3_000) {
  const start = Date.now()
  while (!condition()) {
    if (Date.now() - start > ms) throw new Error("timed out")
    await Bun.sleep(5)
  }
}

function create(model = { providerID: "alpha", id: "one" }) {
  return sessions.create({ model, location: { directory: "/tmp/project" } }).id
}

let counter = 0
function send(id: string, text: string, delivery: "steer" | "queue" = "steer") {
  const inputID = `msg_test${String(++counter).padStart(8, "0")}`
  sessions.prompt(id, { id: inputID, text, files: [], delivery })
  return inputID
}

const idles = (id: string) => sessions.messages(id).filter((message) => message.type === "idle") as Extract<Message, { type: "idle" }>[]
const texts = (id: string) =>
  sessions
    .messages(id)
    .flatMap((message) => (message.type === "assistant" ? message.content.flatMap((content) => (content.type === "text" ? [content.text] : [])) : []))
const settled = (id: string, count: number) => until(() => idles(id).length >= count && !sessions.active().includes(id))

describe("what's waiting", () => {
  test("a message starts at once, and one sent meanwhile waits for it", async () => {
    a.script = works
    const id = create()
    send(id, "first")
    await until(() => a.runs.length === 1)
    send(id, "second")
    expect(sessions.inbox(id).map((item) => item.delivery)).toEqual(["queue"])
    a.script = replies
    a.threads[0].onStop!()
    // Stopped: the one waiting stays.
    await settled(id, 1)
    expect(sessions.inbox(id)).toHaveLength(1)
    expect(a.runs).toHaveLength(1)
  })

  test("after a turn that ends on its own, the next one goes", async () => {
    let release!: () => void
    a.script = (input, turn) => {
      if (input.text !== "first") return replies(input, turn, {} as TurnHooks, {} as FakeThread)
      return new Promise((resolve) => (release = () => resolve({ outcome: "succeeded" })))
    }
    const id = create()
    send(id, "first")
    await until(() => a.runs.length === 1)
    send(id, "second")
    release()
    await settled(id, 2)
    expect(a.runs.map((run) => run.text)).toEqual(["first", "second"])
    expect(sessions.inbox(id)).toHaveLength(0)
  })

  test("Stop holds what waits; steering it starts it", async () => {
    a.script = works
    const id = create()
    send(id, "first")
    await until(() => a.runs.length === 1)
    const waiting = send(id, "second")
    await sessions.interrupt(id)
    await settled(id, 1)
    expect(idles(id)[0].outcome).toBe("interrupted")
    expect(a.runs).toHaveLength(1)
    a.script = replies
    sessions.setDelivery(id, waiting, "steer")
    await settled(id, 2)
    expect(a.runs.map((run) => run.text)).toEqual(["first", "second"])
  })

  test("Send Now: the message you picked goes next, not the first in line", async () => {
    a.script = works
    const id = create()
    send(id, "first")
    await until(() => a.runs.length === 1)
    send(id, "second")
    const picked = send(id, "third")
    a.script = replies
    sessions.setDelivery(id, picked, "steer")
    await sessions.interrupt(id, true)
    // Then, as that one ends on its own, the rest in line.
    await settled(id, 3)
    expect(a.runs.map((run) => run.text)).toEqual(["first", "third", "second"])
    expect(sessions.inbox(id)).toHaveLength(0)
  })

  test("a queued message while nothing runs waits for a nudge", async () => {
    const id = create()
    const waiting = send(id, "later", "queue")
    await Bun.sleep(30)
    expect(a.runs).toHaveLength(0)
    sessions.setDelivery(id, waiting, "steer")
    await settled(id, 1)
    expect(a.runs).toHaveLength(1)
  })

  test("after an error, nothing more starts on its own", async () => {
    a.script = async () => ({ outcome: "failed", error: { type: "agent", message: "broke" } })
    let release!: () => void
    const failing = a.script
    a.script = (input, turn, hooks, thread) =>
      input.text === "first" ? new Promise((resolve) => (release = () => resolve({ outcome: "failed", error: { type: "agent", message: "broke" } }))) : failing(input, turn, hooks, thread)
    const id = create()
    send(id, "first")
    await until(() => a.runs.length === 1)
    send(id, "second")
    release()
    await settled(id, 1)
    await Bun.sleep(30)
    expect(a.runs).toHaveLength(1)
    expect(idles(id)[0].error?.message).toBe("broke")
  })

  test("a message sent twice goes once", async () => {
    const id = create()
    sessions.prompt(id, { id: "msg_twice0000001", text: "hi", files: [], delivery: "steer" })
    sessions.prompt(id, { id: "msg_twice0000001", text: "hi", files: [], delivery: "steer" })
    await settled(id, 1)
    await Bun.sleep(20)
    expect(a.runs).toHaveLength(1)
  })

  test("what waits outlasts the bridge", async () => {
    a.script = works
    const id = create()
    send(id, "first")
    await until(() => a.runs.length === 1)
    send(id, "second")
    sessions.closeAll()
    store.flush()
    make()
    expect(sessions.inbox(id).map((item) => item.payload.text)).toEqual(["second"])
    expect(idles(id).at(-1)?.outcome).toBe("interrupted")
  })

  test("deleting a session starts nothing that waited", async () => {
    a.script = works
    const id = create()
    send(id, "first")
    await until(() => a.runs.length === 1)
    send(id, "second")
    await sessions.remove(id)
    await Bun.sleep(30)
    expect(a.runs).toHaveLength(1)
  })
})

describe("Stop", () => {
  test("an agent that doesn't stop is given up on", async () => {
    timing.stopGrace = 50
    a.script = (_input, turn) => {
      turn.startStep()
      turn.text("ignoring you")
      return new Promise(() => {})
    }
    const id = create()
    send(id, "first")
    await until(() => a.runs.length === 1)
    await sessions.interrupt(id)
    await settled(id, 1)
    expect(idles(id)[0].outcome).toBe("interrupted")
    expect(a.threads[0].closed).toBe(true)
    // What it says now doesn't go in.
    const before = JSON.stringify(sessions.messages(id))
    a.script = replies
    send(id, "again")
    await settled(id, 2)
    expect(a.threads).toHaveLength(2)
    expect(JSON.stringify(sessions.messages(id)).startsWith(before.slice(0, -1))).toBe(true)
  })

  test("asks still open are answered no", async () => {
    let decision: string | undefined
    a.script = async (_input, _turn, hooks) => {
      decision = await hooks.permission({ action: "shell", resources: ["rm -rf build"] })
      return { outcome: "interrupted" }
    }
    const id = create()
    sessions.update(id, { permissions: [{ action: "shell", resource: "*", effect: "ask" }] })
    send(id, "go")
    await until(() => sessions.permissions(id).length === 1)
    await sessions.interrupt(id)
    await settled(id, 1)
    expect(decision).toBe("reject")
    expect(sessions.permissions(id)).toHaveLength(0)
  })
})

describe("permissions", () => {
  test("Approve All with a rule that refuses something asks here, and the rule answers", async () => {
    const seen: (boolean | string)[] = []
    a.script = async (_input, _turn, hooks) => {
      seen.push(hooks.approvesAll())
      seen.push(await hooks.permission({ action: "shell", resources: ["rm -rf /"] }))
      seen.push(await hooks.permission({ action: "shell", resources: ["ls"] }))
      return { outcome: "succeeded" }
    }
    const id = create()
    sessions.update(id, { permissions: [{ action: "shell", resource: "rm *", effect: "deny" }] })
    send(id, "go")
    await settled(id, 1)
    expect(seen).toEqual([false, "reject", "once"])
  })

  test("plan mode refuses changes and doesn't approve all", async () => {
    const seen: (boolean | string)[] = []
    a.script = async (_input, _turn, hooks) => {
      seen.push(hooks.approvesAll())
      seen.push(await hooks.permission({ action: "edit", resources: ["/tmp/project/a.ts"] }))
      return { outcome: "succeeded" }
    }
    const id = create()
    sessions.selectAgent(id, "plan")
    send(id, "go")
    await settled(id, 1)
    expect(seen).toEqual([false, "reject"])
    expect(sessions.messages(id).some((message) => message.type === "agent-switched")).toBe(true)
  })

  test("Always also lets through what else waits on the same thing", async () => {
    const answers: string[] = []
    a.script = async (_input, _turn, hooks) => {
      const first = hooks.permission({ action: "shell", resources: ["git status"], save: ["git *"] })
      const second = hooks.permission({ action: "shell", resources: ["git diff"], save: ["git *"] })
      answers.push(...(await Promise.all([first, second])))
      answers.push(await hooks.permission({ action: "shell", resources: ["git log"] }))
      return { outcome: "succeeded" }
    }
    const id = create()
    sessions.update(id, { permissions: [{ action: "shell", resource: "*", effect: "ask" }] })
    send(id, "go")
    await until(() => sessions.permissions(id).length === 2)
    sessions.replyPermission(id, sessions.permissions(id)[0].id, "always")
    await settled(id, 1)
    expect(answers).toEqual(["always", "once", "once"])
  })
})

describe("moving between agents", () => {
  test("the next agent gets what it hasn't seen, and the first only what came since", async () => {
    const id = create()
    send(id, "plan the thing")
    await settled(id, 1)
    sessions.selectModel(id, { providerID: "beta", id: "two" })
    send(id, "now build it")
    await settled(id, 2)
    const handed = b.runs[0].text
    expect(handed).toContain("This conversation began with another agent")
    expect(handed).toContain("plan the thing")
    expect(handed).toContain("alpha/one on: plan the thing")
    expect(handed.endsWith("User message:\nnow build it")).toBe(true)

    sessions.selectModel(id, { providerID: "alpha", id: "one" })
    send(id, "check it")
    await settled(id, 3)
    const back = a.runs[1].text
    expect(back).not.toContain("plan the thing")
    expect(back).toContain("now build it")
    expect(back).toContain("beta/two on: now build it")
    // Each agent kept its own conversation.
    expect(a.threads).toHaveLength(1)
    expect(b.threads).toHaveLength(1)
  })

  test("an agent you stopped isn't told it was stopped, as if by another", async () => {
    a.script = works
    const id = create()
    send(id, "first")
    await until(() => a.runs.length === 1)
    await sessions.interrupt(id)
    await settled(id, 1)
    a.script = replies
    send(id, "second")
    await settled(id, 2)
    expect(a.runs[1].text).toBe("second")
  })

  test("an agent whose run broke is told what it missed", async () => {
    a.script = async () => {
      throw new Error("its process died")
    }
    const id = create()
    send(id, "first")
    await settled(id, 1)
    a.script = replies
    send(id, "second")
    await settled(id, 2)
    expect(a.runs[1].text).toContain("first")
    expect(a.runs[1].text).toContain("its process died")
    expect(a.runs[1].text.endsWith("User message:\nsecond")).toBe(true)
    // It started a new conversation of its own.
    expect(a.threads).toHaveLength(2)
    expect(a.threads[0].closed).toBe(true)
  })

  test("a model of the same agent needs no handover", async () => {
    const id = create()
    send(id, "one")
    await settled(id, 1)
    sessions.selectModel(id, { providerID: "alpha", id: "other" })
    send(id, "two")
    await settled(id, 2)
    expect(a.runs[1].text).toBe("two")
    expect(a.runs[1].model).toBe("other")
  })

  test("a session from before keeps its agent's conversation", async () => {
    const id = create()
    send(id, "one")
    await settled(id, 1)
    const record = store.get(id)!
    delete record.agent.threads
    record.agent.claudeSession = "abc"
    record.agent.claudeStarted = true
    store.save(id, true)
    sessions.closeAll()
    make()
    sessions.selectModel(id, { providerID: "beta", id: "two" })
    sessions.selectModel(id, { providerID: "alpha", id: "one" })
    send(id, "two")
    await settled(id, 2)
    expect(a.runs.at(-1)!.state).toMatchObject({ claudeSession: "abc", claudeStarted: true })
    expect(a.runs.at(-1)!.text).toBe("two")
    expect(store.get(id)!.agent.claudeSession).toBeUndefined()
  })

  test("switching models mid-turn goes on with the new one", async () => {
    a.script = works
    const id = create()
    send(id, "start")
    await until(() => a.runs.length === 1)
    sessions.selectModel(id, { providerID: "beta", id: "two" })
    sessions.synthetic(id, "The user switched the model while you were working. Carry on.")
    await sessions.interrupt(id, true)
    await settled(id, 2)
    expect(b.runs).toHaveLength(1)
    expect(b.runs[0].text).toContain("start")
    expect(b.runs[0].text.endsWith("Carry on.")).toBe(true)
    expect(sessions.messages(id).some((message) => message.type === "synthetic")).toBe(true)
  })
})

describe("Auto", () => {
  const limited = (scope: "provider" | "model"): Script => async (_input, turn) => {
    turn.startStep()
    turn.text("started on it")
    turn.toolStart("call_1", "shell", { command: "make" })
    turn.endStep()
    return { outcome: "failed", error: { type: "limit", message: "limit" }, limit: { scope } }
  }

  test("a model's limit skips that model; the next in the list goes on with what it did", async () => {
    auto.set([
      { providerID: "alpha", modelID: "one" },
      { providerID: "beta", modelID: "one" },
      { providerID: "alpha", modelID: "two" },
    ])
    a.script = (input, turn, hooks, thread) => (input.model.id === "one" ? limited("model")(input, turn, hooks, thread) : replies(input, turn, hooks, thread))
    const id = create({ providerID: "auto", id: "auto" })
    send(id, "do it")
    await settled(id, 1)
    expect(idles(id)[0].outcome).toBe("succeeded")
    expect(b.runs).toHaveLength(1)
    expect(b.runs[0].text).toContain("started on it")
    expect(b.runs[0].text).toContain("make")
    const notes = sessions.messages(id).filter((message) => message.type === "synthetic")
    expect(notes).toHaveLength(1)
    // The tool the first one left running was stopped.
    const first = sessions.messages(id).find((message) => message.type === "assistant") as any
    expect(first.content.find((content: any) => content.type === "tool").state.status).toBe("error")

    // Next time: alpha/one is held, so beta goes first.
    send(id, "again")
    await settled(id, 2)
    expect(a.runs.filter((run) => run.model === "one")).toHaveLength(1)
    expect(b.runs).toHaveLength(2)
  })

  test("an account's limit skips all of its models", async () => {
    auto.set([
      { providerID: "alpha", modelID: "one" },
      { providerID: "alpha", modelID: "two" },
      { providerID: "beta", modelID: "one" },
    ])
    a.script = limited("provider")
    const id = create({ providerID: "auto", id: "auto" })
    send(id, "do it")
    await settled(id, 1)
    expect(a.runs.map((run) => run.model)).toEqual(["one"])
    expect(b.runs).toHaveLength(1)
    expect(auto.limits().map((limit) => limit.key)).toEqual(["alpha"])
  })

  test("all at their limits: it says so, and says when the first resets", async () => {
    auto.set([
      { providerID: "alpha", modelID: "one" },
      { providerID: "beta", modelID: "one" },
    ])
    a.script = limited("provider")
    b.script = async (input, turn, hooks, thread) => {
      const result = await limited("provider")(input, turn, hooks, thread)
      return { ...result, limit: { scope: "provider", resetsAt: Date.now() + 3_600_000 } }
    }
    const id = create({ providerID: "auto", id: "auto" })
    send(id, "do it")
    await settled(id, 1)
    const idle = idles(id)[0]
    expect(idle.outcome).toBe("failed")
    expect(idle.error?.message).toContain("Every model in your Auto list is at a usage limit")
    expect(idle.error?.message).toContain("the first resets at")
  })

  test("a signed-out agent is skipped", async () => {
    auto.set([
      { providerID: "alpha", modelID: "one" },
      { providerID: "beta", modelID: "one" },
    ])
    a.signedIn = false
    const id = create({ providerID: "auto", id: "auto" })
    send(id, "do it")
    await settled(id, 1)
    expect(a.runs).toHaveLength(0)
    expect(b.runs).toHaveLength(1)
  })

  test("interleaved providers and models, in your order", async () => {
    auto.set([
      { providerID: "alpha", modelID: "one" },
      { providerID: "beta", modelID: "one" },
      { providerID: "alpha", modelID: "two" },
      { providerID: "beta", modelID: "two" },
    ])
    a.script = limited("model")
    b.script = limited("model")
    const id = create({ providerID: "auto", id: "auto" })
    send(id, "do it")
    await settled(id, 1)
    const order = [...a.runs.map((run) => ({ ...run, p: "alpha" })), ...b.runs.map((run) => ({ ...run, p: "beta" }))]
    expect(order).toHaveLength(4)
    expect(auto.limits()).toHaveLength(4)
    expect(sessions.messages(id).filter((message) => message.type === "synthetic")).toHaveLength(4)
  })

  test("Stop during Auto stops, and goes no further down the list", async () => {
    auto.set([
      { providerID: "alpha", modelID: "one" },
      { providerID: "beta", modelID: "one" },
    ])
    a.script = works
    const id = create({ providerID: "auto", id: "auto" })
    send(id, "do it")
    await until(() => a.runs.length === 1)
    await sessions.interrupt(id)
    await settled(id, 1)
    expect(idles(id)[0].outcome).toBe("interrupted")
    expect(b.runs).toHaveLength(0)
  })

  test("an empty list can't be picked", () => {
    expect(() => create({ providerID: "auto", id: "auto" })).toThrow("Settings › Auto")
  })

  test("limits are kept, and go when their time has", () => {
    auto.hold({ providerID: "alpha", modelID: "one" }, { scope: "model", resetsAt: Date.now() + 60_000 })
    auto.hold({ providerID: "beta", modelID: "one" }, { scope: "provider", resetsAt: Date.now() - 1 })
    const reloaded = new Auto(root)
    expect(reloaded.isHeld({ providerID: "alpha", modelID: "one" })).toBeTruthy()
    expect(reloaded.isHeld({ providerID: "alpha", modelID: "two" })).toBeFalsy()
    // Its reset was unknown (in the past here): held half an hour.
    expect(reloaded.isHeld({ providerID: "beta", modelID: "two" })).toBeTruthy()
    reloaded.clearLimits()
    expect(reloaded.limits()).toHaveLength(0)
  })
})

describe("a session the bridge stopped in the middle of", () => {
  test("is ended as stopped when it starts again", () => {
    const id = create()
    const record = store.get(id)!
    record.messages.push(
      { type: "user", id: "msg_u", time: { created: 1 }, text: "go" },
      {
        type: "assistant",
        id: "msg_a",
        time: { created: 2 },
        agent: "build",
        model: { providerID: "alpha", id: "one" },
        content: [{ type: "tool", id: "call", name: "shell", state: { status: "running", input: { command: "make" } } }],
      },
    )
    store.save(id, true)
    make()
    const messages = sessions.messages(id)
    expect(messages.at(-1)).toMatchObject({ type: "idle", outcome: "interrupted" })
    const step = messages.find((message) => message.type === "assistant") as any
    expect(step.time.completed).toBeDefined()
    expect(step.content[0].state.status).toBe("error")
    expect(sessions.get(id).outcome).toBe("interrupted")
  })

  test("a damaged session folder is skipped", () => {
    mkdirSync(join(root, "sessions", "ses_broken"), { recursive: true })
    writeFileSync(join(root, "sessions", "ses_broken", "session.json"), "{not json")
    make()
    expect(sessions.list().some((session) => session.id === "ses_broken")).toBe(false)
  })
})
