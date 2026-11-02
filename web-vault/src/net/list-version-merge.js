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

const URL_TAGS = { 10050: "relay", 10006: "relay", 10007: "relay", 10063: "server" }
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

/**
 * The merge: every entry of `current` and of each version in `picked`, each once, as rows to tick. `all` is every
 * version found (opened), for working out what happened to an entry after the newest version that held it:
 * - "current": in the list now, ticked;
 * - "lost": the next version was a wipe (shrank), ticked, `at` = when;
 * - "removed": the next version was an ordinary edit, so the user took it out: unticked, `at` = when;
 * - "back": no later version is known, ticked.
 * A row is private when the entry is private in the current version or any picked one. Its tag is the current
 * version's, else the newest picked version's that holds it. Order: the current list's, then what comes back, newest
 * version first. -> [{ key, tag, private, status, at, ticked, from: [version ids] }]
 */
export function buildMerge({ current, picked, all }) {
  const sources = [...(current ? [current] : []), ...[...picked].filter(v => v.ev.id !== current?.ev.id).sort(newestFirst)]
  const timeline = [...all].sort(newestFirst) // newest first
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
    // The newest version holding it, then the one that replaced that.
    const i = timeline.findIndex(v => v.entries.has(row.key))
    const next = i > 0 ? timeline[i - 1] : null
    if (!next) Object.assign(row, { status: "back", at: 0, ticked: true })
    else if (shrank(timeline[i].ev, next.ev)) Object.assign(row, { status: "lost", at: next.ev.created_at, ticked: true })
    // The next version's private part unopened: whether it still held the entry isn't known, so it isn't called a removal.
    else if (unread(next) && row.private) Object.assign(row, { status: "back", at: 0, ticked: true })
    else Object.assign(row, { status: "removed", at: next.ev.created_at, ticked: false })
  }
  return [...rows.values()]
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

/** Against the current list: what Save would add and remove, and how many people a mute list would mute again
 *  (Lazarus: a moderation action taken for the user, so it is said before Save). */
export function mergeSummary(kind, rows) {
  const ticked = rows.filter(r => r.ticked)
  const added = ticked.filter(r => r.status !== "current")
  return {
    total: ticked.length,
    added: added.length,
    removed: rows.filter(r => r.status === "current" && !r.ticked).length,
    remutes: kind === 10000 ? added.filter(r => r.tag[0] === "p").length : 0,
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
