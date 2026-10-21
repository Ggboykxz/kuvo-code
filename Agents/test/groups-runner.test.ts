import { afterEach, beforeEach, describe, expect, test } from "bun:test"
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { subscribe } from "../src/events"
import { server } from "../src/groups/api"
import { groupRoutes } from "../src/groups/routes"
import { GroupRunner } from "../src/groups/runner"
import { stamp, type Group } from "../src/groups/rules"
import { GroupStore } from "../src/groups/store"
import type { ServerEvent } from "../src/wire"

// A group chat that lives on a machine, as the machine's bridge runs it: against a stand-in engine
// whose seats answer with their bot's next line, as the Mac's GroupChatTests do.

/** The engine on the machine: each seat answers its turn with its bot's next line (PASS once it has none). */
class Engine {
  readonly requests: { method: string; path: string; body: any }[] = []
  private seats = new Map<string, string>()
  private conversations = new Map<string, any[]>()
  private next = 1
  private server: ReturnType<typeof Bun.serve>
  /** What each bot's seat says, in turn, and what its own conversation reports on a part. */
  lines: Record<string, string[]> = {}
  reports: Record<string, string> = {}
  /** A seat that asks permission before it answers. */
  asking = new Set<string>()
  private permissions = new Map<string, { id: string }[]>()

  constructor() {
    this.server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: (request) => this.answer(request) })
  }

  get url() {
    return `http://127.0.0.1:${this.server.port}`
  }

  stop() {
    this.server.stop(true)
  }

  seatsMade() {
    return this.requests.filter((request) => request.method === "POST" && request.path === "/api/session").map((request) => request.body.title as string)
  }

  prompts(session?: string) {
    return this.requests.filter((request) => request.path.endsWith("/prompt") && (!session || request.path.includes(session)))
  }

  private async answer(request: Request): Promise<Response> {
    const url = new URL(request.url)
    const body: any = request.method === "GET" || request.method === "DELETE" ? undefined : await request.json().catch(() => ({}))
    this.requests.push({ method: request.method, path: url.pathname, body })
    const ok = (data: unknown = {}) => Response.json({ data })
    const parts = url.pathname.split("/").filter(Boolean)
    if (request.method === "POST" && url.pathname === "/api/session") {
      const id = `ses_seat${this.next++}`
      this.seats.set(id, String(body.title).split(" ")[0])
      return ok({ id, title: body.title, model: body.model, location: body.location })
    }
    if (url.pathname === "/api/session/active") return ok({})
    const session = parts[2]
    const what = parts[3]
    if (request.method === "GET" && !what) return ok({ id: session, model: { id: "m", providerID: "p" } })
    if (what === "prompt") {
      const bot = this.seats.get(session)
      const owner = session.startsWith("ses_own_") ? session.slice("ses_own_".length) : undefined
      const line = bot ? (this.lines[bot]?.shift() ?? "PASS") : owner ? (this.reports[owner] ?? "") : ""
      const at = Date.now()
      const conversation = this.conversations.get(session) ?? []
      conversation.push({ type: "user", id: body.id, time: { created: at }, text: body.text })
      if (bot && this.asking.has(bot)) this.permissions.set(session, [{ id: "per_" + session }])
      if (line) {
        conversation.push({ type: "assistant", id: body.id + "_a", time: { created: at + 1, completed: at + 2 }, agent: "build", model: { id: "m", providerID: "p" }, content: [{ type: "text", text: line }] })
      }
      conversation.push({ type: "idle", id: body.id + "_i", time: { created: at + 3 }, outcome: "succeeded" })
      this.conversations.set(session, conversation)
      return ok()
    }
    if (what === "message") return ok([...(this.conversations.get(session) ?? [])].reverse())
    if (what === "inbox") return ok([])
    if (what === "permission" && request.method === "GET") return ok(this.permissions.get(session) ?? [])
    if (what === "permission") {
      this.permissions.delete(session)
      return ok()
    }
    if (what === "form") return ok([])
    return ok()
  }
}

let root: string
let engine: Engine
let events: ServerEvent[]
let unsubscribe: () => void

function bot(id: string, name: string, memory = `# ${name}'s memory\n\n## Job\nHelps with the release\n`) {
  const folder = join(root, "bots", id)
  mkdirSync(join(folder, "workspace"), { recursive: true })
  writeFileSync(join(folder, "bot.json"), JSON.stringify({ kuvo: 1, id, name, job: "Helps", look: { color: "mint", shape: "round", face: "calm" }, model: { id: "m", providerID: "p" }, created: stamp(), updated: stamp() }))
  writeFileSync(join(folder, "session"), "ses_own_" + name)
  writeFileSync(join(folder, "directory"), join(folder, "workspace"))
  writeFileSync(join(folder, "MEMORY.md"), memory)
}

function group(meeting?: Group["meeting"]): Group {
  return { id: "grp_team000001", name: "Team", members: ["bot_ada", "bot_ben"], seats: {}, heard: {}, created: stamp(), ...(meeting ? { meeting } : {}) }
}

function runner() {
  const store = new GroupStore(join(root, "groups"), join(root, "bots"))
  const groups = new GroupRunner({ store, engine: server(engine.url, "x"), bridge: () => undefined, trash: join(root, "trash"), pace: 0.05 })
  return { store, groups }
}

async function until(condition: () => boolean, ms = 5000) {
  const end = Date.now() + ms
  while (!condition() && Date.now() < end) await Bun.sleep(10)
  expect(condition()).toBe(true)
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "kuvo-groups-"))
  engine = new Engine()
  bot("bot_ada", "Ada")
  bot("bot_ben", "Ben")
  events = []
  unsubscribe = subscribe((event) => events.push(event))
})

afterEach(() => {
  unsubscribe()
  engine.stop()
  rmSync(root, { recursive: true, force: true })
})

describe("a group chat on a machine", () => {
  test("the lead first, nobody twice in a row, until everyone passes; then the wrap-up and the work", async () => {
    const { groups, store } = runner()
    engine.lines = { Ada: ["Let's ship. @Ben, the build?", "Agreed.", "PASS", "We ship Friday; Ben fixes the build.", "@Ada: write the notes\n@Ben (after @Ada): fix the build\nGO"], Ben: ["Build is red; I'll fix it.", "Done soon."] }
    engine.reports = { Ada: "Notes written.", Ben: "Build fixed." }
    groups.put(group(), [], "active", false)
    groups.send("grp_team000001", "Should we ship this week? Go ahead and do it.")
    await until(() => !groups.talk("grp_team000001").discussing && (groups.get("grp_team000001")?.messages.some((message) => message.report !== undefined && message.author === "bot_ben") ?? false), 8000)
    const messages = groups.get("grp_team000001")!.messages
    const talk = messages.filter((message) => message.kind === "message" && message.report === undefined).map((message) => message.author ?? "you")
    expect(talk).toEqual(["you", "bot_ada", "bot_ben", "bot_ada", "bot_ben"])
    const wrapUp = messages.find((message) => message.kind === "wrapUp")!
    expect(wrapUp.author).toBe("bot_ada")
    expect(wrapUp.tasks?.map((task) => [task.bot, task.state])).toEqual([
      ["bot_ada", "done"],
      ["bot_ben", "done"],
    ])
    // Ben's part started with Ada's report.
    const benPart = engine.prompts("ses_own_Ben")[0]?.body.text as string
    expect(benPart).toContain("[Work from Team · grp_team000001]")
    expect(benPart).toContain("**Ada**: Notes written.")
    expect(messages.filter((message) => message.report !== undefined).map((message) => message.text)).toEqual(["Notes written.", "Build fixed."])
    // Each seat made once, with its rules, told who it is; the chat kept on disk as the Mac writes it.
    expect(engine.seatsMade()).toEqual(["Ada in Team", "Ben in Team"])
    const seat = engine.requests.find((request) => request.method === "POST" && request.path === "/api/session")!
    expect(seat.body.permissions.some((rule: any) => rule.action === "edit" && rule.effect === "deny")).toBe(true)
    const told = engine.requests.find((request) => request.method === "PUT" && request.path.endsWith("/instructions/entries/kuvo.seat"))!
    expect(told.body.value).toContain("You are Ada, one of the user's bots in Kuvo Code: Helps with the release.")
    expect(told.body.value).toContain("You lead it.")
    const kept = JSON.parse(readFileSync(join(root, "groups", "grp_team000001", "group.json"), "utf8"))
    expect(kept.kuvo).toBe(1)
    expect(Object.keys(kept.group.seats).sort()).toEqual(["bot_ada", "bot_ben"])
    expect(store.read("grp_team000001")!.messages.length).toBe(messages.length)
    // Its bots remember it in their own conversations, under the machine's key.
    await until(() => engine.requests.some((request) => request.path.endsWith("/instructions/entries/kuvo.groups.machine")), 6000)
    expect(existsSync(join(root, "bots", "bot_ada", "groups", "grp_team000001.md"))).toBe(true)
    expect(events.some((event) => event.type === "kuvo.group.done")).toBe(true)
  }, 20_000)

  test("a bot you name with @ speaks first", async () => {
    const { groups } = runner()
    engine.lines = { Ada: [], Ben: ["Here."] }
    groups.put(group(), [], "active", false)
    groups.send("grp_team000001", "@Ben, are you there?")
    await until(() => !groups.talk("grp_team000001").discussing && groups.get("grp_team000001")!.messages.length > 1)
    expect(groups.get("grp_team000001")!.messages.filter((message) => message.author).map((message) => message.author)).toEqual(["bot_ben"])
  })

  test("a long debate pauses, and Keep Going carries on", async () => {
    const { groups } = runner()
    engine.lines = { Ada: Array.from({ length: 8 }, (_, index) => `Ada ${index}`), Ben: Array.from({ length: 8 }, (_, index) => `Ben ${index}`) }
    groups.put(group(), [], "active", false)
    groups.send("grp_team000001", "Debate it.")
    await until(() => groups.talk("grp_team000001").paused && !groups.talk("grp_team000001").discussing, 8000)
    const said = () => groups.get("grp_team000001")!.messages.filter((message) => message.author && message.kind === "message").length
    expect(said()).toBe(6)
    groups.keepGoing("grp_team000001")
    await until(() => said() > 6 && !groups.talk("grp_team000001").discussing, 8000)
  }, 20_000)

  test("undo from your message", async () => {
    const { groups } = runner()
    engine.lines = { Ada: ["First thought."], Ben: [] }
    groups.put(group(), [], "active", false)
    groups.send("grp_team000001", "Hello")
    await until(() => !groups.talk("grp_team000001").discussing && groups.get("grp_team000001")!.messages.length >= 2)
    const yours = groups.get("grp_team000001")!.messages[0]
    expect(groups.undo("grp_team000001", yours.id)).toBe("Hello")
    expect(groups.get("grp_team000001")!.messages).toEqual([])
    expect(groups.get("grp_team000001")!.group.retracted?.bot_ada).toBe("Hello")
    expect(events.some((event) => event.type === "kuvo.group.reset")).toBe(true)
  })

  test("a seat that asks permission is turned down: nobody's there to answer", async () => {
    const { groups } = runner()
    engine.lines = { Ada: ["Checked."], Ben: [] }
    engine.asking.add("Ada")
    groups.put(group(), [], "active", false)
    groups.send("grp_team000001", "Check something")
    await until(() => engine.requests.some((request) => request.method === "POST" && request.path.endsWith("/reply")))
    const reply = engine.requests.find((request) => request.path.endsWith("/reply"))!
    expect(reply.body.decision).toBe("reject")
  })

  test("a meeting comes once and clears; a repeating one moves on, in the user's time zone", async () => {
    const { groups, store } = runner()
    store.writeSettings({ personalities: {}, identityNote: "", askFirst: false, denies: [], timeZone: "Europe/Istanbul" })
    const due = new Date(Date.now() - 1000)
    groups.put(group({ next: stamp(due), topic: "Standup: what's new?" }), [], "active", false)
    expect(existsSync(join(root, "groups", "grp_team000001", "awake"))).toBe(true)
    groups.meetDue()
    expect(groups.get("grp_team000001")!.messages[0]?.kind).toBe("meeting")
    expect(groups.get("grp_team000001")!.group.meeting).toBeUndefined()
    groups.stop("grp_team000001")
    expect(existsSync(join(root, "groups", "grp_team000001", "awake"))).toBe(false)

    const daily = { ...group({ next: "2027-01-14T06:00:00Z", every: "1d", topic: "Standup" }), id: "grp_daily00001" }
    groups.put(daily, [], "active", false)
    groups.meetDue(Date.parse("2027-01-14T06:00:30Z"))
    groups.stop("grp_daily00001")
    // 9:00 in Istanbul, the next day.
    expect(groups.get("grp_daily00001")!.group.meeting).toEqual({ next: "2027-01-15T06:00:00Z", every: "1d", topic: "Standup", at: 540 })
  })

  test("a chat brought here waits until it's started; one here already isn't replaced", async () => {
    const { groups } = runner()
    const due = new Date(Date.now() - 1000)
    expect(groups.put(group({ next: stamp(due), topic: "Standup" }), [], "held", false)).toBe(true)
    groups.meetDue()
    expect(groups.get("grp_team000001")!.messages).toEqual([])
    expect(groups.send("grp_team000001", "Hello")).toBeUndefined()
    expect(groups.put(group(), [], "active", false)).toBe(false)
    groups.activate("grp_team000001")
    groups.meetDue()
    expect(groups.get("grp_team000001")!.messages.map((message) => message.kind)).toEqual(["meeting"])
    groups.stop("grp_team000001")
  })

  test("one talking when the engine started over waits for Keep Going", () => {
    const { store } = runner()
    store.saveGroup({ group: group(), status: "active", talking: true, messages: [] })
    const { groups } = runner()
    expect(groups.talk("grp_team000001")).toEqual({ speaking: undefined, discussing: false, paused: true })
  })

  test("let go of (moved away), its seats stay; deleted, they go", async () => {
    const { groups } = runner()
    const seated = { ...group(), seats: { bot_ada: "ses_seatA" } }
    groups.put(seated, [], "active", false)
    expect(groups.hold("grp_team000001")?.group.seats).toEqual({ bot_ada: "ses_seatA" })
    groups.release("grp_team000001")
    expect(groups.get("grp_team000001")).toBeUndefined()
    expect(engine.requests.some((request) => request.method === "DELETE" && request.path === "/api/session/ses_seatA")).toBe(false)
    expect(existsSync(join(root, "trash"))).toBe(true)

    groups.put({ ...seated, id: "grp_other00001" }, [], "active", false)
    await groups.delete("grp_other00001")
    expect(engine.requests.some((request) => request.method === "DELETE" && request.path === "/api/session/ses_seatA")).toBe(true)
  })

  test("its routes: the list, a chat that's here already, one that's moving", async () => {
    const { groups, store } = runner()
    const call = (method: string, parts: string[], body: unknown = {}) => groupRoutes(groups, store, method, parts, async () => body)
    expect((await call("PUT", ["grp_team000001"], { group: group(), messages: [], status: "held" })).status).toBe(200)
    expect((await call("PUT", ["grp_team000001"], { group: group(), messages: [], status: "held" })).status).toBe(409)
    expect((await call("POST", ["grp_team000001", "send"], { text: "Hi" })).status).toBe(409)
    const listed: any = await (await call("GET", [])).json()
    expect(listed.data.map((each: any) => [each.group.id, each.status])).toEqual([["grp_team000001", "held"]])
    expect((await call("PUT", ["grp_other00001"], { group: group(), messages: [] })).status).toBe(400)
    expect((await call("GET", ["../x"])).status).toBe(404)
  })
})
