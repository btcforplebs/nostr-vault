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

/** Who a note replies to, for the card's "reply to @name" line: the parent's author, as the iPhone's
 *  NIP10Thread.parentAuthor. The parent's `e` tag carries it in its fifth slot (our composers and most clients send it).
 *  Failing that, the `p` tags: a reply copies the parent's `p` tags and most clients append the parent's author, so a
 *  deep reply's first `p` is the thread starter and its last the parent. A direct reply to the root keeps the first.
 *  null for a note that isn't a reply (no NIP-10 parent) or names nobody. */
export function replyToPubkey(ev) {
  if (ev?.kind !== 1) return null
  const { root, parent } = replyRefs(ev)
  if (!parent) return null
  const tag = (ev.tags ?? []).find(t => t[0] === "e" && t[1] === parent && t[3] !== "mention")
  if (HEX64.test(tag?.[4] ?? "")) return tag[4]
  const ps = (ev.tags ?? []).filter(t => t[0] === "p" && HEX64.test(t[1] ?? "")).map(t => t[1])
  return (parent === root ? ps[0] : ps.at(-1)) ?? null
}

/** The note a kind 6 repost points at (its e tag), for a repost that left the content empty. */
export const repostedId = ev => (ev?.tags ?? []).find(t => t[0] === "e" && HEX64.test(t[1] ?? ""))?.[1] ?? null

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

const repostInners = new WeakMap()
/** The note a kind 6 carries in its content, checked against its signature (verifiedCopy), or null. Cached per repost
 *  object, since feed cards ask on every render and a schnorr check costs about a millisecond. */
export function repostInner(ev) {
  if (repostInners.has(ev)) return repostInners.get(ev)
  let inner = null
  try { inner = verifiedCopy(JSON.parse(ev.content)) } catch {}
  repostInners.set(ev, inner)
  return inner
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

// How long a step waits for the other relays once one has answered (EOSE). A relay that never sends EOSE used to
// hold every step to maxWait: three steps in a row put a 3-reply thread on screen after 18 s. A relay that answers
// later is still listened to until maxWait; what it sends is stored and drawn as it lands.
export const SETTLE_MS = 700

/** Asks each relay on its own and hands every event to `onevent` as it arrives. -> { settled, done, close }:
 *  `settled` resolves once every relay has answered, SETTLE_MS after the first EOSE, or as soon as `enough(events)`;
 *  `done` once every relay has answered or given up (maxWait). Events after `settled` still reach `onevent`. */
export function streamQuery(urls, filter, { maxWait = 6000, settle = SETTLE_MS, onevent = () => {}, enough } = {}) {
  const events = [], ends = []
  let left = urls.length, timer = null, settledDone = false, resolveSettled, resolveDone
  const settled = new Promise(r => { resolveSettled = r }), done = new Promise(r => { resolveDone = r })
  const finishSettle = () => { if (settledDone) return; settledDone = true; clearTimeout(timer); resolveSettled(events) }
  const relayDone = answered => {
    if (--left === 0) { finishSettle(); resolveDone(events); return }
    if (answered && timer === null) timer = setTimeout(finishSettle, settle)
  }
  if (!left) { finishSettle(); resolveDone(events) }
  for (const url of urls) {
    let closed = false, sub = null
    const close = reasons => {
      if (closed) return
      closed = true
      relayDone([reasons].flat().some(r => /eose/i.test(r?.reason ?? r ?? "")))
    }
    // Only a subscription still open is closed: nostr-tools counts a relay's operations down on every close, so
    // closing one that already ended on EOSE would count it down twice and its idle timer would never fire.
    ends.push(() => { if (closed) return; try { sub?.close() } catch {} close("closed by caller") })
    try {
      sub = pool.subscribeEose([url], filter, {
        maxWait,
        onevent: ev => { events.push(ev); onevent(ev); if (enough?.(events)) finishSettle() },
        onclose: close,
      })
    } catch { close() }
  }
  // Closing counts every relay still open as done, so `done` can't wait on a subscription that was dropped.
  return { settled, done, close: () => ends.forEach(end => end()) }
}

/** Fetch the note, its root and the replies from the network into Haven /feed. Read-only on the network: nothing
 *  is signed. What arrives is stored at once and `onProgress()` called, so the screen can draw it straight away;
 *  `onRoot(rootId, note)` fires as soon as the root is known. Resolves when every step has settled (streamQuery);
 *  a slower relay's late answers keep arriving through `onProgress` until maxWait, and the replies they bring are
 *  chased once more. `note` is the opened one as found, which /feed may refuse (a 3D object).
 *  -> { rootId, stored, note, done }, `done` resolving when the late answers are in too. */
export async function syncThread(vault, id, relays, { maxWait = 6000, settle = SETTLE_MS, onProgress = () => {}, onRoot = () => {} } = {}) {
  const urls = uniq(relays)
  const seen = new Set(), chased = new Set(), replyIds = new Set(), tails = []
  let stored = 0, queue = Promise.resolve(), batch = null
  // What lands in one tick is written as one batch, all at once as storeAll does (one at a time, 118 replies took
  // 8 s to write at a phone's speed after the relays had sent them all in 1.4 s), then drawn once.
  const put = ev => {
    if (!ev?.id || seen.has(ev.id)) return
    seen.add(ev.id)
    if (batch) return batch.push(ev)
    batch = [ev]
    queue = queue.then(() => new Promise(r => setTimeout(r))).then(async () => {
      const evs = batch
      batch = null
      const rs = await Promise.all(evs.map(e => vault.feed.event(e).catch(() => ({}))))
      const n = rs.filter(r => r?.ok).length
      stored += n
      if (n) onProgress()
    })
  }
  const ask = (filter, opts = {}) => {
    const q = streamQuery(urls, filter, { maxWait, settle, ...opts })
    tails.push(q.done)
    return q
  }
  const replies = ev => { if (ev.kind === 1) { replyIds.add(ev.id); put(ev) } }

  const local = await vault.feed.query({ ids: [id] })
  // Replies to the opened note itself don't wait for the note: ask for them while it is being found.
  const own = ask({ kinds: [1], "#e": [id], limit: 500 }, { onevent: replies })
  let note = local[0]
  if (!note) {
    const found = ask({ ids: [id] }, { onevent: ev => { if (ev.id === id) put(ev) }, enough: evs => evs.some(e => e.id === id) })
    note = (await found.settled).find(e => e.id === id)
    if (note) found.close()
  }
  const rootId = note ? rootIdOf(note) : id
  onRoot(rootId, note ?? null)

  const steps = [own.settled]
  if (rootId !== id) {
    steps.push(ask({ ids: [rootId] }, { onevent: put, enough: evs => evs.some(e => e.id === rootId) }).settled)
    steps.push(ask({ kinds: [1], "#e": [rootId], limit: 500 }, { onevent: replies }).settled)
  }
  await Promise.all(steps)

  // Deep replies that tag only their parent (old positional tags): follow them, a hop at a time.
  const chase = async rounds => {
    for (let i = 0; i < rounds; i++) {
      const frontier = [...replyIds].filter(r => !chased.has(r))
      if (!frontier.length) return
      frontier.forEach(r => chased.add(r))
      const asks = []
      for (let j = 0; j < frontier.length; j += 100) asks.push(ask({ kinds: [1], "#e": frontier.slice(j, j + 100), limit: 500 }, { onevent: replies }).settled)
      await Promise.all(asks)
    }
  }
  chased.add(id).add(rootId)
  await chase(ROUNDS)
  await queue

  // The late answers: once every relay has answered or timed out, chase what they brought, then wait for the writes.
  const done = (async () => {
    for (let n = 0; n < tails.length; n = tails.length) await Promise.all(tails.slice(n))
    await chase(1)
    for (let n = 0; n < tails.length; n = tails.length) await Promise.all(tails.slice(n))
    await queue
    return { stored }
  })()
  return { rootId, get stored() { return stored }, note: note ?? null, done }
}
