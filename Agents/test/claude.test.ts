// Claude Code's thread against a fake SDK: messages you send partway, taken late or never.

import { afterAll, afterEach, beforeEach, describe, expect, test } from "bun:test"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { ClaudeAgent } from "../src/agents/claude"
import { Auto } from "../src/auto"
import { Queue } from "../src/queue"
import type { Roster } from "../src/roster"
import { Sessions } from "../src/sessions"
import { shellOutput, shells } from "../src/shells"
import { Store } from "../src/store"
import type { Message } from "../src/wire"

/** A Claude Code that answers as the test says: what it was sent, and what it says. */
class FakeClaude {
  sent: any[] = []
  out = new Queue<any>()
  interrupts = 0
  outputs = new Map<string, string>()
  stopped: string[] = []
  closed = false
  onInterrupt?: () => void

  /** One-off prompts it answered (a title). */
  oneOffs: string[] = []

  options: any

  query = (options: { prompt: AsyncIterable<any> | string; options?: any }) => {
    if (typeof options.prompt === "string") {
      this.oneOffs.push(options.prompt)
      return (async function* () {
        yield { type: "result", subtype: "success", is_error: false, result: "A Fake Title." }
      })()
    }
    const prompt = options.prompt
    this.options = options.options
    void (async () => {
      for await (const message of prompt) this.sent.push(message)
    })()
    const out = this.out
    return {
      [Symbol.asyncIterator]: () => out[Symbol.asyncIterator](),
      setMcpServers: async () => {},
      setModel: async () => {},
      applyFlagSettings: async () => {},
      setPermissionMode: async () => {},
      getTaskOutput: async (task: string) => ({ output: this.outputs.get(task) ?? "", total_bytes: Buffer.byteLength(this.outputs.get(task) ?? ""), truncated: false }),
      stopTask: async (task: string) => {
        this.stopped.push(task)
      },
      interrupt: async () => {
        this.interrupts++
        this.onInterrupt?.()
      },
      close: () => {
        this.closed = true
        out.close()
      },
    }
  }

  say(text: string, uuids: string[]) {
    this.out.push({ type: "assistant", message: { id: `m${Math.random()}`, content: [{ type: "text", text }] }, user_message_uuids: uuids, parent_tool_use_id: null })
  }

  result(uuids: string[], subtype = "success") {
    this.out.push({ type: "result", subtype, is_error: subtype !== "success", result: "", user_message_uuids: uuids })
  }
}

class TestClaude extends ClaudeAgent {
  constructor(
    readonly fake: FakeClaude,
    home: string,
  ) {
    super({ home, temporary: home, deps: {} as any })
  }
  override async sdk(): Promise<any> {
    return { query: this.fake.query }
  }
  override executable() {
    return "/bin/false"
  }
}

const base = mkdtempSync(join(process.env.KUVO_TEST_ROOT ?? tmpdir(), "kuvo-claude-test-"))
afterAll(() => rmSync(base, { recursive: true, force: true }))

let root: string
let fake: FakeClaude
let sessions: Sessions
let provider: string

beforeEach(() => {
  root = mkdtempSync(join(base, "case-"))
  fake = new FakeClaude()
  const claude = new TestClaude(fake, root)
  provider = claude.providerID
  sessions = new Sessions(new Store(join(root, "sessions")), { find: (id: string | undefined) => (id === claude.providerID ? claude : undefined) } as unknown as Roster, new Auto(root))
})

afterEach(() => sessions.closeAll())

async function until(condition: () => boolean, ms = 3_000) {
  const start = Date.now()
  while (!condition()) {
    if (Date.now() - start > ms) throw new Error("timed out")
    await Bun.sleep(5)
  }
}

const idles = (id: string) => sessions.messages(id).filter((message) => message.type === "idle") as Extract<Message, { type: "idle" }>[]
const texts = (id: string) => sessions.messages(id).flatMap((message) => (message.type === "assistant" ? message.content.flatMap((content) => (content.type === "text" ? [content.text] : [])) : []))

describe("Claude Code, messages sent partway", () => {
  test("one it takes after its last step: the turn goes on until it has answered it", async () => {
    const id = sessions.create({ model: { providerID: provider, id: "default" }, location: { directory: root } }).id
    sessions.prompt(id, { id: "msg_claude_first01", text: "first", files: [], delivery: "steer" })
    await until(() => fake.sent.length === 1)
    sessions.prompt(id, { id: "msg_claude_second1", text: "second", files: [], delivery: "steer" })
    await until(() => fake.sent.length === 2)
    expect(fake.sent[1].priority).toBe("next")
    const [first, second] = fake.sent.map((message) => message.uuid)
    fake.say("on the first", [first])
    fake.result([first])
    await Bun.sleep(50)
    // Not over: it takes the second next.
    expect(idles(id)).toHaveLength(0)
    fake.say("on the second", [second])
    fake.result([second])
    await until(() => idles(id).length === 1)
    expect(idles(id)[0].outcome).toBe("succeeded")
    expect(texts(id).join(" ")).toContain("on the second")
    // Named from your first message, by the session's model, as the engine's sessions are.
    await until(() => sessions.get(id).title === "A Fake Title")
    expect(fake.oneOffs[0]).toContain("first")
  })

  test("one taken partway ends with the turn's one result", async () => {
    const id = sessions.create({ model: { providerID: provider, id: "default" }, location: { directory: root } }).id
    sessions.prompt(id, { id: "msg_claude_first02", text: "first", files: [], delivery: "steer" })
    await until(() => fake.sent.length === 1)
    sessions.prompt(id, { id: "msg_claude_second2", text: "second", files: [], delivery: "steer" })
    await until(() => fake.sent.length === 2)
    const [first, second] = fake.sent.map((message) => message.uuid)
    fake.say("on both", [first, second])
    fake.result([first, second])
    await until(() => idles(id).length === 1)
    expect(fake.closed).toBe(false)
  })

  test("stopped before it took one: that Claude Code goes, and the message is handed over next time", async () => {
    const id = sessions.create({ model: { providerID: provider, id: "default" }, location: { directory: root } }).id
    sessions.prompt(id, { id: "msg_claude_first03", text: "first", files: [], delivery: "steer" })
    await until(() => fake.sent.length === 1)
    sessions.prompt(id, { id: "msg_claude_second3", text: "the missed one", files: [], delivery: "steer" })
    await until(() => fake.sent.length === 2)
    const [first] = fake.sent.map((message) => message.uuid)
    fake.onInterrupt = () => fake.result([first], "error_during_execution")
    await sessions.interrupt(id, false)
    await until(() => idles(id).length === 1)
    expect(fake.closed).toBe(true)
    // The next message opens a new Claude Code, which is handed what it missed.
    const again = new FakeClaude()
    fake.sent = []
    fake.out = again.out
    fake.closed = false
    sessions.prompt(id, { id: "msg_claude_third04", text: "go on", files: [], delivery: "steer" })
    await until(() => fake.sent.length === 1)
    const text = fake.sent[0].message.content.find((part: any) => part.type === "text").text
    expect(text).toContain("the missed one")
    expect(text).toContain("go on")
  })
})

describe("Claude Code, on its own", () => {
  test("a command it leaves running shows in the bar; when it ends, the turn it starts on its own shows too", async () => {
    const id = sessions.create({ model: { providerID: provider, id: "default" }, location: { directory: root } }).id
    sessions.prompt(id, { id: "msg_claude_bg_00001", text: "start the server", files: [], delivery: "steer" })
    await until(() => fake.sent.length === 1)
    const [first] = fake.sent.map((message) => message.uuid)
    fake.out.push({ type: "assistant", message: { id: "m1", content: [{ type: "tool_use", id: "tool1", name: "Bash", input: { command: "npm run dev", run_in_background: true } }] }, parent_tool_use_id: null, user_message_uuids: [first] })
    fake.out.push({ type: "system", subtype: "task_started", task_id: "t1", task_type: "local_bash", description: "Start the dev server", tool_use_id: "tool1", is_backgrounded: true })
    fake.out.push({ type: "system", subtype: "background_tasks_changed", tasks: [{ task_id: "t1", task_type: "local_bash", description: "Start the dev server" }] })
    fake.say("It's running.", [first])
    fake.result([first])
    await until(() => idles(id).length === 1)
    // In the bar, with what it printed.
    const [job] = shells(root).filter((job) => job.metadata.sessionID === id && job.status === "running")
    expect(job.command).toBe("npm run dev")
    fake.outputs.set("t1", "ready on :3000\n")
    expect((await shellOutput(job.id, 0, 24_000))?.output).toBe("ready on :3000\n")
    // It ends; Claude Code carries on by itself, and a turn here takes it.
    fake.out.push({ type: "system", subtype: "task_notification", task_id: "t1", status: "completed", tool_use_id: "tool1", output_file: "/nonexistent", summary: "exit code 0" })
    fake.out.push({ type: "system", subtype: "background_tasks_changed", tasks: [] })
    fake.say("The server stopped.", [])
    fake.result([])
    await until(() => idles(id).length === 2)
    expect(shells(root).find((one) => one.id === job.id)?.status).toBe("exited")
    const notice = sessions.messages(id).find((message) => message.type === "synthetic") as any
    expect(notice.metadata).toMatchObject({ source: "shell", state: "completed", exit: 0 })
    expect(notice.description).toBe("npm run dev")
    expect(texts(id).join(" ")).toContain("The server stopped.")
  })

  test("a turn of its own answered before your message: your turn ends with the result that answers yours", async () => {
    const id = sessions.create({ model: { providerID: provider, id: "default" }, location: { directory: root } }).id
    sessions.prompt(id, { id: "msg_claude_bg_00002", text: "hello", files: [], delivery: "steer" })
    await until(() => fake.sent.length === 1)
    const [mine] = fake.sent.map((message) => message.uuid)
    fake.say("about the command that ended", [])
    fake.result([])
    await Bun.sleep(50)
    expect(idles(id)).toHaveLength(0)
    fake.say("hello to you", [mine])
    fake.result([mine])
    await until(() => idles(id).length === 1)
    expect(texts(id).join(" ")).toContain("hello to you")
  })
})

describe("Claude Code, on its own, twice", () => {
  test("two turns of its own one after the other are two turns here", async () => {
    const id = sessions.create({ model: { providerID: provider, id: "default" }, location: { directory: root } }).id
    sessions.prompt(id, { id: "msg_claude_bg_00004", text: "hello", files: [], delivery: "steer" })
    await until(() => fake.sent.length === 1)
    const [mine] = fake.sent.map((message) => message.uuid)
    fake.say("hi", [mine])
    fake.result([mine])
    await until(() => idles(id).length === 1)
    fake.say("the first command ended", [])
    fake.result([])
    fake.say("the second command ended", [])
    fake.result([])
    await until(() => idles(id).length === 3)
    expect(texts(id).join(" ")).toContain("the first command ended")
    expect(texts(id).join(" ")).toContain("the second command ended")
    expect(fake.interrupts).toBe(0)
  })
})

describe("Claude Code, on its own, not taken", () => {
  test("a turn it begins while an undo is staged is stopped, and the undo stays", async () => {
    const id = sessions.create({ model: { providerID: provider, id: "default" }, location: { directory: root } }).id
    sessions.prompt(id, { id: "msg_claude_bg_00003", text: "hello", files: [], delivery: "steer" })
    await until(() => fake.sent.length === 1)
    const [mine] = fake.sent.map((message) => message.uuid)
    fake.say("hi", [mine])
    fake.result([mine])
    await until(() => idles(id).length === 1)
    await sessions.stageRevert(id, "msg_claude_bg_00003")
    fake.say("about the command that ended", [])
    await until(() => fake.interrupts === 1)
    fake.result([])
    await Bun.sleep(50)
    expect(sessions.get(id).revert?.messageID).toBe("msg_claude_bg_00003")
    expect(idles(id)).toHaveLength(1)
    expect(sessions.messages(id).some((message) => message.type === "synthetic")).toBe(false)
  })
})

describe("Claude Code's subagents in the background", () => {
  test("one goes on after the turn: its work shows in its session, it can ask you, and it ends when Claude Code says", async () => {
    const id = sessions.create({ model: { providerID: provider, id: "default" }, location: { directory: root } }).id
    sessions.prompt(id, { id: "msg_claude_sub_0001", text: "look into it in the background", files: [], delivery: "steer" })
    await until(() => fake.sent.length === 1)
    const [first] = fake.sent.map((message) => message.uuid)
    fake.out.push({ type: "assistant", message: { id: "m1", content: [{ type: "tool_use", id: "call1", name: "Agent", input: { description: "Look into it", prompt: "Look into it", subagent_type: "general-purpose", run_in_background: true } }] }, parent_tool_use_id: null, user_message_uuids: [first] })
    fake.out.push({ type: "system", subtype: "task_started", task_id: "ag1", task_type: "local_agent", description: "Look into it", tool_use_id: "call1", is_backgrounded: true })
    fake.out.push({ type: "system", subtype: "background_tasks_changed", tasks: [{ task_id: "ag1", task_type: "local_agent", description: "Look into it" }] })
    fake.out.push({ type: "user", message: { content: [{ type: "tool_result", tool_use_id: "call1", content: "Launched in the background." }] }, parent_tool_use_id: null })
    fake.say("Launched.", [first])
    fake.result([first])
    await until(() => idles(id).length === 1)
    const child = sessions.list(root, id)[0]?.id
    expect(child).toBeTruthy()
    expect(sessions.active()).toContain(child)
    // After the turn: its words in its session.
    fake.out.push({ type: "assistant", message: { id: "m2", content: [{ type: "text", text: "Found the cause." }] }, parent_tool_use_id: "call1" })
    await until(() => texts(child).includes("Found the cause."))
    // It asks, as its own; you answer in the conversation that started it.
    const asked = fake.options.canUseTool("Bash", { command: "rm -rf build" }, { toolUseID: "t2", agentID: "ag1" })
    sessions.update(id, { permissions: [{ action: "shell", resource: "*", effect: "ask" }] })
    await until(() => sessions.permissions(id).length === 1)
    sessions.replyPermission(id, sessions.permissions(id)[0].id, "once")
    expect((await asked).behavior).toBe("allow")
    // Claude Code says it's done: its session's work ends.
    fake.out.push({ type: "system", subtype: "task_notification", task_id: "ag1", status: "completed", tool_use_id: "call1", output_file: "", summary: "done" })
    await until(() => !sessions.active().includes(child))
    expect(sessions.messages(child).at(-1)).toMatchObject({ type: "idle", outcome: "succeeded" })
  })
})

describe("Claude Code, nothing dropped", () => {
  async function turn(frames: (first: string) => any[]) {
    const id = sessions.create({ model: { providerID: provider, id: "default" }, location: { directory: root } }).id
    sessions.prompt(id, { id: "msg_claude_drop_01", text: "go", files: [], delivery: "steer" })
    await until(() => fake.sent.length === 1)
    const [first] = fake.sent.map((message) => message.uuid)
    for (const frame of frames(first)) fake.out.push(frame)
    fake.result([first])
    await until(() => idles(id).length === 1)
    return id
  }
  const tools = (id: string) => sessions.messages(id).flatMap((message: any) => (message.type === "assistant" ? message.content.filter((content: any) => content.type === "tool") : []))
  const notices = (id: string) => sessions.messages(id).flatMap((message: any) => (message.type === "synthetic" ? [message.text] : []))

  test("a picture a tool brings back, and a server tool's results", async () => {
    const id = await turn((first) => [
      { type: "assistant", message: { id: "a1", content: [{ type: "tool_use", id: "r1", name: "Read", input: { file_path: "/tmp/shot.png" } }] }, parent_tool_use_id: null, user_message_uuids: [first] },
      { type: "user", message: { content: [{ type: "tool_result", tool_use_id: "r1", content: [{ type: "image", source: { type: "base64", media_type: "image/png", data: "CCCC" } }] }] }, parent_tool_use_id: null },
      { type: "assistant", message: { id: "a2", content: [{ type: "server_tool_use", id: "s1", name: "web_search", input: { query: "kuvo" } }, { type: "web_search_tool_result", tool_use_id: "s1", content: [{ type: "web_search_result", title: "Kuvo", url: "https://kuvo.run" }] }] }, parent_tool_use_id: null },
    ])
    const [read, search] = tools(id)
    expect(read.state.content).toEqual([{ type: "text", text: "" }, { type: "file", uri: "data:image/png;base64,CCCC", mime: "image/png" }])
    expect(search).toMatchObject({ name: "websearch", state: { status: "completed", content: [{ type: "text", text: "Kuvo — https://kuvo.run" }] } })
  })

  test("what Claude Code says about itself: compacting, retrying, and a kind this bridge doesn't know", async () => {
    const id = await turn(() => [
      { type: "system", subtype: "compact_boundary", compact_metadata: { trigger: "auto" } },
      { type: "system", subtype: "api_retry", attempt: 2, max_retries: 10, error_status: 529, error: "overloaded" },
      { type: "system", subtype: "api_retry", attempt: 3, max_retries: 10, error_status: 529, error: "overloaded" },
      { type: "system", subtype: "brand_new_thing", content: "Something new to read." },
      { type: "system", subtype: "post_turn_summary", summary: "Already shown." },
    ])
    expect(notices(id)).toEqual(["Claude Code summarized the conversation to make room.", "Claude's API is overloaded: trying again (2/10).", "Something new to read."])
  })
})
