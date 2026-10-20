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
import { Store } from "../src/store"
import type { Message } from "../src/wire"

/** A Claude Code that answers as the test says: what it was sent, and what it says. */
class FakeClaude {
  sent: any[] = []
  out = new Queue<any>()
  interrupts = 0
  closed = false
  onInterrupt?: () => void

  query = (options: { prompt: AsyncIterable<any> }) => {
    void (async () => {
      for await (const message of options.prompt) this.sent.push(message)
    })()
    const out = this.out
    return {
      [Symbol.asyncIterator]: () => out[Symbol.asyncIterator](),
      setMcpServers: async () => {},
      setModel: async () => {},
      applyFlagSettings: async () => {},
      setPermissionMode: async () => {},
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
