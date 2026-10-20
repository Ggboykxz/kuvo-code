// The agents' own lists of what they send, against what the bridge knows: a new kind (after an
// agent's update) fails here rather than being lost without a trace. Each check runs when that
// agent's program or package is there, and is skipped otherwise.

import { describe, expect, test } from "bun:test"
import { mkdtempSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
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
