// Cursor's thread against a fake SDK: what its agent is started with.

import { afterEach, describe, expect, test } from "bun:test"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import type { TurnHooks } from "../src/agent"
import { CursorAgent } from "../src/agents/cursor"
import { setToolServer } from "../src/kuvotools"
import { noTokens, type Session } from "../src/wire"

/** Cursor's SDK as far as starting an agent goes: each agent's options, as it was made. */
function fakeSDK() {
  const made: any[] = []
  let next = 1
  const sdk = {
    made,
    Agent: {
      create: async (options: any) => {
        made.push(options)
        return { agentId: `agent-${next++}`, close() {} }
      },
      resume: async () => undefined,
    },
    JsonlLocalAgentStore: class {},
    createAgentPlatform: async () => ({ prewarmLocalWorkspace: async () => undefined }),
  }
  return sdk
}

const folders: string[] = []
afterEach(() => {
  setToolServer(undefined)
  delete process.env.CURSOR_API_KEY
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true })
})

function hooks(state: Record<string, unknown>): TurnHooks {
  return {
    permission: async () => "once" as any,
    question: async () => null,
    instructions: () => "",
    check: () => undefined,
    state,
    saveState() {},
    approvesAll: () => true,
    signal: new AbortController().signal,
    subagent: () => {
      throw new Error("no subagents here")
    },
  }
}

describe("Cursor", () => {
  test("its agent gets Kuvo Code's tools, for its own conversation, as the other agents do", async () => {
    const home = mkdtempSync(join(tmpdir(), "kuvo-cursor-"))
    folders.push(home)
    const sdk = fakeSDK()
    process.env.CURSOR_API_KEY = "key_test"
    const agent = new CursorAgent({ home, temporary: home, deps: { ensure: async () => home, load: async () => sdk } as any })
    const session: Session = { id: "ses_bot", projectID: "p", cost: 0, tokens: noTokens(), time: { created: 1, updated: 1 }, title: "Primary", location: { directory: home } }
    const state: Record<string, unknown> = {}
    const thread = agent.thread(session, state)
    const input = { text: "hi", files: [], model: { id: "grok-4.7", providerID: "cursor" }, plan: false }

    setToolServer({ url: "http://127.0.0.1:47000/mcp", token: "secret", timeout: 1_000 })
    await thread.prepare?.(input, hooks(state))
    const tools = sdk.made.at(-1)?.mcpServers?.["kuvo-browser"]
    expect(tools?.url).toBe("http://127.0.0.1:47000/mcp")
    expect(tools?.headers).toEqual({ Authorization: "Bearer secret", "X-Kuvo-Session": "ses_bot" })

    // The app started again, its tools elsewhere: the agent is started again with them.
    setToolServer({ url: "http://127.0.0.1:47001/mcp", token: "other", timeout: 1_000 })
    await thread.prepare?.(input, hooks(state))
    expect(sdk.made.length).toBe(2)
    expect(sdk.made.at(-1)?.mcpServers?.["kuvo-browser"]?.url).toBe("http://127.0.0.1:47001/mcp")
  })
})
