// What a project's files were before each of your messages, as the engine keeps them for undo: a
// git object store of the bridge's own (in its folder, never the project's), over the project's
// folder. Only in git repositories, as the engine's: their .gitignore says what's kept.

import { createHash } from "node:crypto"
import { existsSync, mkdirSync, rmSync } from "node:fs"
import { join, resolve } from "node:path"
import { fromPatch } from "./diff"
import { run } from "./proc"
import type { FileDiff } from "./wire"

const quiet = { GIT_TERMINAL_PROMPT: "0", GIT_CONFIG_NOSYSTEM: "1", GIT_OPTIONAL_LOCKS: "0" }

export class Snapshots {
  constructor(private readonly root: string) {}

  private store(directory: string) {
    return join(this.root, createHash("sha1").update(resolve(directory)).digest("hex").slice(0, 20))
  }

  private git(directory: string, args: string[], timeout = 120_000) {
    return run("git", ["--git-dir", this.store(directory), "--work-tree", directory, ...args], { cwd: directory, timeout, env: quiet })
  }

  /** The folder's files as they are now (a tree's ID), or none outside a git repository. */
  async take(directory: string): Promise<string | undefined> {
    const inside = await run("git", ["-C", directory, "rev-parse", "--is-inside-work-tree"], { timeout: 15_000, env: quiet }).catch(() => undefined)
    if (inside?.stdout.trim() !== "true") return undefined
    const store = this.store(directory)
    if (!existsSync(join(store, "HEAD"))) {
      mkdirSync(store, { recursive: true })
      const made = await run("git", ["init", "--bare", "-q", store], { timeout: 30_000, env: quiet }).catch(() => undefined)
      if (made?.code !== 0) return undefined
    }
    const added = await this.git(directory, ["add", "-A", "."]).catch(() => undefined)
    if (added?.code !== 0) return undefined
    const tree = await this.git(directory, ["write-tree"]).catch(() => undefined)
    return tree?.code === 0 ? tree.stdout.trim() || undefined : undefined
  }

  /** What changed from one snapshot to another, file by file. */
  async changes(directory: string, from: string, to: string): Promise<FileDiff[]> {
    const ran = await this.git(directory, ["diff", "--no-color", "--no-renames", "--no-ext-diff", from, to]).catch(() => undefined)
    if (ran?.code !== 0) return []
    const files: FileDiff[] = []
    for (const section of ran.stdout.split(/^(?=diff --git )/m)) {
      const path = /^diff --git a\/(.+?) b\//.exec(section)?.[1]
      if (!path) continue
      const status = /^new file mode/m.test(section) ? "added" : /^deleted file mode/m.test(section) ? "deleted" : "modified"
      files.push(fromPatch(join(directory, path), section, status))
    }
    return files
  }

  /** Puts the folder's files back as they were in `tree`, where they differ from `now` (a snapshot of them as they are). */
  async restore(directory: string, tree: string, now: string): Promise<boolean> {
    const changed = await this.git(directory, ["diff", "--name-only", "--no-renames", "-z", now, tree]).catch(() => undefined)
    if (changed?.code !== 0) return false
    const paths = changed.stdout.split("\0").filter(Boolean)
    if (!paths.length) return true
    const listed = await this.git(directory, ["ls-tree", "-r", "-z", "--name-only", tree, "--", ...paths]).catch(() => undefined)
    if (listed?.code !== 0) return false
    const there = new Set(listed.stdout.split("\0").filter(Boolean))
    const back = paths.filter((path) => there.has(path))
    if (back.length) {
      const checked = await this.git(directory, ["checkout", tree, "--", ...back]).catch(() => undefined)
      if (checked?.code !== 0) return false
    }
    // Made since: gone again.
    for (const path of paths.filter((path) => !there.has(path))) rmSync(join(directory, path), { force: true })
    return true
  }
}
