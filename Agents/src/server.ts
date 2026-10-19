// The bridge's HTTP API: the engine's, the parts the app uses for a session, its models and its
// sign-in, answered for outside agents. Anything else is "not here", which the app takes as it
// takes an engine without that feature.

import { kinds, type AgentKind } from "./accounts"
import type { Account, Agent, SignInAttempt } from "./agent"
import type { Auto } from "./auto"
import type { EngineLink } from "./engine"
import type { Roster } from "./roster"
import { emit, feed } from "./events"
import { isOutdated } from "./maintenance"
import { refreshLoginPath } from "./proc"
import { newID } from "./ids"
import { BadRequest, NotFound, Sessions } from "./sessions"
import type { Integration, Model } from "./wire"

export interface Context {
  roster: Roster
  sessions: Sessions
  auto: Auto
  link: EngineLink
  password: string
  version: string
}

const attempts = new Map<string, { agent: Agent; attempt: SignInAttempt; created: number; expires: number }>()

/** Sign-ins still waiting, given up on (the bridge is stopping). */
export function cancelSignIns() {
  for (const pending of attempts.values()) pending.attempt.cancel()
  attempts.clear()
}

// Sign-ins left waiting past their time: stopped, with what they started.
setInterval(() => {
  for (const [id, pending] of attempts) {
    if (Date.now() < pending.expires + 60_000) continue
    pending.attempt.cancel()
    attempts.delete(id)
  }
}, 60_000).unref?.()

const json = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } })
const located = (value: unknown) => json({ location: { directory: process.cwd() }, data: value })
const error = (status: number, message: string) => json({ message }, status)

/** What each agent's account looked like when last asked: a change means other models. */
const lastSeen = new Map<string, string>()

export async function integration(agent: Agent, fresh = false): Promise<Integration> {
  const [account, maintained] = await Promise.all([
    agent.account(fresh).catch((error): Account => ({ installed: false, signedIn: false, message: String(error?.message ?? error) })),
    // Its version, if it says soon enough (it's asked again later).
    agent.maintenance ? Promise.race([agent.maintenance(fresh).catch(() => undefined), Bun.sleep(15_000).then(() => undefined)]) : undefined,
  ])
  const seen = JSON.stringify([account.installed, account.signedIn, account.label])
  const before = lastSeen.get(agent.providerID)
  lastSeen.set(agent.providerID, seen)
  if (before !== undefined && before !== seen) {
    agent.forgetModels?.()
    emit("integration.updated", { integrationID: agent.providerID })
  }
  return {
    id: agent.providerID,
    name: agent.name,
    metadata: {
      source: "agent",
      agent: agent.id,
      // Which of your accounts with it: `default` is the agent's own sign-in.
      accountID: agent.instance.id,
      accountLabel: agent.instance.label,
      installed: account.installed,
      message: account.message,
      signInEnded: account.ended ?? false,
      account: account.label,
      install: agent.install,
      signsOut: Boolean(agent.signOut),
      // Its program's version, and the newest (an old Claude Code lists old models).
      version: maintained?.installed,
      latestVersion: maintained?.latest,
      outdated: maintained ? isOutdated(maintained) : false,
      updateCommand: maintained?.shown,
      updates: Boolean(agent.update && maintained?.command),
    },
    methods: agent.methods(),
    connections: account.signedIn
      ? [{ type: "agent", label: account.label, method: "oauth", status: { status: "connected", message: account.label ? `Signed in as ${account.label}` : "Signed in" } }]
      : [],
  }
}

async function models(agents: Agent[]): Promise<Model[]> {
  const lists = await Promise.all(
    agents.map(async (agent) => {
      try {
        const account = await agent.account()
        return account.signedIn ? await agent.models() : []
      } catch {
        return []
      }
    }),
  )
  return lists.flat()
}

function page<T extends { id: string }>(items: T[], url: URL): { data: T[]; cursor: { next?: string; previous?: string } } {
  // Items come newest first unless `order=asc`; the cursor is the last one sent.
  const limit = Number(url.searchParams.get("limit") ?? 100) || 100
  const cursor = url.searchParams.get("cursor")
  let start = 0
  if (cursor) {
    const [, after] = cursor.split(":", 2)
    const index = items.findIndex((item) => item.id === after)
    start = index >= 0 ? index + 1 : items.length
  }
  const data = items.slice(start, start + limit)
  const order = cursor?.split(":", 1)[0] ?? url.searchParams.get("order") ?? "desc"
  const next = start + limit < items.length && data.length ? `${order}:${data[data.length - 1].id}` : undefined
  return { data, cursor: { next } }
}

export function handler(context: Context) {
  const expected = "Basic " + Buffer.from(`opencode:${context.password}`).toString("base64")
  const { sessions, roster, auto, link } = context
  const agentFor = (id: string) => roster.find(id)

  return async (request: Request): Promise<Response> => {
    if (request.headers.get("authorization") !== expected) return error(401, "Unauthorized")
    const url = new URL(request.url)
    const parts = url.pathname.split("/").filter(Boolean).map(decodeURIComponent)
    const method = request.method
    const body = async (): Promise<any> => (request.headers.get("content-type")?.includes("json") ? await request.json().catch(() => ({})) : {})
    try {
      if (parts[0] !== "api") return error(404, "Not found")
      const [, area, a, b, c, d, e] = parts

      if (area === "info") return json({ version: context.version, pid: process.pid })
      if (area === "event") return feed()

      // Sign-in
      if (area === "integration") {
        if (!a) {
          // `fresh`: asked anew (you refreshed, or came back to the app), with your shell's PATH read again.
          const fresh = url.searchParams.get("fresh") === "1"
          if (fresh) await refreshLoginPath()
          return located(await Promise.all(roster.all().map((agent) => integration(agent, fresh))))
        }
        const agent = agentFor(a)
        if (!agent) return error(404, `No agent ${a}.`)
        if (!b) return located(await integration(agent, true))
        if (b === "connect" && c === "oauth") {
          if (!d && method === "POST") {
            const { methodID } = await body()
            if (!agent.signIn) return error(400, `${agent.name} signs in another way.`)
            const attempt = await agent.signIn(methodID)
            const id = newID("att")
            const created = Date.now()
            // Long enough for a download first (Antigravity's agent) on a slow connection.
            const expires = created + 30 * 60_000
            attempts.set(id, { agent, attempt, created, expires })
            return located({ attemptID: id, url: attempt.url, instructions: attempt.instructions, mode: attempt.mode, acceptsCode: attempt.acceptsCode || undefined, time: { created, expires } })
          }
          const pending = d ? attempts.get(d) : undefined
          if (!pending) return error(404, "That sign-in is over. Start it again.")
          if (method === "GET" && !e) {
            const expired = Date.now() > pending.expires
            const status = expired ? { status: "expired" } : pending.attempt.status()
            if (expired) pending.attempt.cancel()
            if (status.status !== "pending") attempts.delete(d!)
            return located(status)
          }
          if (method === "POST" && e === "complete") {
            const { code } = await body()
            if (!pending.attempt.complete) return error(400, "This sign-in finishes in the browser.")
            await pending.attempt.complete(String(code ?? ""))
            return json({})
          }
          if (method === "DELETE") {
            pending.attempt.cancel()
            attempts.delete(d!)
            return json({})
          }
        }
        if (b === "connect" && c === "key" && method === "POST") {
          const { key } = await body()
          if (!agent.signInWithKey) return error(400, `${agent.name} doesn't take a key here.`)
          await agent.signInWithKey(String(key ?? "").trim())
          return json({})
        }
        // Its program updated through the installer that owns it; then what it lists anew.
        if (b === "update" && method === "POST") {
          if (!agent.update) return error(400, `Update ${agent.name} the way you installed it.`)
          const result = await agent.update()
          if (result.updated) {
            for (const each of roster.all()) if (each.id === agent.id) each.forgetModels?.()
            emit("integration.updated", { integrationID: agent.providerID })
            emit("model.updated", {})
          }
          return json({ data: result })
        }
        if (b === "disconnect" && method === "POST") {
          if (!agent.signOut) return error(400, `Sign out of ${agent.name} where you signed in.`)
          await agent.signOut()
          return json({})
        }
      }

      // Catalog
      if (area === "model") {
        if (a === "default") return located(null)
        return located(await models(roster.all()))
      }
      if (area === "agent" || area === "command" || area === "skill" || area === "mcp") return located([])
      if (area === "provider") return located([])

      // Sessions
      if (area === "session") {
        if (!a) {
          if (method === "POST") return json({ data: sessions.create(await body()) })
          const directory = url.searchParams.get("directory") ?? undefined
          const roots = sessions.list(directory)
          const ordered = (url.searchParams.get("cursor")?.startsWith("asc") || url.searchParams.get("order") === "asc") ? [...roots].reverse() : roots
          return json(page(ordered, url))
        }
        if (a === "active") return json({ data: Object.fromEntries(sessions.active().map((id) => [id, { type: "busy" }])) })
        const id = a
        if (!b) {
          if (method === "GET") return json({ data: sessions.get(id) })
          if (method === "PATCH") {
            sessions.update(id, await body())
            return json({ data: sessions.get(id) })
          }
          if (method === "DELETE") {
            await sessions.remove(id)
            return json({})
          }
        }
        switch (b) {
          case "message": {
            const messages = sessions.messages(id)
            const asc = url.searchParams.get("order") === "asc" || url.searchParams.get("cursor")?.startsWith("asc")
            const ordered = asc ? messages : [...messages].reverse()
            if (c) {
              const found = messages.find((message) => message.id === c)
              return found ? json({ data: found }) : error(404, "No such message.")
            }
            return json(page(ordered, url))
          }
          case "inbox":
            if (method === "DELETE" && c) {
              sessions.cancelInput(id, c)
              return json({})
            }
            if (method === "PATCH" && c) {
              sessions.setDelivery(id, c, (await body()).delivery)
              return json({})
            }
            return json({ data: sessions.inbox(id) })
          case "prompt": {
            const input = await body()
            sessions.prompt(id, { id: input.id ?? newID("msg"), text: String(input.text ?? ""), files: input.files ?? [], delivery: input.delivery ?? "steer" })
            return json({})
          }
          case "fork":
            return json({ data: sessions.fork(id, String((await body()).before ?? "")) })
          case "synthetic": {
            const input = await body()
            sessions.synthetic(id, String(input.text ?? ""), typeof input.description === "string" ? input.description : undefined)
            return json({})
          }
          case "command": {
            // The agent's own slash commands, as it takes them: typed.
            const input = await body()
            sessions.prompt(id, { id: newID("msg"), text: `/${input.name} ${input.text ?? ""}`.trim(), files: input.files ?? [], delivery: input.delivery ?? "steer" })
            return json({})
          }
          case "interrupt":
            return json({ interrupted: await sessions.interrupt(id, url.searchParams.get("resume") === "true") })
          case "model":
            sessions.selectModel(id, (await body()).model)
            return json({})
          case "agent":
            sessions.selectAgent(id, (await body()).agent)
            return json({})
          case "permission":
            if (!c) return json({ data: sessions.permissions(id) })
            if (d === "reply") {
              const { decision } = await body()
              sessions.replyPermission(id, c, decision)
              return json({})
            }
            break
          case "form":
            if (!c) return json({ data: sessions.forms(id) })
            if (d === "reply") {
              sessions.replyForm(id, c, (await body()).answer ?? {})
              return json({})
            }
            if (method === "DELETE") {
              sessions.replyForm(id, c, null)
              return json({})
            }
            break
          case "view": {
            const { idle } = await body()
            sessions.view(id, Number(idle) || Date.now())
            return json({})
          }
          case "diff":
            return json({ data: [] })
        }
      }

      // Your accounts with the agents: adding one (it then signs in as any does), naming one, removing one.
      if (area === "kuvo" && a === "accounts") {
        if (method === "POST" && !b) {
          const { agent, label } = await body()
          if (!kinds.includes(agent)) return error(400, "That isn't one of the coding agents.")
          const record = roster.accounts.add(agent as AgentKind, label)
          roster.sync()
          const added = roster.all().find((each) => each.instance.id === record.id && each.id === agent)!
          emit("integration.updated", { integrationID: added.providerID })
          return json({ data: { providerID: added.providerID } })
        }
        const target = b ? roster.find(b) : undefined
        if (!target) return error(404, "No such account.")
        if (target.instance.id === "default") return error(400, "That's the agent's own sign-in: sign out of it where you signed in.")
        if (method === "PATCH") {
          roster.accounts.rename(target.providerID, (await body()).label)
          roster.sync()
          emit("integration.updated", { integrationID: target.providerID })
          return json({})
        }
        if (method === "DELETE") {
          sessions.forgetProvider(target.providerID)
          await target.removeAccount?.().catch(() => {})
          target.shutdown?.()
          roster.accounts.remove(target.providerID)
          roster.sync()
          emit("integration.updated", { integrationID: target.providerID })
          emit("model.updated", {})
          return json({})
        }
      }

      // Where the engine is (the app says each time it starts), for its models in sessions here.
      if (area === "kuvo" && a === "engine" && method === "PUT") {
        const { url: address, password } = await body()
        link.configure(typeof address === "string" && address ? address : undefined, typeof password === "string" ? password : undefined)
        return json({})
      }

      // Auto: your list of models, and the ones held back at a limit until it resets.
      if (area === "kuvo" && a === "auto") {
        if (b === "limits" && method === "DELETE") {
          auto.clearLimits()
          emit("kuvo.auto.updated", {})
          return json({})
        }
        if (!b && method === "PUT") {
          const { entries } = await body()
          if (!Array.isArray(entries)) return error(400, "Send the list as entries.")
          auto.set(entries)
          emit("kuvo.auto.updated", {})
        }
        if (!b && (method === "GET" || method === "PUT")) return json({ data: { entries: auto.list(), limits: auto.limits() } })
      }

      if (area === "experimental" && a === "session" && b) {
        const id = b
        if (c === "instructions" && d === "entries" && e) {
          sessions.setInstruction(id, e, method === "DELETE" ? undefined : String((await body()).value ?? ""))
          return json({})
        }
        if (c === "wait") {
          while (sessions.active().includes(id)) await Bun.sleep(200)
          return json({})
        }
      }

      return error(404, "Not available for this agent.")
    } catch (caught) {
      if (caught instanceof NotFound) return error(404, caught.message)
      if (caught instanceof BadRequest) return error(400, caught.message)
      return error(500, caught instanceof Error ? caught.message : String(caught))
    }
  }
}
