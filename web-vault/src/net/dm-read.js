// Which messages the user has read (iPhone DMConversation.unreadCount / DMService markAsRead / markAllAsRead).
// Kept per account in localStorage "nv-dm-read:<pubkey>" as { before, read: [[id, at], ...] }: a message is read when
// it is older than `before` or its id is listed. Only event ids and times are written, never text. A NIP-17 wrap id
// names no one (the wrap is from a throwaway key); a kind 4 id is as public as the kind 4 itself, which already
// names both people on every relay that holds it.
// The first time an account opens Messages here `before` is now, so years of history don't arrive as unread. Past
// MAX_READ_IDS the oldest ids go and `before` moves up past them, so they stay read.
const KEY = me => `nv-dm-read:${me}`
export const MAX_READ_IDS = 2000
const now = () => Math.floor(Date.now() / 1000)
const memory = new Map() // fallback when localStorage is missing or refuses (private mode, quota)
const cache = new Map() // me -> { before, read: Map id -> at }
const listeners = new Set()
export function onRead(cb) { listeners.add(cb); return () => listeners.delete(cb) }
const changed = () => { for (const cb of listeners) cb() }

// Another tab read or marked something: drop this tab's copy so the next count reads storage.
globalThis.addEventListener?.("storage", e => { if (e.key == null || e.key.startsWith("nv-dm-read:")) { cache.clear(); changed() } })

const get = (storage, k) => { try { return storage?.getItem(k) ?? memory.get(k) ?? null } catch { return memory.get(k) ?? null } }
const put = (storage, k, v) => { memory.set(k, v); try { storage?.setItem(k, v) } catch {} }

function parse(raw) {
  try {
    const d = JSON.parse(raw ?? "null")
    if (!d || !Number.isFinite(d.before) || !Array.isArray(d.read)) return null
    return { before: d.before, read: new Map(d.read.filter(e => Array.isArray(e) && typeof e[0] === "string" && Number.isFinite(e[1]))) }
  } catch { return null }
}

/** The account's read marker, created (everything before now read) the first time. */
export function readState(me, { storage = globalThis.localStorage, clock = now } = {}) {
  if (cache.has(me)) return cache.get(me)
  let r = parse(get(storage, KEY(me)))
  if (!r) { r = { before: clock(), read: new Map() }; put(storage, KEY(me), JSON.stringify({ before: r.before, read: [] })) }
  cache.set(me, r)
  return r
}

// Merge with what another tab may have saved since, cap, write back.
function save(me, r, storage) {
  const other = parse(get(storage, KEY(me)))
  if (other) { r.before = Math.max(r.before, other.before); for (const [id, at] of other.read) if (!r.read.has(id)) r.read.set(id, at) }
  for (const [id, at] of r.read) if (at < r.before) r.read.delete(id)
  if (r.read.size > MAX_READ_IDS) {
    const byTime = [...r.read].sort((a, b) => a[1] - b[1])
    const drop = byTime.slice(0, r.read.size - MAX_READ_IDS)
    r.before = Math.max(r.before, drop[drop.length - 1][1] + 1)
    for (const [id, at] of byTime) if (at < r.before) r.read.delete(id)
  }
  put(storage, KEY(me), JSON.stringify({ before: r.before, read: [...r.read] }))
}

/** Someone else's message the user hasn't seen. */
export const isUnread = (m, me, r) => m.from !== me && m.at >= r.before && !r.read.has(m.id)

/** Unread messages per conversation, blocked people left out. -> Map peer -> count */
export function unreadCounts(messages, me, blocked = new Set(), opts) {
  const r = readState(me, opts)
  const out = new Map()
  for (const m of messages.values()) if (!blocked.has(m.peer) && isUnread(m, me, r)) out.set(m.peer, (out.get(m.peer) ?? 0) + 1)
  return out
}

/** All unread messages, for a badge. */
export const unreadTotal = (messages, me, blocked, opts) => [...unreadCounts(messages, me, blocked, opts).values()].reduce((a, b) => a + b, 0)

/** These messages are read: opening a conversation (DMThreadView markAsRead), or every open message for "Mark all
 *  read" (DMInboxView markAllAsRead). Messages not opened yet ("Open more") stay unread. -> how many were newly read */
export function markRead(me, messages, opts = {}) {
  const r = readState(me, opts)
  let n = 0
  for (const m of messages) if (isUnread(m, me, r)) { r.read.set(m.id, m.at); n++ }
  if (n) { save(me, r, opts.storage ?? globalThis.localStorage); changed() }
  return n
}

/** Tests: forget what was loaded, so the next readState reads storage again. */
export const forgetReadCache = () => { cache.clear(); memory.clear() }
