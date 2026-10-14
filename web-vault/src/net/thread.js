// A note's thread: the network fills Haven /feed with the root and its replies, the screen reads them back from
// Haven, and buildThread() turns them into a tree from the NIP-10 `e` tags.
import { verifyEvent } from "nostr-tools/pure"
import { pool, uniq } from "./pool.js"

const HEX64 = /^[0-9a-f]{64}$/
const ROUNDS = 3 // reply-to-reply hops to chase when a deep reply only tags its parent (old positional tags)

/** NIP-10 root and parent of a kind 1. Marked tags ("root"/"reply") win; with no markers, the old positional rule:
 *  one `e` is both root and parent, otherwise the first is the root and the last the parent (the rest are mentions).
 *  -> { root, parent } with null where the note doesn't say; both null for a note that isn't a reply. */
export function replyRefs(ev) {
  const es = (ev?.tags ?? []).filter(t => t[0] === "e" && HEX64.test(t[1] ?? "") && t[1] !== ev.id)
  if (!es.length) return { root: null, parent: null }
  const marked = es.filter(t => t[3] === "root" || t[3] === "reply")
  if (marked.length) {
    const root = marked.find(t => t[3] === "root")?.[1] ?? null
    const parent = marked.find(t => t[3] === "reply")?.[1] ?? root
    return { root: root ?? parent, parent }
  }
  // Only "mention" markers left means it quotes notes but replies to none.
  const positional = es.filter(t => !t[3])
  if (!positional.length) return { root: null, parent: null }
  return { root: positional[0][1], parent: positional.at(-1)[1] }
}

/** Build the tree under rootId from any bag of events (duplicates and unrelated notes are fine).
 *  A reply whose parent isn't in the bag hangs off the root, so nothing fetched is lost; root is null when the
 *  root itself wasn't found. Replies are oldest first at every level.
 *  -> { root, replies: [{ event, children: [...] }], count } */
export function buildThread(rootId, events) {
  const byId = new Map()
  for (const ev of events) if (ev?.kind === 1 && ev.id && !byId.has(ev.id)) byId.set(ev.id, ev)
  const root = byId.get(rootId) ?? null

  const nodes = new Map()
  for (const ev of byId.values()) {
    if (ev.id === rootId) continue
    const { root: r, parent } = replyRefs(ev)
    if (!parent) continue
    nodes.set(ev.id, { event: ev, children: [], parent, inThread: r === rootId || parent === rootId })
  }
  // A reply belongs if it names this root, or its parent chain reaches a reply that does (old positional tags
  // on a deep reply can name only the parent). Walk up with a visited set so a tag loop can't spin.
  const belongs = new Map()
  const reaches = id => {
    const seen = []
    let cur = nodes.get(id), ok = false
    while (cur && !seen.includes(cur)) {
      if (belongs.has(cur.event.id)) { ok = belongs.get(cur.event.id); break }
      seen.push(cur)
      if (cur.inThread) { ok = true; break }
      cur = nodes.get(cur.parent)
    }
    for (const n of seen) belongs.set(n.event.id, ok)
    return ok
  }

  const replies = []
  let count = 0
  for (const n of nodes.values()) {
    if (!reaches(n.event.id)) continue
    count++
    const up = n.parent !== rootId && nodes.get(n.parent)
    if (up && reaches(up.event.id) && !isAncestor(n, up, nodes)) up.children.push(n)
    else replies.push(n)
  }
  const sort = list => { list.sort((a, b) => a.event.created_at - b.event.created_at || (a.event.id < b.event.id ? -1 : 1)); list.forEach(n => sort(n.children)) }
  sort(replies)
  const strip = n => ({ event: n.event, children: n.children.map(strip) })
  return { root, replies: replies.map(strip), count }
}

// True when `node` is already above `candidate`, i.e. hanging node under candidate would make a cycle.
function isAncestor(node, candidate, nodes) {
  const seen = new Set()
  for (let cur = candidate; cur && !seen.has(cur); cur = nodes.get(cur.parent)) {
    if (cur === node) return true
    seen.add(cur)
  }
  return false
}

/** Depth-first list for rendering: [{ event, depth }], root's direct replies at depth 1. */
export function flattenThread(replies, depth = 1) {
  return replies.flatMap(n => [{ event: n.event, depth }, ...flattenThread(n.children, depth + 1)])
}

/** The root id for a note: its own id unless it is a reply. */
export const rootIdOf = ev => replyRefs(ev).root ?? ev.id

/** The note a repost in Haven /feed carries for `id`: the feed stores the kind 6, not the note inside it, so a
 *  reposted note's thread would otherwise open offline without its root. Signature checked, since the embedded copy
 *  is only as good as whoever reposted it. -> the kind 1, or null */
export async function repostedNote(vault, id) {
  for (const repost of await vault.feed.query({ kinds: [6], "#e": [id], limit: 20 })) {
    let inner
    try { inner = JSON.parse(repost.content) } catch { continue }
    if (inner?.id !== id || inner.kind !== 1) continue
    const note = verifiedCopy(inner)
    if (note) return note
  }
  return null
}

/** `ev` checked against its signature, as a copy holding only the signed fields: verifyEvent trusts a "verified"
 *  flag an event object can carry, and that flag survives a spread. A malformed event never throws, it is just not
 *  verified. -> the copy, or null */
export function verifiedCopy(ev) {
  try {
    const { id, pubkey, created_at, kind, tags, content, sig } = ev
    const copy = { id, pubkey, created_at, kind, tags, content, sig }
    return verifyEvent(copy) ? copy : null
  } catch { return null }
}

/** Everything Haven /feed has for this thread. Works offline. */
export async function readThread(vault, rootId) {
  const [stored, replies] = await Promise.all([
    vault.feed.query({ ids: [rootId] }),
    vault.feed.query({ kinds: [1], "#e": [rootId], limit: 1000 }),
  ])
  const roots = stored.length ? stored : [await repostedNote(vault, rootId)].filter(Boolean)
  const evs = [...roots, ...replies]
  // Deep replies that tag only their parent: follow them through Haven too.
  let frontier = replies.map(e => e.id)
  for (let i = 0; i < ROUNDS && frontier.length; i++) {
    const have = new Set(evs.map(e => e.id))
    const more = (await vault.feed.query({ kinds: [1], "#e": frontier, limit: 1000 })).filter(e => !have.has(e.id))
    evs.push(...more)
    frontier = more.map(e => e.id)
  }
  return evs
}

/** Fetch the note, its root and the replies from the network into Haven /feed. Read-only on the network: nothing
 *  is signed. -> { rootId, stored } */
export async function syncThread(vault, id, relays, { maxWait = 6000 } = {}) {
  const urls = uniq(relays)
  const store = async evs => { let n = 0; for (const ev of evs) if ((await vault.feed.event(ev)).ok) n++; return n }

  const local = await vault.feed.query({ ids: [id] })
  const [note] = local.length ? local : await pool.querySync(urls, { ids: [id] }, { maxWait })
  const rootId = note ? rootIdOf(note) : id
  let stored = note && !local.length ? await store([note]) : 0

  const ids = uniq([id, rootId])
  const [roots, replies] = await Promise.all([
    rootId === id ? [] : pool.querySync(urls, { ids: [rootId] }, { maxWait }),
    pool.querySync(urls, { kinds: [1], "#e": ids, limit: 500 }, { maxWait }),
  ])
  stored += await store([...roots, ...replies])

  const seen = new Set([...ids, ...replies.map(e => e.id)])
  let frontier = replies.map(e => e.id)
  for (let i = 0; i < ROUNDS && frontier.length; i++) {
    const more = []
    for (let j = 0; j < frontier.length; j += 100) {
      more.push(...(await pool.querySync(urls, { kinds: [1], "#e": frontier.slice(j, j + 100), limit: 500 }, { maxWait })).filter(e => !seen.has(e.id)))
    }
    stored += await store(more)
    more.forEach(e => seen.add(e.id))
    frontier = uniq(more.map(e => e.id))
  }
  return { rootId, stored }
}
