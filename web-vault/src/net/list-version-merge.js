// Merging old versions of one list (Settings › Recover a List, RESEARCH/NV_LIST_MERGE_PLAN.md): the user picks two
// or more versions the vault kept, sees what each would bring back or drop against the list they have now, and
// gets one list holding every entry of the picked versions and the current one, each entry once, every entry with a
// tick. Pure rules, nothing here reads the network or signs (list-merge-save.js signs). The Lazarus spec's delta rule
// decides when two entries are the same; haven-go list_shrink.go decides when a version was a wipe.

/** The lists that can be merged, in the order the page lists them. Not kind 0 (a profile is fields, not entries), not
 *  the relay list (only Settings › Relays' Save sends a 10002, Logen 2026-10-31) and not the addressable sets
 *  (30000/30002/30003: one list per `d`, left out as Lazarus leaves them). */
export const MERGE_KINDS = [
  { kind: 3, name: "Follows", noun: "follow" },
  { kind: 10000, name: "Mutes", noun: "muted entry" },
  { kind: 10003, name: "Bookmarks", noun: "bookmark" },
  { kind: 10063, name: "Media servers", noun: "server" },
  { kind: 10050, name: "DM relays", noun: "relay" },
  { kind: 10006, name: "Blocked relays", noun: "relay" },
  { kind: 10007, name: "Search relays", noun: "relay" },
  { kind: 10015, name: "Interests", noun: "interest" },
  { kind: 10001, name: "Pinned notes", noun: "pinned note" },
  { kind: 10004, name: "Communities", noun: "community" },
  { kind: 10030, name: "Emoji", noun: "emoji" },
]
export const mergeKind = kind => MERGE_KINDS.find(k => k.kind === kind)

/** Tags that name or describe a list rather than being an entry in it (haven-go listMetadataTags). */
const META = new Set(["d", "title", "name", "description", "image", "alt", "client"])
const isMeta = t => META.has(t[0])

/** Kinds whose content is never a private part: kind 3 keeps relay hints there. */
const NO_PRIVATE = new Set([3])
/** Encrypted kinds, where a wipe is also seen in the content's length (haven-go encryptedListKinds). */
const ENCRYPTED = new Set([10000, 10003, 30000, 30003])

/** Whether `ev` carries a private part to open: NIP-51 content, encrypted to the user. */
export const hasPrivate = ev => !NO_PRIVATE.has(ev?.kind) && typeof ev?.content === "string" && ev.content.trim() !== ""

/** A relay or server address as Lazarus compares them: scheme and host lowercased, default port dropped, repeated
 *  slashes collapsed, trailing slash dropped. Not an address: the trimmed text as it is. */
export function normUrl(raw) {
  const s = String(raw ?? "").trim()
  let u
  try { u = new URL(s) } catch { return s.replace(/\/+$/, "") }
  const scheme = u.protocol.toLowerCase()
  const dflt = { "wss:": "443", "https:": "443", "ws:": "80", "http:": "80" }[scheme]
  const port = u.port && u.port !== dflt ? `:${u.port}` : ""
  const path = u.pathname.replace(/\/{2,}/g, "/").replace(/\/+$/, "")
  return `${scheme}//${u.hostname.toLowerCase()}${port}${path}${u.search}`
}

const URL_TAGS = { 10002: "r", 10050: "relay", 10006: "relay", 10007: "relay", 10063: "server" }
const LOWER = new Set(["p", "e", "t", "word"])

/**
 * One entry's identity: `tag[0]` and `tag[1]` (a rewritten relay hint or petname is the same entry), hex and words
 * lowercased, relay and server addresses normalized. -> key, or null for a tag that isn't an entry (no value, or one
 * naming the list).
 */
export function itemKey(kind, tag) {
  if (!Array.isArray(tag) || typeof tag[0] !== "string" || isMeta(tag)) return null
  const v = typeof tag[1] === "string" ? tag[1].trim() : ""
  if (!v) return null
  const value = URL_TAGS[kind] === tag[0] ? normUrl(v) : LOWER.has(tag[0]) ? v.toLowerCase() : v
  return `${tag[0]}\u0000${value}`
}

/** Public entries as haven-go counts them (every tag but the list's own), for the wipe rule. */
const rawCount = ev => (ev?.tags ?? []).filter(t => Array.isArray(t) && t.length && !isMeta(t)).length

/**
 * Whether `next`, the version that replaced `prev`, was a wipe rather than an edit (haven-go listShrank): empty where
 * `prev` was not, or under half of a list of 10 or more; on encrypted kinds the content's length counts the same way
 * (1000 characters, about ten private entries).
 */
export function shrank(prev, next) {
  if (!prev || !next) return false
  const a = rawCount(prev), b = rawCount(next)
  if (a > 0 && b === 0) return true
  if (a >= 10 && b * 2 < a) return true
  if (ENCRYPTED.has(prev.kind)) {
    const la = (prev.content ?? "").length, lb = (next.content ?? "").length
    if (la > 0 && lb === 0) return true
    if (la >= 1000 && lb * 2 < la) return true
  }
  return false
}

/**
 * A version opened for merging: its entries, public and private, each once (an entry listed twice, or both publicly
 * and privately, is one entry, and private wins). `open(content)` is the signer's decrypt; it is only asked when the
 * version has a private part. `open` undefined: the private part is left for later (the page opens a version's only
 * when it is ticked, so a NIP-07 or bunker signer isn't asked once per version on opening the list) and the version
 * is `locked`. -> { ev, entries: Map(key -> { tag, private }), reason, locked } where `reason` says why the private
 * part couldn't be opened ("" when it could, or there is none).
 */
export async function openVersion(ev, open) {
  const entries = new Map()
  const add = (tag, priv) => {
    const key = itemKey(ev.kind, tag)
    if (!key) return
    const had = entries.get(key)
    if (!had) entries.set(key, { tag: tag.map(String), private: priv })
    else if (priv && !had.private) had.private = true
  }
  for (const t of ev.tags ?? []) add(t, false)
  let reason = ""
  if (hasPrivate(ev) && open === undefined) return { ev, entries, reason, locked: true }
  if (hasPrivate(ev)) {
    if (!open) reason = "this sign-in can't open private entries"
    else {
      try {
        const tags = JSON.parse(await open(ev.content.trim()))
        if (!Array.isArray(tags)) throw new Error("it isn't a list")
        for (const t of tags) add(t, true)
      } catch (e) { reason = `its private part couldn't be opened (${e?.message ?? e})` }
    }
  }
  return { ev, entries, reason, locked: false }
}

/** A version whose private part wasn't read (left for later, or couldn't be opened): what it held privately is unknown. */
export const unread = v => !!(v.reason || v.locked)

/** Empty: no entries, and no private part left unopened (that one may hold any number). Never offered (Lazarus
 *  invariant 3, Logen: never suggest an empty list). */
export const isEmpty = v => v.entries.size === 0 && !unread(v)

/** Why a version can't be picked, or "". */
export function pickProblem(v) {
  if (isEmpty(v)) return "Empty: nothing to bring back."
  if (v.reason) return `Can't be merged: ${v.reason}.`
  return ""
}

/** What one version would bring back (+) and drop (-) against the current list. */
export function deltaOf(version, current) {
  const now = current?.entries ?? new Map()
  return {
    added: [...version.entries.keys()].filter(k => !now.has(k)).length,
    removed: [...now.keys()].filter(k => !version.entries.has(k)).length,
  }
}

const newestFirst = (a, b) => b.ev.created_at - a.ev.created_at || (a.ev.id < b.ev.id ? -1 : 1)

/** Versions the vault keeps with no hole between them: its newest 20 of a list (haven-go listHistoryKeep). Beyond
 *  those it keeps only what a wipe pins, so the versions in between are gone. */
export const VAULT_KEEP = 20
/** How many versions before a new one it is compared with, so a list emptied in steps (40, 20, 10, 5) is one wipe
 *  (haven-go shrinkLookback, PR 1587). */
export const LOOKBACK = 5
/** Relay and server lists: short, and a dropped relay is never a "people I unfollowed" call, so whatever an old
 *  version had comes back ticked (Logen 2026-11-03, Hal's review point 2). 10002 is here for the rule's sake; it isn't
 *  offered for merging (MERGE_KINDS). */
const RELAY_KINDS = new Set([10002, 10050, 10006, 10007, 10063])
/** Under this many entries a removal can't be told from a wipe by numbers, so it comes back ticked too. */
export const SHORT = 10

/** The ids of the versions with no hole between them: found in the vault, and among its newest VAULT_KEEP. A step
 *  between two of these is the whole story; any other step may hide versions nobody kept (Hal's point 3). */
export function unbroken(all) {
  const kept = [...all].filter(v => v.ev.from?.includes("vault")).sort(newestFirst).slice(0, VAULT_KEEP)
  return new Set(kept.map(v => v.ev.id))
}

/** Whether `next` kept under half of `prev`'s entries (prev 10 or more), or none of a list that had some. By which
 *  entries went, not by count: a stale list of the same size that swapped them out is a wipe (Hal's point 1). */
export function wipedBy(prev, next) {
  const a = prev.entries.size
  if (!a) return false
  if (!next.entries.size) return true
  if (a < SHORT) return false
  let kept = 0
  for (const k of prev.entries.keys()) if (next.entries.has(k)) kept++
  return kept * 2 < a
}

/**
 * Whether the entry `key`, held by timeline[i] and gone from timeline[i - 1] on, went in a wipe: some version `o` at or
 * up to LOOKBACK before i that held it was wiped by some version `w` from i - 1 up to LOOKBACK newer (o and w at most
 * LOOKBACK apart), with no version between them already a wipe of `o` (that one is the wipe; edits after it are the
 * user's). Only over `ok` versions (unbroken and read): a gap or an unread part stops the window.
 * -> the wipe's version, or null.
 */
function wipeOf(timeline, i, key, ok, memo) {
  const wiped = (o, w) => {
    const id = `${timeline[o].ev.id}:${timeline[w].ev.id}`
    if (!memo.has(id)) memo.set(id, wipedBy(timeline[o], timeline[w]))
    return memo.get(id)
  }
  for (let o = i; o < timeline.length && o - i < LOOKBACK && ok(timeline[o]); o++) {
    if (!timeline[o].entries.has(key)) continue
    for (let w = i - 1; w >= 0 && o - w <= LOOKBACK && ok(timeline[w]); w--) {
      if (!wiped(o, w)) continue
      let earlier = false
      for (let b = o - 1; b > w && !earlier; b--) earlier = wiped(o, b)
      if (!earlier) return timeline[w]
    }
  }
  return null
}

/**
 * The merge: every entry of `current` and of each version in `picked`, each once, as rows to tick. `all` is every
 * version found (opened), for working out what happened to an entry after the newest of them that held it:
 * - "current": in the list now, ticked;
 * - "back": no later version is known, or the list was short or a relay list then (anything goes back), ticked;
 * - "lost": a wipe took it (wipeOf), ticked, `at` = when;
 * - "removed": an ordinary edit took it, so the user did: unticked, `at` = when;
 * - "unsure": the step that dropped it can't be judged (a gap between the versions not bridged by a wipe, or any newer version unread): unticked,
 *   as Lazarus leaves it (Logen 2026-11-03), `at` = when.
 * A row is private when the entry is private in any version, or a newer unread version may hold it privately. Its tag
 * is the current version's, else the newest picked version's that holds it (so a 10002 keeps the list now's read/
 * write marker). Order: the current list's, then what comes back, newest version first.
 * -> [{ key, tag, private, status, at, ticked, from: [version ids] }]
 */
export function buildMerge({ current, picked, all }) {
  const sources = [...(current ? [current] : []), ...[...picked].filter(v => v.ev.id !== current?.ev.id).sort(newestFirst)]
  const timeline = [...all].sort(newestFirst) // newest first
  const run = unbroken(all)
  const ok = v => run.has(v.ev.id) && !unread(v)
  const memo = new Map()
  const rows = new Map()
  for (const v of sources) {
    for (const [key, e] of v.entries) {
      const row = rows.get(key)
      if (row) { row.private ||= e.private; row.from.push(v.ev.id); continue }
      rows.set(key, { key, tag: e.tag, private: e.private, from: [v.ev.id] })
    }
  }
  // Private anywhere it was ever listed, not only in the merged versions: an entry the user moved to the private part
  // after a picked version must not come back public (Tron, PR 1570). A newer version whose private part wasn't read
  // may hold it privately, so then it is private too: hiding an entry that was public loses nothing, publishing one
  // that was hidden can't be undone.
  for (const row of rows.values()) {
    if (all.some(v => v.entries.get(row.key)?.private)) { row.private = true; continue }
    if (current?.entries.has(row.key)) continue
    const i = timeline.findIndex(v => v.entries.has(row.key))
    if (timeline.slice(0, i < 0 ? timeline.length : i).some(v => !NO_PRIVATE.has(v.ev.kind) && unread(v))) row.private = true
  }
  for (const row of rows.values()) {
    if (current?.entries.has(row.key)) { Object.assign(row, { status: "current", at: 0, ticked: true }); continue }
    // The newest version holding it (of all found, picked or not), then the one that replaced that.
    const i = timeline.findIndex(v => v.entries.has(row.key))
    const held = timeline[i], next = i > 0 ? timeline[i - 1] : null
    if (!next || RELAY_KINDS.has(held.ev.kind) || (held.entries.size < SHORT && !unread(held))) {
      Object.assign(row, { status: "back", at: 0, ticked: true }); continue
    }
    const unsure = () => Object.assign(row, { status: "unsure", at: next.ev.created_at, ticked: false })
    // Any newer version with its private part unread may still hold it privately: can't tell (strict, all three apps).
    if (timeline.slice(0, i).some(unread) || unread(held)) { unsure(); continue }
    // A gap between H and the next: can't tell, unless that next one wiped H (the vault pins a wipe with the one before).
    if (!run.has(held.ev.id) || !run.has(next.ev.id)) {
      if (wipedBy(held, next)) Object.assign(row, { status: "lost", at: next.ev.created_at, ticked: true })
      else unsure()
      continue
    }
    const wipe = wipeOf(timeline, i, row.key, ok, memo)
    if (wipe) Object.assign(row, { status: "lost", at: wipe.ev.created_at, ticked: true })
    else Object.assign(row, { status: "removed", at: next.ev.created_at, ticked: false })
  }
  return [...rows.values()]
}

/** Whether timeline[j] (newest first) wiped the list: against any of the LOOKBACK versions before it that it wiped
 *  with no version between already wiping that one (wipeOf, for the whole list). Unread or count-only: `shrank`. */
export function wasWipe(timeline, j) {
  const v = timeline[j]
  if (j + 1 >= timeline.length) return false
  if (unread(v) || unread(timeline[j + 1])) return shrank(timeline[j + 1].ev, v.ev)
  for (let o = j + 1; o < timeline.length && o - j <= LOOKBACK && !unread(timeline[o]); o++) {
    if (!wipedBy(timeline[o], v)) continue
    let earlier = false
    for (let b = o - 1; b > j && !earlier; b--) earlier = wipedBy(timeline[o], timeline[b])
    if (!earlier) return true
  }
  return false
}

/**
 * The new list's tags: the current version's own tags (d, title, …) first, then each ticked public row's tag; the
 * ticked private rows' tags go in `privateTags`. -> { tags, privateTags }
 */
export function mergedTags(rows, current) {
  const tags = (current?.ev.tags ?? []).filter(t => Array.isArray(t) && isMeta(t)).map(t => t.map(String))
  const privateTags = []
  for (const row of rows) if (row.ticked) (row.private ? privateTags : tags).push([...row.tag])
  return { tags, privateTags }
}

/** Against the current list: what Save would add and remove, what stays out, and what a mute list would mute again
 *  by type (Lazarus: a moderation action taken for the user, so it is said before Save; Hal's point 11: words,
 *  hashtags and threads too, not only people). */
export function mergeSummary(kind, rows) {
  const ticked = rows.filter(r => r.ticked)
  const added = ticked.filter(r => r.status !== "current")
  const of = t => kind === 10000 ? added.filter(r => r.tag[0] === t).length : 0
  return {
    total: ticked.length,
    added: added.length,
    removed: rows.filter(r => r.status === "current" && !r.ticked).length,
    leftOut: rows.filter(r => r.status === "removed" && !r.ticked).length,
    unsure: rows.filter(r => r.status === "unsure" && !r.ticked).length,
    remutes: { people: of("p"), words: of("word"), hashtags: of("t"), threads: of("e") },
  }
}

const plural = (n, noun) => n === 1 ? noun : noun.endsWith("y") ? `${noun.slice(0, -1)}ies` : `${noun}s`

/** A version's one-line summary against the list now, the page's default view (Logen 2026-11-02: no long per-item
 *  checklist): "+340 follows, −2", "Same as now". */
export function deltaLine(kind, { added, removed }) {
  if (!added && !removed) return "Same as now"
  const noun = mergeKind(kind)?.noun ?? "entry"
  const parts = []
  if (added) parts.push(`+${added} ${plural(added, noun)}`)
  if (removed) parts.push(added ? `−${removed}` : `−${removed} ${plural(removed, noun)}`)
  return parts.join(", ")
}

/**
 * Before a merge: open the private parts still locked in every version as new as the oldest picked one or newer. Those are
 * the versions that may have removed or hidden a picked entry, so without them "removed on purpose stays out" can't
 * be told (Tron, PR 1570). Runs on the Merge tap, so signer prompts still only follow a tap. -> the versions, the
 * needed ones opened (one that fails keeps its `reason`).
 */
export async function openForMerge(versions, picked, open) {
  const oldest = Math.min(...[...picked].map(v => v.ev.created_at))
  return Promise.all(versions.map(v => v.locked && v.ev.created_at >= oldest ? openVersion(v.ev, open) : v))
}
