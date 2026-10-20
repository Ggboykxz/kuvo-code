// An ACP agent (as Grok and Antigravity speak it), faked: what it sends shows, nothing lost.

import { afterAll, afterEach, beforeEach, describe, expect, test } from "bun:test"
import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { AcpThread, acpTiming } from "../src/acp"
import type { Agent } from "../src/agent"
import { Auto } from "../src/auto"
import type { Roster } from "../src/roster"
import { Sessions } from "../src/sessions"
import { Store } from "../src/store"

const base = mkdtempSync(join(process.env.KUVO_TEST_ROOT ?? tmpdir(), "kuvo-acp-test-"))
afterAll(() => rmSync(base, { recursive: true, force: true }))

let root: string
let sessions: Sessions

beforeEach(() => {
  root = mkdtempSync(join(base, "case-"))
})
afterEach(() => sessions?.closeAll())

/** An ACP agent whose prompt sends `updates` (each `[sessionId, update]`), then, after the answer, `later`. */
function agentSaying(updates: [string, any][], later: [string, any][] = [], request?: any): Agent {
  const script = join(root, "agent.js")
  writeFileSync(
    script,
    `let buffer = ""
const send = (message) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...message }) + "\\n")
const update = (sessionId, value) => send({ method: "session/update", params: { sessionId, update: value } })
let prompt
process.stdin.on("data", (chunk) => {
  buffer += chunk
  let at
  while ((at = buffer.indexOf("\\n")) >= 0) {
    const line = buffer.slice(0, at)
    buffer = buffer.slice(at + 1)
    if (!line.trim()) continue
    const message = JSON.parse(line)
    if (message.method === "initialize") send({ id: message.id, result: { protocolVersion: 1, authMethods: [] } })
    else if (message.method === "session/new") send({ id: message.id, result: { sessionId: "s1" } })
    else if (message.method === "session/prompt") {
      prompt = message.id
      for (const [sessionId, value] of ${JSON.stringify(updates)}) update(sessionId, value)
      if (${JSON.stringify(Boolean(request))}) send({ id: 900, method: ${JSON.stringify(request?.method ?? "")}, params: ${JSON.stringify(request?.params ?? {})} })
      else send({ id: prompt, result: { stopReason: "end_turn" } })
    } else if (message.id === 900) {
      update("s1", { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Got " + JSON.stringify(message.result) } })
      send({ id: prompt, result: { stopReason: "end_turn" } })
    } else if (message.id !== undefined) send({ id: message.id, result: {} })
    if (message.method === "session/prompt" && ${JSON.stringify(later.length > 0)}) setTimeout(() => { for (const [sessionId, value] of ${JSON.stringify(later)}) update(sessionId, value) }, 300)
  }
})
`,
  )
  return {
    id: "grok",
    providerID: "acp",
    name: "Agent",
    instance: { id: "default" },
    methods: () => [],
    account: async () => ({ installed: true, signedIn: true }),
    models: async () => [],
    thread: (session, state) => new AcpThread({ fileSystem: false, authMethod: () => undefined, command: async () => ({ argv: [process.execPath, script], cwd: root }), selectModel: async () => {} }, session, state, "Agent"),
  }
}

async function run(agent: Agent, idles = 1) {
  sessions = new Sessions(new Store(join(root, "sessions")), { find: (provider: string | undefined) => (provider === "acp" ? agent : undefined) } as unknown as Roster, new Auto(root))
  const id = sessions.create({ model: { providerID: "acp", id: "one" }, location: { directory: root } }).id
  sessions.prompt(id, { id: "msg_acp_test_00001", text: "go", files: [], delivery: "steer" })
  const start = Date.now()
  while (sessions.messages(id).filter((message) => message.type === "idle").length < idles || sessions.active().includes(id)) {
    if (Date.now() - start > 30_000) throw new Error("timed out")
    await Bun.sleep(20)
  }
  return id
}

const tools = (id: string) => sessions.messages(id).flatMap((message: any) => (message.type === "assistant" ? message.content.filter((content: any) => content.type === "tool") : []))
const words = (id: string) => sessions.messages(id).flatMap((message: any) => (message.type === "assistant" ? message.content.filter((content: any) => content.type === "text").map((content: any) => content.text) : [])).join("")
const notices = (id: string) => sessions.messages(id).flatMap((message: any) => (message.type === "synthetic" ? [message.text] : []))

describe("ACP agents, nothing dropped", () => {
  test("pictures it sends and its tools bring back, a link, an error's words, and a kind this bridge doesn't know", async () => {
    const id = await run(
      agentSaying([
        ["s1", { sessionUpdate: "agent_message_chunk", content: { type: "image", data: "DDDD", mimeType: "image/png" } }],
        ["s1", { sessionUpdate: "agent_message_chunk", content: { type: "resource_link", name: "Docs", uri: "https://kuvo.run" } }],
        ["s1", { sessionUpdate: "tool_call", toolCallId: "t1", title: "Screenshot", kind: "other", status: "completed", content: [{ type: "content", content: { type: "image", data: "EEEE", mimeType: "image/jpeg" } }] }],
        ["s1", { sessionUpdate: "tool_call", toolCallId: "t2", title: "npm test", kind: "execute", status: "failed", rawInput: { command: "npm test" }, rawOutput: { stderr: "1 test failed" } }],
        ["s1", { sessionUpdate: "shiny_new_kind", message: "Something new to read." }],
      ]),
    )
    const [image, shot, failed] = tools(id)
    expect(image).toMatchObject({ name: "generate_image", state: { content: [{ type: "text" }, { type: "file", uri: "data:image/png;base64,DDDD" }] } })
    expect(shot.state.content).toEqual([{ type: "text", text: "" }, { type: "file", uri: "data:image/jpeg;base64,EEEE", mime: "image/jpeg" }])
    expect(JSON.stringify(failed.state)).toContain("1 test failed")
    expect(words(id)).toContain("[Docs](https://kuvo.run)")
    expect(notices(id)).toContain("Something new to read.")
  })

  test("a subagent's session (another session of the agent's), with its task", async () => {
    const id = await run(
      agentSaying([
        ["c1", { sessionUpdate: "user_message_chunk", content: { type: "text", text: "Count the files" } }],
        ["c1", { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "There are 3." } }],
        ["s1", { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Done." } }],
      ]),
    )
    const [row] = tools(id)
    expect(row).toMatchObject({ name: "subagent", state: { status: "completed", input: { description: "Count the files" } } })
    const child = row.state.metadata.sessionID
    expect(words(child)).toBe("There are 3.")
  })

  test("a form it asks you to fill in", async () => {
    sessions = undefined as unknown as Sessions
    const agent = agentSaying([], [], { method: "elicitation/create", params: { message: "Which branch?", requestedSchema: { type: "object", properties: { branch: { type: "string", enum: ["main", "dev"] } }, required: ["branch"] } } })
    const started = run(agent)
    const start = Date.now()
    while (!sessions || !sessions.list(root).length || !sessions.forms(sessions.list(root)[0].id).length) {
      if (Date.now() - start > 15_000) throw new Error("no form")
      await Bun.sleep(20)
    }
    const session = sessions.list(root)[0].id
    const [form] = sessions.forms(session)
    expect(form.fields[0]).toMatchObject({ key: "branch", options: [{ value: "main" }, { value: "dev" }] })
    sessions.replyForm(session, form.id, { branch: "dev" })
    const id = await started
    expect(words(id)).toContain('"action":"accept","content":{"branch":"dev"}')
  })

  test("a turn it begins on its own after its answer is taken as a turn here", async () => {
    acpTiming.ownQuiet = 500
    const id = await run(agentSaying([["s1", { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Started the task." } }]], [["s1", { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "The task finished." } }]]), 2)
    expect(words(id)).toContain("The task finished.")
    expect(notices(id)).toContain("Agent carried on by itself.")
    acpTiming.ownQuiet = 20_000
  }, 20_000)
})
