// The Feed's three layouts, as on the iPhone (FeedLayoutMode, FeedView+Layout, FeedThreadGrouping): full cards
// (expanded), one line per note (condensed), or whole conversations (threaded). One setting per feed, cycled by one
// button; kept in this browser.
import { replyRefs } from "./thread.js"

export const LAYOUTS = ["expanded", "condensed", "threaded"]
export const LAYOUT_NAME = { expanded: "Expanded View", condensed: "Compact View", threaded: "Threaded View" }
/** Indentation stops here; deeper replies keep their order and share the last rail. */
export const MAX_DEPTH = 4
/** Replies a folded thread card shows: the newest ones, since a reply is what lifted the thread. */
export const COLLAPSED_REPLIES = 3

/** Feeds of note rows. Media, the readers (Articles, Live…) and grids have nothing to condense, so no layouts. */
export const hasLayouts = mode => ["following", "discovery", "global", "popular", "hashtag"].includes(mode)
/** The iPhone's default for a new install: every timeline feed opens in Threaded View (HavenConfig.feedLayoutModes,
 *  Logen 2026-10-08). A layout picked in this browser is kept. */
const DEFAULTS = { following: "threaded", discovery: "threaded", hashtag: "threaded", global: "threaded", popular: "threaded" }

/** The next layout in the cycle. */
export const nextLayout = layout => LAYOUTS[(LAYOUTS.indexOf(layout) + 1) % LAYOUTS.length]

const KEY = "nv:feed-layouts"
/** The layout picked for `mode`, or its default. */
export function loadLayout(mode, storage = globalThis.localStorage) {
  let saved = {}
  try { saved = JSON.parse(storage?.getItem(KEY) ?? "{}") ?? {} } catch {}
  return LAYOUTS.includes(saved[mode]) ? saved[mode] : DEFAULTS[mode] ?? "expanded"
}
export function saveLayout(mode, layout, storage = globalThis.localStorage) {
  let saved = {}
  try { saved = JSON.parse(storage?.getItem(KEY) ?? "{}") ?? {} } catch {}
  try { storage?.setItem(KEY, JSON.stringify({ ...saved, [mode]: layout })) } catch {}
}

/** The note a kind 1 answers (NIP-10), or null. Reposts and anything else answer nothing. */
const parentOf = ev => ev?.kind === 1 ? replyRefs(ev).parent : null
const taggedRoot = ev => ev?.kind === 1 ? (ev.tags ?? []).find(t => t[0] === "e" && t[3] === "root")?.[1] ?? null : null

/**
 * Arrange a newest-first feed into threads (FeedThreadGrouping.build): each note under the topmost ancestor that is
 * here (or that `resolve` can supply), else the root its NIP-10 tag names, so sibling branches stay together.
 * -> [{ rootId, root (null until fetched), entries: [{ note, depth }], latest }], by latest activity newest first,
 * or in the order roots first appear when `keepFeedOrder` (Popular is ranked, and a reply must not reshuffle it).
 */
export function buildThreads(notes, { keepFeedOrder = false, resolve = () => null } = {}) {
  const pool = new Map()
  for (const n of notes) pool.set(n.id, n)
  for (const n of notes) {
    let id = parentOf(n), hops = 0
    while (id && !pool.has(id) && hops++ < 64) {
      const found = resolve(id)
      if (!found) break
      pool.set(id, found)
      id = parentOf(found)
    }
  }
  const rootCache = new Map()
  const rootIdOf = note => {
    if (rootCache.has(note.id)) return rootCache.get(note.id)
    const chain = []
    let cur = note, hops = 0, root
    for (;;) {
      const pid = parentOf(cur)
      if (!pid || hops++ >= 64) { root = cur.id; break }
      chain.push(cur.id)
      const parent = pool.get(pid)
      if (!parent) { root = taggedRoot(cur) ?? pid; break }
      cur = parent
    }
    for (const id of [...chain, note.id]) rootCache.set(id, root)
    return root
  }
  const order = [], groups = new Map()
  const add = (note, root) => {
    if (!groups.has(root)) { groups.set(root, new Map()); order.push(root) }
    groups.get(root).set(note.id, note)
  }
  for (const n of notes) {
    const root = rootIdOf(n)
    add(n, root)
    let id = parentOf(n), hops = 0
    while (id && pool.has(id) && hops++ < 64) { add(pool.get(id), root); id = parentOf(pool.get(id)) }
    if (!pool.has(root)) { const found = resolve(root); if (found) pool.set(root, found) }
    if (pool.has(root)) add(pool.get(root), root)
  }
  const threads = order.map(rootId => {
    const members = [...groups.get(rootId).values()]
    return { rootId, root: groups.get(rootId).get(rootId) ?? null, entries: flatten(members, rootId), latest: Math.max(...members.map(m => m.created_at)) }
  })
  if (keepFeedOrder) return threads
  return threads.map((t, i) => [t, i]).sort((a, b) => b[0].latest - a[0].latest || a[1] - b[1]).map(([t]) => t)
}

/** Depth-first from the root, oldest sibling first; a note whose parent isn't in the group hangs off the root. */
function flatten(members, rootId) {
  const byId = new Map(members.map(m => [m.id, m]))
  const children = new Map(), tops = []
  for (const m of members) {
    if (m.id === rootId) continue
    const pid = parentOf(m)
    if (pid && byId.has(pid) && pid !== m.id) { if (!children.has(pid)) children.set(pid, []); children.get(pid).push(m) }
    else tops.push(m)
  }
  const byTime = (a, b) => a.created_at - b.created_at
  for (const list of children.values()) list.sort(byTime)
  tops.sort(byTime)
  const out = [], seen = new Set()
  const visit = (note, depth) => {
    if (seen.has(note.id)) return
    seen.add(note.id)
    out.push({ note, depth: Math.min(depth, MAX_DEPTH) })
    for (const c of children.get(note.id) ?? []) visit(c, depth + 1)
  }
  if (byId.has(rootId)) visit(byId.get(rootId), 0)
  for (const t of tops) visit(t, 1)
  return out
}

/** The replies under the root, in reading order. */
export const repliesOf = thread => thread.entries.filter(e => e.note.id !== thread.rootId)

/** The `limit` newest replies, kept in reading order (FeedThread.latestReplies). */
export function latestReplies(thread, limit) {
  const all = repliesOf(thread)
  if (all.length <= limit) return all
  const newest = new Set(all.map((e, i) => [e, i]).sort((a, b) => b[0].note.created_at - a[0].note.created_at || b[1] - a[1]).slice(0, limit).map(([e]) => e.note.id))
  return all.filter(e => newest.has(e.note.id))
}
