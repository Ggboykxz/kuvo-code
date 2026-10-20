// What a repository's files were around each of your messages, as the engine keeps them for undo:
// a git object store of the bridge's own (in its folder, never the project's), over the
// repository's folder, with the repository's own ignore rules. Undo puts back only the files the
// undone turns changed, as the engine's does. Only in git repositories, as the engine's.

import { createHash } from "node:crypto"
import { existsSync, lstatSync, mkdirSync, readdirSync, realpathSync, rmdirSync, rmSync } from "node:fs"
import { dirname, join, relative, resolve, sep } from "node:path"
import { fromPatch } from "./diff"
import { run } from "./proc"
import type { FileDiff } from "./wire"

const quiet = { GIT_TERMINAL_PROMPT: "0", GIT_CONFIG_NOSYSTEM: "1", GIT_OPTIONAL_LOCKS: "0", GIT_LITERAL_PATHSPECS: "1" }
/** A file's changes as shown with an undo, and how many files: enough to see what goes back. */
const patchLimit = 50_000
const fileLimit = 200

interface Repository {
  /** Its top folder, which the store works over. */
  top: string
  /** The session's folder in it ("" for the top). */
  prefix: string
  /** Its own list of what to leave out (`.git/info/exclude`). */
  exclude?: string
}

export class Snapshots {
  /** One git operation at a time on a store (two at once fail on its index). */
  private queues = new Map<string, Promise<unknown>>()
  private taken = 0

  constructor(private readonly root: string) {}

  /** The repository a folder is in, or none. */
  private async repository(directory: string): Promise<Repository | undefined> {
    const top = await run("git", ["-C", directory, "rev-parse", "--show-toplevel"], { timeout: 15_000, env: quiet }).catch(() => undefined)
    if (top?.code !== 0 || !top.stdout.trim()) return undefined
    let root: string
    let here: string
    try {
      root = realpathSync(top.stdout.trim())
      here = realpathSync(directory)
    } catch {
      return undefined
    }
    const exclude = await run("git", ["-C", directory, "rev-parse", "--path-format=absolute", "--git-path", "info/exclude"], { timeout: 15_000, env: quiet }).catch(() => undefined)
    let prefix = relative(root, here)
    if (prefix.startsWith("..")) prefix = ""
    return { top: root, prefix, exclude: exclude?.code === 0 ? exclude.stdout.trim() || undefined : undefined }
  }

  private storeOf(repository: Repository) {
    return join(this.root, createHash("sha1").update(repository.top).digest("hex").slice(0, 20))
  }

  private git(repository: Repository, args: string[], options: { input?: string; timeout?: number } = {}) {
    const settings = ["-c", "core.autocrlf=false", "-c", "core.fsmonitor=false", "-c", "core.quotepath=false", "-c", "core.symlinks=true", "-c", "core.longpaths=true", "-c", "gc.auto=0"]
    if (repository.exclude) settings.push("-c", `core.excludesFile=${repository.exclude}`)
    return run("git", ["--git-dir", this.storeOf(repository), "--work-tree", repository.top, ...settings, ...args], {
      cwd: repository.top,
      timeout: options.timeout ?? 120_000,
      env: quiet,
      input: options.input,
    })
  }

  /** Runs `work` once the store's earlier operations are done. */
  private exclusive<T>(repository: Repository, work: () => Promise<T>): Promise<T> {
    const store = this.storeOf(repository)
    const before = this.queues.get(store) ?? Promise.resolve()
    const next = before.then(work, work)
    this.queues.set(store, next.catch(() => {}))
    return next
  }

  /**
   * The folder's files as they are now (a tree's ID), or undefined outside a git repository.
   * Throws when they couldn't be kept.
   */
  async take(directory: string): Promise<string | undefined> {
    const repository = await this.repository(directory)
    if (!repository) return undefined
    return this.exclusive(repository, async () => {
      const store = this.storeOf(repository)
      if (!existsSync(join(store, "HEAD"))) {
        mkdirSync(store, { recursive: true })
        const made = await run("git", ["init", "--bare", "-q", store], { timeout: 30_000, env: quiet })
        if (made.code !== 0) throw new Error("Kuvo Code couldn't make a place to keep this project's files.")
      }
      const added = await this.git(repository, ["add", "-A", "--", repository.prefix || "."])
      if (added.code !== 0) throw new Error(`Kuvo Code couldn't keep this project's files: ${added.stderr.trim().split("\n").pop() ?? "git failed"}`)
      const tree = await this.git(repository, ["write-tree"])
      if (tree.code !== 0 || !tree.stdout.trim()) throw new Error("Kuvo Code couldn't keep this project's files.")
      // Kept small now and then.
      if (++this.taken % 50 === 0) void this.git(repository, ["gc", "--auto", "--quiet"], { timeout: 600_000 }).catch(() => {})
      return tree.stdout.trim()
    })
  }

  /** The files (the repository's paths) that differ between two snapshots, in the session's folder. */
  async changed(directory: string, from: string, to: string): Promise<string[]> {
    const repository = await this.repository(directory)
    if (!repository || from === to) return []
    return this.exclusive(repository, async () => {
      const ran = await this.git(repository, ["diff", "--name-only", "-z", "--no-renames", "--no-ext-diff", from, to, "--", repository.prefix || "."])
      if (ran.code !== 0) throw new Error("Kuvo Code couldn't tell which files changed.")
      return ran.stdout.split("\0").filter(Boolean)
    })
  }

  /** How some files differ from one snapshot to another, for showing what an undo puts back. */
  async changes(directory: string, from: string, to: string, paths: string[]): Promise<FileDiff[]> {
    const repository = await this.repository(directory)
    if (!repository) return []
    return this.exclusive(repository, async () => {
      const files: FileDiff[] = []
      for (const path of paths.slice(0, fileLimit)) {
        const ran = await this.git(repository, ["diff", "--no-color", "--no-renames", "--no-ext-diff", from, to, "--", path]).catch(() => undefined)
        if (ran?.code !== 0) continue
        const patch = ran.stdout.length > patchLimit ? ran.stdout.slice(0, patchLimit) : ran.stdout
        const status = /^new file mode/m.test(patch) ? "added" : /^deleted file mode/m.test(patch) ? "deleted" : "modified"
        files.push(fromPatch(join(repository.top, path), patch, status))
      }
      return files
    })
  }

  /**
   * Puts `paths` (the repository's) back as they were in `tree`: those that weren't there go,
   * the rest are as they were. Never through a link, never outside the repository. Throws when
   * it couldn't.
   */
  async restore(directory: string, tree: string, paths: string[]): Promise<void> {
    const repository = await this.repository(directory)
    if (!repository || !paths.length) return
    await this.exclusive(repository, async () => {
      const listed = await this.git(repository, ["ls-tree", "-r", "-z", "--name-only", "--full-tree", tree])
      if (listed.code !== 0) throw new Error("Kuvo Code couldn't read what the files were.")
      const wanted = new Set(paths)
      const there = new Set(listed.stdout.split("\0").filter((path) => path && wanted.has(path)))
      // Gone first, deepest first (a folder that was a file, a file that was a folder).
      const gone = paths.filter((path) => !there.has(path)).sort((a, b) => b.length - a.length)
      for (const path of gone) this.remove(repository.top, path)
      const back = paths.filter((path) => there.has(path))
      if (back.length) {
        // A folder where a file goes back (it became one): it goes first.
        for (const path of back) {
          const full = join(repository.top, path)
          if (this.isInside(repository.top, full) && existsSync(full) && lstatSync(full).isDirectory()) rmSync(full, { recursive: true, force: true })
        }
        const checked = await this.git(repository, ["checkout", tree, "--pathspec-from-file=-", "--pathspec-file-nul"], { input: back.join("\0") })
        if (checked.code !== 0) throw new Error(`Kuvo Code couldn't put the files back: ${checked.stderr.trim().split("\n").pop() ?? "git failed"}`)
      }
    })
  }

  /** Whether a path's folders are inside the repository, none of them a link (deleting through one would reach elsewhere). */
  private isInside(top: string, full: string): boolean {
    const target = resolve(full)
    if (!target.startsWith(top + sep)) return false
    let folder = dirname(target)
    while (folder.length > top.length) {
      try {
        if (lstatSync(folder).isSymbolicLink()) return false
      } catch {
        return true
      }
      folder = dirname(folder)
    }
    return true
  }

  /** A file (or link, or folder) made since, gone again; the folders it leaves empty too. */
  private remove(top: string, path: string) {
    const full = join(top, path)
    if (!this.isInside(top, full)) return
    try {
      const stat = lstatSync(full)
      // A link goes itself, never what it points at.
      rmSync(full, { recursive: stat.isDirectory() && !stat.isSymbolicLink(), force: true })
    } catch {
      return
    }
    let folder = dirname(full)
    while (folder.length > top.length) {
      try {
        if (readdirSync(folder).length) break
        rmdirSync(folder)
      } catch {
        break
      }
      folder = dirname(folder)
    }
  }
}
