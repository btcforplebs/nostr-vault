// What a NIP-88 poll (kind 1068) carries, ported from the iPhone's PollDraft (Models/NIP88Poll.swift) and
// PollComposeView: a question, two to ten options with short random ids, the relays votes go to, single or multiple
// choice, and when voting closes.
import { POLL_KIND, isPublicRelay } from "../../components/polls.js"
import { DEFAULT_RELAYS } from "../../net/pool.js"
export { POLL_KIND }

export const MIN_OPTIONS = 2, MAX_OPTIONS = 10, MAX_RELAYS = 4

/** PollComposeView.Closing: seconds from Post, null for Never; "custom" is the picked time. 1 day is the default. */
export const CLOSING = [["1h", "1 hour", 3600], ["1d", "1 day", 86400], ["3d", "3 days", 3 * 86400], ["1w", "1 week", 7 * 86400], ["never", "Never", null], ["custom", "Pick a time", null]]
export const DEFAULT_CLOSING = "1d"

export const emptyPoll = (now = Date.now()) => ({ question: "", options: ["", ""], multiple: false, closes: DEFAULT_CLOSING, customEnd: localInput(now + 86400e3) })

/** A Date as <input type="datetime-local"> writes it, in this browser's time zone. */
export function localInput(ms) {
  const d = new Date(ms), p = n => String(n).padStart(2, "0")
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`
}

/** When voting closes, in seconds, counted from `now` (the moment Post is tapped); null leaves it open. */
export function endsAt(d, now = Date.now()) {
  if (d.closes === "never") return null
  if (d.closes === "custom") { const t = new Date(d.customEnd).getTime(); return Number.isFinite(t) ? Math.floor(t / 1000) : NaN }
  const secs = CLOSING.find(([k]) => k === d.closes)?.[2] ?? 86400
  return Math.floor(now / 1000) + secs
}

export const filledOptions = d => d.options.map(o => o.trim()).filter(Boolean)
const sameTwice = labels => new Set(labels.map(l => l.toLowerCase())).size !== labels.length

/** PollDraft.isComplete: a question, 2-10 different labels (case aside), and an end time still ahead. */
export function pollComplete(d, now = Date.now()) {
  const labels = filledOptions(d)
  if (!d.question.trim() || labels.length < MIN_OPTIONS || labels.length > MAX_OPTIONS || sameTwice(labels)) return false
  const end = endsAt(d, now)
  return end === null || end > now / 1000
}

export const hasPoll = d => !!(d.question.trim() || filledOptions(d).length)

/** Why Post is off, under the options (optionsHint); a fresh form stays quiet. */
export function pollHint(d) {
  const labels = filledOptions(d)
  if (hasPoll(d)) {
    if (!d.question.trim()) return "Add a question to post."
    if (labels.length < MIN_OPTIONS) return "Fill in at least two options to post."
  }
  if (sameTwice(labels)) return "Two options are the same."
  return null
}
export function closingHint(d, now = Date.now()) {
  if (d.closes !== "custom") return null
  const end = endsAt(d, now)
  return !(end > now / 1000) ? "Pick a closing time that's still ahead." : null
}

/** A 9-character id from a-z0-9, as other clients use (PollDraft.randomOptionId). */
export function randomOptionId(random = globalThis.crypto) {
  const chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  return [...random.getRandomValues(new Uint8Array(9))].map(b => chars[b % 36]).join("")
}

/** The relays the poll names for its votes: your public wss Write relays, at most 4, else the defaults. */
export function pollRelaysFor(write = []) {
  const seen = new Set(), out = []
  for (const r of write) {
    const url = String(r).trim()
    if (!url.startsWith("wss://") || !isPublicRelay(url) || seen.has(url.toLowerCase())) continue
    seen.add(url.toLowerCase()); out.push(url)
    if (out.length >= MAX_RELAYS) break
  }
  return out.length ? out : DEFAULT_RELAYS.slice(0, MAX_RELAYS)
}

/** -> { content, tags } for the kind 1068 (PollDraft.tags): option, relay, polltype, endsAt when set. */
export function buildPoll(d, relays, { makeId = randomOptionId, now = Date.now() } = {}) {
  const tags = [], used = new Set()
  for (const label of filledOptions(d)) {
    let id = makeId()
    while (used.has(id)) id = makeId()
    used.add(id); tags.push(["option", id, label])
  }
  for (const r of relays) tags.push(["relay", r])
  tags.push(["polltype", d.multiple ? "multiplechoice" : "singlechoice"])
  const end = endsAt(d, now)
  if (end != null) tags.push(["endsAt", String(end)])
  return { content: d.question.trim(), tags }
}

/** What the draft keeps: the form as it is. */
export const pollDraftOf = d => ({ question: d.question, options: d.options, multiple: d.multiple, closes: d.closes, customEnd: d.customEnd })
