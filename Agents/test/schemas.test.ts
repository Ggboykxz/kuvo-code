// The agents' own lists of what they send, against what the bridge knows: a new kind (after an
// agent's update) fails here rather than being lost without a trace. Each check runs when that
// agent's program or package is there, and is skipped otherwise.

import { describe, expect, test } from "bun:test"
import { mkdtempSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { claudeMessages, claudeSystem } from "../src/agents/claude"
import { codexItems, codexNotifications, codexRequests } from "../src/agents/codex"

const codex = Bun.which("codex")

describe("Codex", () => {
  test.skipIf(!codex)("every item, notification and request of the installed Codex is known", () => {
    const folder = mkdtempSync(join(tmpdir(), "kuvo-codex-schema-"))
    try {
      expect(Bun.spawnSync([codex!, "app-server", "generate-json-schema", "--out", folder]).exitCode).toBe(0)
      const read = (file: string) => JSON.parse(readFileSync(join(folder, file), "utf8"))
      const methods = (file: string): string[] => read(file).oneOf.map((variant: any) => variant.properties.method.enum[0])
      const items: string[] = read("codex_app_server_protocol.v2.schemas.json").definitions.ThreadItem.oneOf.map((variant: any) => variant.properties.type.enum[0])
      const known = new Set([...codexNotifications.shown, ...codexNotifications.ignored])
      expect(items.filter((type) => !codexItems.has(type))).toEqual([])
      expect(methods("ServerNotification.json").filter((method) => !known.has(method))).toEqual([])
      expect(methods("ServerRequest.json").filter((method) => !codexRequests.has(method))).toEqual([])
    } finally {
      rmSync(folder, { recursive: true, force: true })
    }
  })
})

describe("Claude Code", () => {
  test("every kind of message the Agent SDK's typings list is known", () => {
    const typings = readFileSync(join(import.meta.dir, "..", "node_modules", "@anthropic-ai", "claude-agent-sdk", "sdk.d.ts"), "utf8")
    const union = /export declare type SDKMessage = ([^;]+);/.exec(typings)?.[1] ?? ""
    const names = union.split("|").map((name) => name.trim()).flatMap((name) => {
      const alias = new RegExp(`declare type ${name} = ([A-Za-z| ]+);`).exec(typings)?.[1]
      return alias && !alias.includes("{") ? alias.split("|").map((part) => part.trim()) : [name]
    })
    expect(names.length).toBeGreaterThan(20)
    const missing: string[] = []
    for (const name of names) {
      const body = new RegExp(`declare type ${name} = (\\{[\\s\\S]*?\\n\\});`).exec(typings)?.[1] ?? ""
      const type = /^\s{4}type: '([^']+)'/m.exec(body)?.[1]
      if (!type) continue
      if (!claudeMessages.has(type)) missing.push(type)
      const subtypes = /^\s{4}subtype: ([^;]+);/m.exec(body)?.[1] ?? ""
      if (type === "system") for (const [, subtype] of subtypes.matchAll(/'([^']+)'/g)) if (!claudeSystem.has(subtype)) missing.push(`system:${subtype}`)
    }
    expect(missing).toEqual([])
  })
})
