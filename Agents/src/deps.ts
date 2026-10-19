// The agents' SDKs, from npm, installed the first time one is needed: each agent's in a folder of
// its own (`runtime/<agent>`), by the engine's own Bun (the bridge's runtime), at the version this
// bridge was written for. Nothing goes anywhere else: Bun's cache is the bridge's too.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"

export interface Package {
  name: string
  version: string
}

const installing = new Map<string, Promise<void>>()

export class Deps {
  constructor(
    private readonly root: string,
    private readonly cache: string,
  ) {}

  folder(agent: string) {
    return join(this.root, agent)
  }

  /** Whether an agent's packages are installed at their versions. */
  has(agent: string, packages: Package[]): boolean {
    return packages.every((pkg) => installedVersion(this.folder(agent), pkg.name) === pkg.version)
  }

  /** Installs an agent's packages if they aren't yet (one install at a time per agent). */
  async ensure(agent: string, packages: Package[], options: { optional?: boolean } = {}): Promise<string> {
    const folder = this.folder(agent)
    if (this.has(agent, packages)) return folder
    let pending = installing.get(agent)
    if (!pending) {
      pending = this.install(folder, packages, options.optional ?? true).finally(() => installing.delete(agent))
      installing.set(agent, pending)
    }
    await pending
    return folder
  }

  private async install(folder: string, packages: Package[], optional: boolean) {
    mkdirSync(folder, { recursive: true })
    const manifest = { name: "kuvo-agents-runtime", private: true, dependencies: Object.fromEntries(packages.map((pkg) => [pkg.name, pkg.version])) }
    writeFileSync(join(folder, "package.json"), JSON.stringify(manifest, null, 2))
    const args = [process.execPath, "install", "--no-save", "--no-progress", "--silent"]
    if (!optional) args.push("--omit", "optional")
    const child = Bun.spawn(args, {
      cwd: folder,
      env: {
        ...process.env,
        BUN_BE_BUN: "1",
        BUN_INSTALL: this.cache,
        BUN_INSTALL_CACHE_DIR: join(this.cache, "install"),
      },
      stdout: "pipe",
      stderr: "pipe",
    })
    const [code, stderr] = await Promise.all([child.exited, new Response(child.stderr).text()])
    if (code !== 0) throw new Error(`Couldn't download what the agent needs (${packages.map((pkg) => pkg.name).join(", ")}): ${stderr.trim().slice(-400)}`)
  }

  /** Loads an installed package (its entry as Bun resolves it from the agent's folder). */
  async load<T = any>(agent: string, name: string): Promise<T> {
    const entry = Bun.resolveSync(name, this.folder(agent))
    return (await import(entry)) as T
  }
}

function installedVersion(folder: string, name: string): string | undefined {
  const file = join(folder, "node_modules", name, "package.json")
  if (!existsSync(file)) return undefined
  try {
    return JSON.parse(readFileSync(file, "utf8")).version
  } catch {
    return undefined
  }
}
