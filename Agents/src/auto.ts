// Auto: your own order of models to work with. A session on Auto runs each message on the first
// one in your list that isn't at a limit; when one reaches a usage limit partway, the message goes
// on with the next (the conversation carried over). A limit on a whole account (a plan's 5-hour
// window) skips every model of that provider; a limit on one model (Claude's weekly Opus
// allowance) skips only that model. A limit lasts until its reset, when the agent says when that
// is, and otherwise half an hour (a few minutes for requests too close together).

import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs"
import { join } from "node:path"

export const autoProvider = "auto"

export interface AutoEntry {
  providerID: string
  modelID: string
  /** Its effort (thinking) level, if you chose one. */
  variant?: string
}

export interface Limit {
  /** A whole account or plan (`provider`), or one model of it (`model`). */
  scope: "provider" | "model"
  /** When it resets, if the agent said (milliseconds since 1970). */
  resetsAt?: number
  /** The agent's own words for it. */
  message?: string
  /** A short one (requests too close together), not a plan's allowance: held a few minutes. */
  brief?: boolean
}

interface Held {
  key: string
  until: number
  scope: "provider" | "model"
  known: boolean
}

const unknownReset = 30 * 60_000
const briefReset = 3 * 60_000

export class Auto {
  private entries: AutoEntry[] = []
  private held: Held[] = []

  constructor(private readonly root: string) {
    try {
      const saved = JSON.parse(readFileSync(this.file, "utf8"))
      this.entries = (saved.entries ?? []).filter((entry: AutoEntry) => entry?.providerID && entry?.modelID)
      this.held = (saved.limits ?? []).filter((held: Held) => held?.key && held.until > Date.now())
    } catch {}
  }

  private get file() {
    return join(this.root, "auto.json")
  }

  list(): AutoEntry[] {
    return this.entries.map((entry) => ({ ...entry }))
  }

  set(entries: AutoEntry[]) {
    this.entries = entries
      .filter((entry) => entry && typeof entry.providerID === "string" && typeof entry.modelID === "string" && entry.providerID !== autoProvider)
      .map((entry) => ({ providerID: entry.providerID, modelID: entry.modelID, ...(entry.variant ? { variant: entry.variant } : {}) }))
    this.save()
  }

  /** What's held back now, and until when. */
  limits(): { key: string; until: number; scope: string; known: boolean }[] {
    this.prune()
    return this.held.map((held) => ({ ...held }))
  }

  clearLimits() {
    this.held = []
    this.save()
  }

  private prune() {
    const before = this.held.length
    this.held = this.held.filter((held) => held.until > Date.now())
    if (this.held.length !== before) this.save()
  }

  static providerKey(providerID: string) {
    return providerID
  }

  static modelKey(entry: { providerID: string; modelID: string }) {
    return `${entry.providerID}/${entry.modelID}`
  }

  /** Held back: its provider, or the model itself, is at a limit. */
  isHeld(entry: AutoEntry): Held | undefined {
    this.prune()
    return this.held.find((held) => held.key === Auto.providerKey(entry.providerID) || held.key === Auto.modelKey(entry))
  }

  hold(entry: AutoEntry, limit: Limit) {
    const key = limit.scope === "provider" ? Auto.providerKey(entry.providerID) : Auto.modelKey(entry)
    const known = Boolean(limit.resetsAt && limit.resetsAt > Date.now())
    const until = known ? limit.resetsAt! : Date.now() + (limit.brief ? briefReset : unknownReset)
    this.held = this.held.filter((held) => held.key !== key)
    this.held.push({ key, until, scope: limit.scope, known })
    this.save()
  }

  private save() {
    mkdirSync(this.root, { recursive: true })
    writeFileSync(this.file + ".new", JSON.stringify({ entries: this.entries, limits: this.held }, null, 2))
    renameSync(this.file + ".new", this.file)
  }
}

/** "4:30 PM", or "Oct 21, 9:00 AM" when it isn't today. */
export function resetTime(at: number): string {
  const date = new Date(at)
  const today = new Date()
  const time = date.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" })
  if (date.toDateString() === today.toDateString()) return time
  return `${date.toLocaleDateString("en-US", { month: "short", day: "numeric" })}, ${time}`
}
