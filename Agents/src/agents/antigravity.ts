// Antigravity, as T3 Code runs it: Google's own Antigravity agent (`agy_acp_server`), downloaded
// from Google the first time you sign in, signed in with your Google account, speaking ACP. All of
// it (the agent, your sign-in, its conversations) stays in the bridge's `antigravity` folder.

import { createHash } from "node:crypto"
import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import type { Agent, AgentContext, Account, SignInAttempt, Thread } from "../agent"
import { failure, model } from "../agent"
import { AcpThread } from "../acp"
import { newID } from "../ids"
import { run } from "../proc"
import { RPC } from "../rpc"
import { catcher } from "../signin"
import type { Model, OAuthStatus, Session } from "../wire"

const version = "1.3.0"
const releases: Record<string, { url: string; sha256: string; bytes: number }> = {
  "darwin-arm64": {
    url: "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-1.3.0-darwin-arm64.zip",
    sha256: "7cd97045f7b4fe81175a107cdf16f9c51484e3c78a5162cae415338bb6aa5b88",
    bytes: 111456962,
  },
  "darwin-x64": {
    url: "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-1.3.0-darwin-x86_64.zip",
    sha256: "bb23956b89984bf5d354af2c3725e6c57f0cc1b7228e77a0e91c9c2bc1d47646",
    bytes: 117245544,
  },
  "linux-x64": {
    url: "https://dl.google.com/agy-extensions/releases/linux/agy-acp-server-1.3.0-linux-x86_64.zip",
    sha256: "9fb60956af0a9d76220a4db91ca9ac88e2a2372ad68f985ab5fceace6b825b96",
    bytes: 333727150,
  },
  "linux-arm64": {
    url: "https://dl.google.com/agy-extensions/releases/linux/agy-acp-server-1.3.0-linux-arm64.zip",
    sha256: "500b0bc0fb858e88f4df404d4cedf80bf9298c178291e39e383d6c50b111cbdf",
    bytes: 321690363,
  },
}
const executableName = "agy_acp_server.par"
const harnessName = "localharness_external"
/** What it says on stdout when it wants you to sign in (not ACP). */
const signInLine = "Open the following link to authenticate the ACP server:"
/** Your other Google keys and settings, kept from it: it signs in its own way. */
const scrubbed = [
  "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_LOCATION",
  "GOOGLE_CLOUD_QUOTA_PROJECT", "GOOGLE_GENAI_USE_VERTEXAI", "GCLOUD_PROJECT", "CLOUDSDK_CORE_PROJECT", "AGY_ACP_CCPA_PROJECT",
  "AGY_ACP_ENABLE_OAUTH", "GEMINI_HOME", "AGY_ACP_FORCE_FILE_STORAGE", "ANTIGRAVITY_HARNESS_PATH", "BROWSER", "PYTHONUNBUFFERED",
  "ELECTRON_RUN_AS_NODE",
]

export class AntigravityAgent implements Agent {
  id = "antigravity"
  providerID = "antigravity"
  name = "Antigravity"
  private installing?: Promise<void>

  constructor(readonly context: AgentContext) {}

  private get root() {
    return join(this.context.home, "antigravity")
  }

  private get folder() {
    return join(this.root, version)
  }

  /** Its home (GEMINI_HOME): your sign-in, its settings and conversations. */
  private get profile() {
    return join(this.root, "profile")
  }

  private get tokenFile() {
    return join(this.profile, "antigravity-acp", "acp_token.json")
  }

  private get modelsFile() {
    return join(this.profile, "kuvo-models.json")
  }

  private get isInstalled() {
    return existsSync(join(this.folder, ".complete"))
  }

  methods() {
    return [{ type: "oauth" as const, id: "oauth-personal", label: "Sign in with Google" }]
  }

  async account(): Promise<Account> {
    const release = releases[`${process.platform}-${process.arch}`]
    if (!release) return { installed: false, signedIn: false, message: "Google doesn't make Antigravity's agent for this computer." }
    if (!existsSync(this.tokenFile)) {
      return {
        installed: this.isInstalled,
        signedIn: false,
        message: this.isInstalled ? "Sign in with your Google account." : "Sign in with your Google account. Kuvo Code downloads Google's Antigravity agent (about 110 MB) first.",
      }
    }
    return { installed: this.isInstalled, signedIn: true, label: "Google account" }
  }

  /** Downloads and checks Google's agent, once. */
  private ensureInstalled(): Promise<void> {
    if (this.isInstalled) return Promise.resolve()
    this.installing ??= this.download().finally(() => (this.installing = undefined))
    return this.installing
  }

  private async download() {
    const release = releases[`${process.platform}-${process.arch}`]
    if (!release) throw new Error("Google doesn't make Antigravity's agent for this computer.")
    const staging = join(this.root, `.install-${newID("att")}`)
    mkdirSync(staging, { recursive: true })
    try {
      const archive = join(staging, "download.zip")
      const response = await fetch(release.url)
      if (!response.ok || !response.body) throw new Error(`Couldn't download Antigravity's agent (HTTP ${response.status}).`)
      const hash = createHash("sha256")
      const writer = Bun.file(archive).writer()
      let bytes = 0
      for await (const chunk of response.body) {
        hash.update(chunk)
        writer.write(chunk)
        bytes += chunk.byteLength
      }
      await writer.end()
      if (bytes !== release.bytes || hash.digest("hex") !== release.sha256) throw new Error("Antigravity's agent didn't download whole. Try again.")
      const listed = await run("/usr/bin/unzip", ["-Z1", archive])
      const entries = listed.stdout.split("\n").filter(Boolean).sort()
      if (entries.join(",") !== [executableName, harnessName].sort().join(",")) throw new Error("Antigravity's agent wasn't what Kuvo Code expected.")
      const unzipped = await run("/usr/bin/unzip", ["-q", "-o", archive, "-d", staging])
      if (unzipped.code !== 0) throw new Error(`Couldn't unpack Antigravity's agent: ${unzipped.stderr.trim()}`)
      rmSync(archive, { force: true })
      for (const name of [executableName, harnessName]) chmodSync(join(staging, name), 0o755)
      writeFileSync(join(staging, ".complete"), JSON.stringify({ version, sha256: release.sha256 }))
      rmSync(this.folder, { recursive: true, force: true })
      renameSync(staging, this.folder)
      // Older versions go.
      for (const name of readdirSync(this.root)) {
        if (name !== version && name !== "profile" && /^\d/.test(name)) rmSync(join(this.root, name), { recursive: true, force: true })
      }
    } finally {
      rmSync(staging, { recursive: true, force: true })
    }
  }

  /** How it's started: its own home, its own temporary folder (it unpacks itself there, about 1 GB), and nothing of your other Google keys. */
  private launch(): { argv: string[]; env: Record<string, string | undefined>; cleanEnv: boolean; onExit: () => void; signInFile: string } {
    mkdirSync(join(this.profile, "antigravity-acp", "tmp"), { recursive: true, mode: 0o700 })
    const settings = join(this.profile, "antigravity-acp", "settings.json")
    if (!existsSync(settings)) writeFileSync(settings, JSON.stringify({ auth: { type: "oauth-personal" } }))
    const temporary = join(this.context.temporary, "antigravity", newID("att"))
    mkdirSync(temporary, { recursive: true })
    const env: Record<string, string | undefined> = {}
    for (const [key, value] of Object.entries(process.env)) if (!scrubbed.includes(key.toUpperCase())) env[key] = value
    Object.assign(env, {
      GEMINI_HOME: this.profile,
      AGY_ACP_FORCE_FILE_STORAGE: "1",
      BROWSER: catcher(this.context.temporary),
      KUVO_URL_FILE: join(temporary, "url"),
      PYTHONUNBUFFERED: "1",
      TMPDIR: temporary,
      ANTIGRAVITY_HARNESS_PATH: join(this.folder, harnessName),
    })
    const argv = [join(this.folder, executableName), ...(process.platform === "linux" ? ["--uid="] : [])]
    return { argv, env, cleanEnv: true, onExit: () => rmSync(temporary, { recursive: true, force: true }), signInFile: join(temporary, "url") }
  }

  async signIn(): Promise<SignInAttempt> {
    let status: OAuthStatus = { status: "pending" }
    let link = ""
    let rpc: RPC | undefined
    let cancelled = false
    let resolveLink: (url: string) => void = () => {}
    const linked = new Promise<string>((resolve) => (resolveLink = resolve))
    const found = (url: string) => {
      if (link) return
      link = url
      resolveLink(url)
    }
    const flow = async () => {
      await this.ensureInstalled()
      if (cancelled) return
      const launch = this.launch()
      const cwd = join(this.context.temporary, "antigravity", newID("att"))
      mkdirSync(cwd, { recursive: true })
      rpc = new RPC(launch.argv, {
        cwd,
        env: launch.env,
        cleanEnv: true,
        jsonrpc: true,
        firstID: 2 ** 30,
        filter: (line) => {
          const at = line.indexOf(signInLine)
          if (at >= 0) {
            found(line.slice(at + signInLine.length).trim())
            return false
          }
          return true
        },
      })
      rpc.onExit = () => {
        launch.onExit()
        rmSync(cwd, { recursive: true, force: true })
      }
      // Or it hands the link to its "browser", which writes it down.
      const watch = setInterval(() => {
        try {
          const url = readFileSync(launch.env.KUVO_URL_FILE!, "utf8").split("\n")[0].trim()
          if (url) found(url)
        } catch {}
      }, 300)
      try {
        await rpc.request("initialize", { protocolVersion: 1, clientCapabilities: { fs: { readTextFile: true, writeTextFile: true }, terminal: false }, clientInfo: { name: "kuvo-code", version: "1" } }, 120_000)
        await rpc.request("authenticate", { methodId: "oauth-personal" }, 300_000)
        // Signed in: a session to check it works, and to learn your models; then it goes.
        const setup: any = await rpc.request("session/new", { cwd, mcpServers: [] }, 120_000)
        this.saveModels(setup)
        if (setup?.sessionId) this.removeSessionFiles(setup.sessionId)
        status = { status: "complete" }
      } finally {
        clearInterval(watch)
        rpc.kill()
      }
    }
    flow().catch((error) => {
      if (status.status !== "pending") return
      const message = String(error?.message ?? error)
      status = {
        status: "failed",
        message: cancelled
          ? "Cancelled."
          : /SUBSCRIPTION_REQUIRED/i.test(message)
            ? "Google says this account needs an Antigravity subscription."
            : /access_denied/i.test(message)
              ? "Google sign-in wasn't approved."
              : failure(error).message,
      }
    })
    // The page to open, once there is one (the first time, after the download).
    const url = await Promise.race([linked, Bun.sleep(20_000).then(() => "")])
    if (!url) {
      // It comes later: opened here, as the app has already shown the waiting page.
      void linked.then((later) => run("/usr/bin/open", [later]))
    }
    return {
      url,
      instructions: this.isInstalled
        ? "Finish signing in with Google in your browser."
        : "Downloading Google's Antigravity agent (about 110 MB). Google's sign-in opens in your browser once it's ready.",
      mode: "auto",
      status: () => status,
      cancel: () => {
        cancelled = true
        if (status.status === "pending") status = { status: "failed", message: "Cancelled." }
        rpc?.kill()
      },
    }
  }

  async signOut() {
    rmSync(this.tokenFile, { force: true })
    rmSync(this.modelsFile, { force: true })
  }

  private saveModels(setup: any) {
    const option = (setup?.configOptions ?? []).find((option: any) => option.id === "model" || option.category === "model")
    const flat: { value: string; name: string }[] = []
    for (const entry of option?.options ?? []) {
      if (Array.isArray(entry.options)) for (const inner of entry.options) flat.push({ value: inner.value, name: inner.name ?? inner.value })
      else if (entry.value) flat.push({ value: entry.value, name: entry.name ?? entry.value })
    }
    if (!flat.length) {
      for (const info of setup?.models?.availableModels ?? []) flat.push({ value: info.modelId, name: info.name ?? info.modelId })
    }
    if (flat.length) writeFileSync(this.modelsFile, JSON.stringify({ current: option?.currentValue, models: flat }))
  }

  /** A session made only to check the sign-in leaves nothing behind. */
  private removeSessionFiles(sessionID: string) {
    const folder = join(this.profile, "antigravity-acp")
    for (const suffix of [".db", ".db-wal", ".db-shm", ".db-journal", ".meta"]) rmSync(join(folder, "conversations", sessionID + suffix), { force: true })
    rmSync(join(folder, "brain", sessionID), { recursive: true, force: true })
  }

  async models(): Promise<Model[]> {
    try {
      const saved = JSON.parse(readFileSync(this.modelsFile, "utf8")) as { current?: string; models: { value: string; name: string }[] }
      return saved.models.map((info, index) => model(this.providerID, info.value, info.name, { images: true, released: info.value === saved.current ? 2000 : 1000 - index, context: 1_000_000 }))
    } catch {
      return []
    }
  }

  thread(session: Session, state: Record<string, unknown>): Thread {
    const agent = this
    return new AcpThread(
      {
        fileSystem: true,
        authenticatesFirst: true,
        resumes: true,
        authMethod: () => "oauth-personal",
        async command() {
          if (!agent.isInstalled) throw new Error("Sign in to Antigravity in Settings › Accounts first.")
          return agent.launch()
        },
        fatalLine(line) {
          return line.includes(signInLine) ? "Antigravity needs you to sign in again: Settings › Accounts." : undefined
        },
        async selectModel(rpc, sessionId, modelID, setup) {
          if (setup?.kuvoModel === modelID) return
          await rpc.request("session/set_config_option", { sessionId, configId: "model", value: modelID }, 30_000)
          setup.kuvoModel = modelID
          agent.saveModels(setup)
        },
        async selectMode(rpc, sessionId, { approvesAll, plan }, setup) {
          const option = (setup?.configOptions ?? []).find((option: any) => option.id === "mode" || option.category === "mode")
          const values: string[] = (option?.options ?? []).map((entry: any) => entry.value)
          const wanted = plan && values.includes("plan") ? "plan" : approvesAll ? "yolo" : "default"
          if (!option || setup.kuvoMode === wanted || (values.length && !values.includes(wanted))) return
          await rpc.request("session/set_config_option", { sessionId, configId: option.id, value: wanted }, 30_000)
          setup.kuvoMode = wanted
        },
      },
      session,
      state,
      this.name,
    )
  }
}

