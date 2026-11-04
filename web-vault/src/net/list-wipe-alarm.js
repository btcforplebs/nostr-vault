// List wipe alarm (docs/LIST_WIPE_ALARM.md, Logen 2026-11-04): when a new version of one of the user's lists looks
// like another app clobbered it (emptied, swapped for other entries, drained step by step), show a banner with one
// tap to Recover. Pure rules; the watcher below only reads the vault's /lists history and this browser's storage.
// Never restores or publishes by itself. Same rule and fixtures as iPhone/Mac ListWipeAlarmRule.swift and Android
// ListWipeAlarmRule.kt (HavenApp/MediaLogicTests/.../Fixtures/ListAlarm/alarm-cases.json).

/** The lists the vault keeps history for (haven-go protectedListKinds). */
export const PROTECTED_KINDS = [0, 3, 10000, 10001, 10002, 10003, 10004, 10006, 10007, 10015, 10030, 10050, 10063, 30000, 30002, 30003]
const PROTECTED = new Set(PROTECTED_KINDS)
const META = new Set(["d", "title", "name", "description", "image", "alt", "client"])
const ENCRYPTED = new Set([10000, 10003, 30000, 30003])
export const RULE = { minItems: 10, minContent: 1000, lookback: 5, alarmMinItems: 3 }

export const isProtectedKind = kind => PROTECTED.has(kind)

/** A list's items as the shrink rule keys them: every tag but the list's own, by name and value; a profile's
 *  filled-in string fields. */
export function items(v) {
  const out = new Set()
  if (v.kind === 0) {
    let f
    try { f = JSON.parse(v.content) } catch { return out }
    if (!f || typeof f !== "object" || Array.isArray(f)) return out
    for (const [k, x] of Object.entries(f)) if (typeof x === "string" && x !== "") out.add(`${k}\u0000${x}`)
    return out
  }
  for (const t of v.tags ?? []) {
    if (!Array.isArray(t) || !t.length || META.has(t[0])) continue
    out.add(t.length > 1 ? `${t[0]}\u0000${t[1]}` : String(t[0]))
  }
  return out
}

const len = v => (typeof v.content === "string" ? v.content.length : 0)

/** Whether `b` is a clobber of `a`, by which entries survived (a same-size swap counts). */
export function clobbered(a, b) {
  const ia = items(a), ib = items(b)
  const n = ia.size
  let kept = 0
  for (const k of ia) if (ib.has(k)) kept++
  if (n > 0 && ib.size === 0) return true
  if (n >= RULE.minItems && kept * 2 < n) return true
  if (ENCRYPTED.has(a.kind)) {
    const la = len(a), lb = len(b)
    if (la > 0 && lb === 0) return true
    if (la >= RULE.minContent && lb * 2 < la) return true
  }
  return false
}

/**
 * The alarm the newest version raises, or null. `newestFirst`: one list's versions; `own`, `dismissed`: Sets of ids.
 * -> { before, after, how: "emptied"|"drained"|"swapped"|"shrank", from, to, lost, client }
 */
export function wipeAlarm(newestFirst, own = new Set(), dismissed = new Set()) {
  const vs = newestFirst
  if (vs.length < 2) return null
  const v0 = vs[0]
  if (own.has(v0.id) || dismissed.has(v0.id)) return null
  const top = Math.min(RULE.lookback, vs.length - 1)
  let trig = null
  for (let i = 1; i <= top && trig == null; i++) {
    if (!clobbered(vs[i], v0)) continue
    let explained = false
    for (let j = 1; j < i; j++) if (clobbered(vs[i], vs[j])) { explained = true; break }
    if (!explained) trig = i
  }
  if (trig == null) return null
  // Offer back the largest version within the lookback that v0 clobbered, never older than the newest one this app
  // signed (that one is the owner's own choice).
  let stop = top
  for (let k = 1; k <= top; k++) if (own.has(vs[k].id)) { stop = k; break }
  let best = null
  for (let k = 1; k <= stop; k++) {
    if (!clobbered(vs[k], v0)) continue
    const n = items(vs[k]).size, bn = best ? items(best).size : -1
    if (!best || n > bn || (n === bn && len(vs[k]) > len(best))) best = vs[k]
  }
  if (!best) return null
  const ib = items(best), i0 = items(v0)
  const worth = ib.size >= RULE.alarmMinItems || (ENCRYPTED.has(best.kind) && len(best) >= RULE.minContent)
  if (!worth) return null
  let kept = 0, lost = 0
  for (const k of ib) { if (i0.has(k)) kept++; else lost++ }
  let how
  if (i0.size === 0 && (!ENCRYPTED.has(best.kind) || len(v0) === 0)) how = "emptied"
  else if (trig > 1) how = "drained"
  else if (ib.size >= RULE.minItems && kept * 2 < ib.size && i0.size * 2 >= ib.size) how = "swapped"
  else how = "shrank"
  const tag = (v0.tags ?? []).find(t => Array.isArray(t) && t.length >= 2 && t[0] === "client" && typeof t[1] === "string" && t[1].trim())
  return { before: best, after: v0, how, from: ib.size, to: i0.size, lost, client: tag ? tag[1].trim().slice(0, 60) : null }
}

/** What the user calls each list (iPhone/Mac ListShrinkRule.name). */
const NAMES = {
  0: "profile", 3: "follows", 10000: "mutes", 10001: "pinned notes", 10002: "relay list", 10003: "bookmarks",
  10004: "communities", 10006: "blocked relays", 10007: "search relays", 10015: "interests", 10030: "emoji list",
  10050: "DM relays", 10063: "media servers", 30000: "follow set", 30002: "relay set", 30003: "bookmark set",
}
export const listName = kind => NAMES[kind] ?? `list ${kind}`

/** The banner's line, e.g. "Your follows went from 40 to 0 on 4 Nov, changed by Amethyst." */
export function alarmLine(alarm, locale) {
  const day = new Date(alarm.after.created_at * 1000).toLocaleDateString(locale, { day: "numeric", month: "short" })
  const who = alarm.client ? `changed by ${alarm.client}` : "by an app that didn't name itself"
  const name = `Your ${listName(alarm.after.kind)}`
  switch (alarm.how) {
    case "emptied": return `${name} ${alarm.from ? `went from ${alarm.from} to 0` : "lost its private part"} on ${day}, ${who}.`
    case "swapped": return `${name} lost ${alarm.lost} of ${alarm.from} entries on ${day}, swapped for others, ${who}.`
    case "drained": return `${name} went from ${alarm.from} to ${alarm.to} in a few steps, the last on ${day}, ${who}.`
    default: return alarm.from === alarm.to
      ? `${name} lost most of its private part on ${day}, ${who}.`
      : `${name} went from ${alarm.from} to ${alarm.to} on ${day}, ${who}.`
  }
}

// ── This browser's ledgers ───────────────────────────────────────────────────────────────────────────────────────

const OWN_KEY = "nv-own-list-ids"
const DISMISSED_KEY = "nv-list-alarm-dismissed"
const CAP = 500
const store = () => globalThis.localStorage

function readSet(key) {
  try { const a = JSON.parse(store()?.getItem(key) ?? "[]"); return new Set(Array.isArray(a) ? a.filter(x => typeof x === "string") : []) } catch { return new Set() }
}
function addTo(key, id) {
  const ids = [...readSet(key)].filter(x => x !== id)
  ids.push(id)
  try { store()?.setItem(key, JSON.stringify(ids.slice(-CAP))) } catch {}
}

/** A list version this browser signed: the owner's own edit, never an alarm. Called from checkSigned (sync.js). */
export function recordOwnList(ev) {
  if (ev && typeof ev.id === "string" && isProtectedKind(ev.kind)) addTo(OWN_KEY, ev.id)
}
export const ownListIds = () => readSet(OWN_KEY)
export const dismissedAlarms = () => readSet(DISMISSED_KEY)
/** "Keep the new list": this alarm is not shown again. */
export const dismissAlarm = alarm => addTo(DISMISSED_KEY, alarm.after.id)

// ── The watcher ──────────────────────────────────────────────────────────────────────────────────────────────────

const byNewest = (a, b) => b.created_at - a.created_at || (a.id < b.id ? -1 : 1)
const listKey = v => (v.kind >= 30000 && v.kind < 40000 ? `${v.kind}:${(v.tags ?? []).find(t => t[0] === "d")?.[1] ?? ""}` : `${v.kind}`)

/** Every alarm in `versions` (any order, any list) for `me`, newest first. */
export function alarmsIn(versions, me, own = ownListIds(), dismissed = dismissedAlarms()) {
  const groups = new Map()
  const seen = new Set()
  for (const v of versions ?? []) {
    if (!v || v.pubkey !== me || !isProtectedKind(v.kind) || seen.has(v.id)) continue
    seen.add(v.id)
    const k = listKey(v)
    if (!groups.has(k)) groups.set(k, [])
    groups.get(k).push(v)
  }
  const out = []
  for (const vs of groups.values()) {
    const a = wipeAlarm(vs.sort(byNewest), own, dismissed)
    if (a) out.push(a)
  }
  return out.sort((a, b) => byNewest(a.after, b.after))
}

/** Reads the vault's list history for the signed-in user and returns the alarms. Read only. */
export async function readAlarms(ctx) {
  const me = ctx?.session?.pubkey
  if (!me || !ctx.vault?.lists) return []
  const evs = await ctx.vault.lists.query({ kinds: PROTECTED_KINDS, authors: [me], limit: 1000 }).catch(() => [])
  return alarmsIn(evs, me)
}

/** How often the open app looks again. */
export const WATCH_MS = 5 * 60 * 1000
