import { describe, expect, test } from "bun:test"
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { subscribe } from "../src/events"
import { Store } from "../src/store"
import { Turn } from "../src/turn"
import { noTokens, type ServerEvent } from "../src/wire"
import { unwrapShell } from "../src/agents/codex"
import { fileDiff, fromPatch, unified } from "../src/diff"
import { messageID, newID } from "../src/ids"
import { compareVersions, homebrewKeg, npmGlobalPrefix, versionIn } from "../src/maintenance"
import { evaluate, matches } from "../src/rules"
import { commandSignIn } from "../src/signin"

describe("diffs", () => {
  test("a changed line, with the lines around it", () => {
    const { patch, additions, deletions } = unified("a\nb\nc\nd\n", "a\nb\nC\nd\n")
    expect(additions).toBe(1)
    expect(deletions).toBe(1)
    expect(patch).toBe("@@ -1,4 +1,4 @@\n a\n b\n-c\n+C\n d\n")
  })

  test("a new file is all added", () => {
    const diff = fileDiff("/tmp/x.txt", undefined, "one\ntwo\n")
    expect(diff.status).toBe("added")
    expect(diff.additions).toBe(2)
    expect(diff.patch.startsWith("--- /tmp/x.txt\n+++ /tmp/x.txt\n@@ -0,0 +1,2 @@\n")).toBe(true)
  })

  test("far-apart changes make two hunks", () => {
    const before = Array.from({ length: 20 }, (_, i) => `line ${i}`).join("\n") + "\n"
    const after = before.replace("line 1\n", "line one\n").replace("line 18\n", "line eighteen\n")
    const { patch } = unified(before, after)
    expect(patch.match(/^@@/gm)?.length).toBe(2)
  })

  test("someone else's patch is counted", () => {
    const diff = fromPatch("src/a.ts", "@@ -1,2 +1,2 @@\n-old\n+new\n same\n")
    expect([diff.additions, diff.deletions]).toEqual([1, 1])
    expect(diff.patch.startsWith("--- a/src/a.ts")).toBe(true)
  })
})

describe("permission rules", () => {
  test("nothing set runs without asking", () => {
    expect(evaluate([], "shell", ["ls"])).toBe("allow")
  })

  test("the last matching rule wins", () => {
    const rules = [
      { action: "shell", resource: "*", effect: "ask" as const },
      { action: "shell", resource: "git *", effect: "allow" as const },
    ]
    expect(evaluate(rules, "shell", ["git status"])).toBe("allow")
    expect(evaluate(rules, "shell", ["rm -rf build"])).toBe("ask")
    expect(evaluate(rules, "edit", ["/a"])).toBe("allow")
  })

  test("patterns", () => {
    expect(matches("*.env", "secrets.env")).toBe(true)
    expect(matches("src/*", "lib/a")).toBe(false)
  })
})

describe("IDs", () => {
  test("they sort in the order they were made, as the engine's do", () => {
    const ids = Array.from({ length: 50 }, () => newID("msg"))
    expect([...ids].sort()).toEqual(ids)
    expect(ids[0]).toMatch(/^msg_[0-9a-f]{12}[0-9A-Za-z]{14}$/)
  })

  test("an event's message", () => {
    expect(messageID("evt_0123abc")).toBe("msg_0123abc")
  })
})

describe("Codex's commands", () => {
  test("shown as typed", () => {
    expect(unwrapShell(`/bin/zsh -lc 'cat notes.txt'`)).toBe("cat notes.txt")
    expect(unwrapShell(`/bin/zsh -lc "echo \\"hi\\""`)).toBe(`echo "hi"`)
    expect(unwrapShell("ls -la")).toBe("ls -la")
  })
})

describe("keeping an agent's program current", () => {
  test("its version, as it prints it", () => {
    expect(versionIn("2.1.156 (Claude Code)")).toBe("2.1.156")
    expect(versionIn("codex-cli 0.159.3")).toBe("0.159.3")
    expect(versionIn("grok 1.0.62 (1474f9cbdd91)")).toBe("1.0.62")
    expect(versionIn("no version here")).toBeUndefined()
  })

  test("versions compare by number, a pre-release before its release", () => {
    expect(compareVersions("2.1.156", "2.1.303")).toBe(-1)
    expect(compareVersions("0.163.0", "0.159.3")).toBe(1)
    expect(compareVersions("1.0.62", "1.0.62")).toBe(0)
    expect(compareVersions("1.10.0", "1.9.9")).toBe(1)
    expect(compareVersions("2.0.0-beta.1", "2.0.0")).toBe(-1)
  })

  test("who installed it, from where it really is", () => {
    expect(npmGlobalPrefix("/Users/me/.nvm/versions/node/v22.15.1/lib/node_modules/@xai-official/grok/bin/grok", "@xai-official/grok")).toBe("/Users/me/.nvm/versions/node/v22.15.1")
    // A project's own copy isn't a global install.
    expect(npmGlobalPrefix("/Users/me/app/node_modules/x/lib/node_modules/@openai/codex/bin/codex", "@openai/codex")).toBeUndefined()
    expect(npmGlobalPrefix("/opt/homebrew/Caskroom/codex/0.159.3/bin/codex", "@openai/codex")).toBeUndefined()
    expect(homebrewKeg("/opt/homebrew/Caskroom/codex/0.159.3/bin/codex")).toEqual({ kind: "cask", name: "codex", prefix: "/opt/homebrew" })
    expect(homebrewKeg("/usr/local/Cellar/gh/2.80.0/bin/gh")).toEqual({ kind: "formula", name: "gh", prefix: "/usr/local" })
    expect(homebrewKeg("/Users/me/.local/share/claude/versions/2.1.156")).toBeUndefined()
  })
})

describe("blocks an agent keeps apart", () => {
  test("thinking and words that interleave stay two blocks", () => {
    const folder = mkdtempSync(join(process.env.KUVO_TEST_ROOT ?? tmpdir(), "kuvo-turn-"))
    try {
      const store = new Store(folder)
      store.add({ id: "ses_t", projectID: "p", cost: 0, tokens: noTokens(), time: { created: 1, updated: 1 }, location: { directory: "/tmp" } })
      const seen: ServerEvent[] = []
      const stop = subscribe((event) => seen.push(event))
      const turn = new Turn(store, "ses_t", "/tmp", { providerID: "opencode", id: "m" }, "build")
      turn.startStep()
      turn.blockDelta("reasoning-0", "reasoning", "Think")
      turn.blockDelta("text-0", "text", "It ")
      turn.blockDelta("reasoning-0", "reasoning", "ing.")
      turn.blockDelta("text-0", "text", "printed hello.")
      turn.blockEnd("reasoning-0")
      turn.endStep()
      turn.finish("succeeded")
      stop()
      const step = store.get("ses_t")!.messages.find((message) => message.type === "assistant") as any
      expect(step.content.map((content: any) => [content.type, content.text])).toEqual([
        ["reasoning", "Thinking."],
        ["text", "It printed hello."],
      ])
      expect(seen.filter((event) => event.type === "session.text.ended")).toHaveLength(1)
      expect(seen.filter((event) => event.type === "session.reasoning.ended")).toHaveLength(1)
    } finally {
      rmSync(folder, { recursive: true, force: true })
    }
  })
})

describe("signing in with an agent's command", () => {
  // Like Claude Code's: prints a page for when no browser opens (ending on a code), then hands its
  // browser the page that comes back by itself, and takes a pasted code.
  function fakeLogin(folder: string) {
    const script = join(folder, "login")
    writeFileSync(
      script,
      `#!/bin/sh
echo "If the browser didn't open, visit: https://example.com/printed?redirect=code"
sleep 0.5
"$BROWSER" "https://example.com/browser?redirect=localhost"
printf "Paste code here if prompted > "
read code
[ "$code" = "good" ] && echo signed > "${join(folder, "account")}" && exit 0
echo "Login failed: Request failed with status code 400"
exit 1
`,
    )
    chmodSync(script, 0o755)
    return script
  }

  async function attempt(folder: string) {
    return commandSignIn({
      command: fakeLogin(folder),
      args: [],
      home: folder,
      temporary: folder,
      instructions: "",
      signedIn: async () => existsSync(join(folder, "account")),
      codePrompt: /Paste code here if prompted >\s*/g,
    })
  }

  async function settled(sign: Awaited<ReturnType<typeof attempt>>) {
    for (let waited = 0; waited < 10_000 && sign.status().status === "pending"; waited += 100) await Bun.sleep(100)
    return sign.status()
  }

  test("opens the page handed to the browser, not the one printed first", async () => {
    const folder = mkdtempSync(join(process.env.KUVO_TEST_ROOT ?? tmpdir(), "kuvo-signin-"))
    try {
      const sign = await attempt(folder)
      expect(sign.url).toBe("https://example.com/browser?redirect=localhost")
      expect(sign.acceptsCode).toBe(true)
      sign.cancel()
    } finally {
      rmSync(folder, { recursive: true, force: true })
    }
  })

  test("a pasted code is typed into the command", async () => {
    const folder = mkdtempSync(join(process.env.KUVO_TEST_ROOT ?? tmpdir(), "kuvo-signin-"))
    try {
      const sign = await attempt(folder)
      await sign.complete!("good\n")
      expect((await settled(sign)).status).toBe("complete")
      expect(readFileSync(join(folder, "account"), "utf8").trim()).toBe("signed")
    } finally {
      rmSync(folder, { recursive: true, force: true })
    }
  })

  test("a wrong code says so, without the command's prompt", async () => {
    const folder = mkdtempSync(join(process.env.KUVO_TEST_ROOT ?? tmpdir(), "kuvo-signin-"))
    try {
      const sign = await attempt(folder)
      await sign.complete!("bad")
      const status = await settled(sign)
      expect(status.status).toBe("failed")
      expect(status.message).toContain("That code didn't work")
      await expect(sign.complete!("good")).rejects.toThrow()
    } finally {
      rmSync(folder, { recursive: true, force: true })
    }
  })
})
