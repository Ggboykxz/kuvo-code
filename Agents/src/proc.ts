// Running the agents' own programs (`claude`, `codex`, `grok`…), found where your login shell
// would find them: the app hands the bridge that shell's PATH.

import { accessSync, constants } from "node:fs"
import { delimiter, join } from "node:path"

/** The program's path on PATH (or the extra places given), if it's there. */
export function which(name: string, extra: string[] = []): string | undefined {
  const folders = [...(process.env.PATH ?? "").split(delimiter), ...extra].filter(Boolean)
  for (const folder of folders) {
    const path = join(folder, name)
    try {
      accessSync(path, constants.X_OK)
      return path
    } catch {}
  }
  return undefined
}

export interface Ran {
  code: number
  stdout: string
  stderr: string
}

/** Runs a program to its end, or until `timeout` (then it's stopped). */
export async function run(command: string, args: string[], options: { cwd?: string; env?: Record<string, string | undefined>; timeout?: number; input?: string } = {}): Promise<Ran> {
  const child = Bun.spawn([command, ...args], {
    cwd: options.cwd,
    env: { ...process.env, ...options.env },
    stdin: options.input !== undefined ? "pipe" : "ignore",
    stdout: "pipe",
    stderr: "pipe",
  })
  if (options.input !== undefined && child.stdin) {
    child.stdin.write(options.input)
    child.stdin.end()
  }
  const timer = options.timeout ? setTimeout(() => child.kill(), options.timeout) : undefined
  const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()])
  if (timer) clearTimeout(timer)
  return { code, stdout, stderr }
}

/** Finds the first web address in some text (a sign-in page a program printed). */
export function firstURL(text: string): string | undefined {
  return text.match(/https?:\/\/[^\s"'<>]+/)?.[0]
}

/** Text with terminal colors and cursor codes taken out. */
export function plain(text: string): string {
  return text.replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, "").replace(/\x1b\][^\x07]*\x07/g, "")
}
