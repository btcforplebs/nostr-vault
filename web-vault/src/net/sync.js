// Network -> in-page Haven. Every event that comes in is written to Haven (the user's own events to the
// outbox route, follows' notes to /feed); the screens read only from Haven.
import { pool, relayLists, uniq } from "./pool.js"

export const FEED_KINDS = [1, 6]
const now = () => Math.floor(Date.now() / 1000)
const newest = evs => evs.reduce((a, e) => (!a || e.created_at > a.created_at ? e : a), undefined)

/** The account as Haven has it: kind 0, 3 and 10002 from the outbox route. Works offline. */
export async function readAccount(vault, pubkey) {
  const evs = await vault.outbox.query({ kinds: [0, 3, 10002], authors: [pubkey] })
  return account(evs)
}

function account(evs) {
  const by = k => newest(evs.filter(e => e.kind === k))
  const k3 = by(3)
  return {
    profileEvent: by(0),
    contacts: k3,
    follows: uniq((k3?.tags ?? []).filter(t => t[0] === "p" && /^[0-9a-f]{64}$/.test(t[1] ?? "")).map(t => t[1])),
    relays: relayLists(by(10002)),
  }
}

/** Fetch the account's replaceable events from the network into Haven, then read it back from Haven. */
export async function refreshAccount(vault, pubkey, hintRelays, { log = () => {} } = {}) {
  const evs = await pool.querySync(hintRelays, { kinds: [0, 3, 10002], authors: [pubkey] }, { maxWait: 6000 })
  for (const k of [0, 3, 10002]) {
    const ev = newest(evs.filter(e => e.kind === k))
    if (!ev) continue
    const r = await vault.outbox.event(ev)
    if (!r.ok && !/^duplicate:/.test(r.message)) log("account-store-refused", { kind: k, message: r.message })
  }
  return readAccount(vault, pubkey)
}

/** The Following feed from Haven /feed, newest first. */
export async function readFeed(vault, follows, { limit = 100, until } = {}) {
  if (!follows.length) return []
  const evs = await vault.feed.query({ kinds: FEED_KINDS, authors: follows, limit, ...(until ? { until } : {}) })
  return evs.sort((a, b) => b.created_at - a.created_at)
}

/** Pull follows' notes since the newest one cached (or the last two days) into Haven /feed. -> notes stored */
export async function syncFeed(vault, follows, relays, { onProgress = () => {} } = {}) {
  if (!follows.length) return 0
  // querySync treats a relay it can't reach as an empty answer, so check that at least one relay is up first.
  const up = await Promise.allSettled(relays.map(url => pool.ensureRelay(url, { connectionTimeout: 5000 })))
  if (!up.some(r => r.status === "fulfilled")) throw new Error("no relay reachable")
  const top = (await readFeed(vault, follows, { limit: 1 }))[0]
  const since = top ? top.created_at - 600 : now() - 2 * 86400
  let stored = 0
  for (let i = 0; i < follows.length; i += 250) {
    const evs = await pool.querySync(relays, { kinds: FEED_KINDS, authors: follows.slice(i, i + 250), since, limit: 500 }, { maxWait: 8000 })
    for (const ev of evs) if ((await vault.feed.event(ev)).ok) stored++
    onProgress({ done: Math.min(i + 250, follows.length), of: follows.length, stored })
  }
  return stored
}

/** The user's own notes and articles from their write relays into Haven's outbox route. */
export async function syncOwn(vault, pubkey, relays) {
  const evs = await pool.querySync(relays, { kinds: [1, 30023], authors: [pubkey], limit: 300 }, { maxWait: 8000 })
  let stored = 0
  for (const ev of evs) if ((await vault.outbox.event(ev)).ok) stored++
  return stored
}

export async function readOwn(vault, pubkey, kinds, limit = 100) {
  const evs = await vault.outbox.query({ kinds, authors: [pubkey], limit })
  return evs.sort((a, b) => b.created_at - a.created_at)
}

/** Sign, store in Haven's outbox, then send to the write relays. -> { event, local, relays: [{url, ok, message}] } */
export async function publishNote(vault, signer, content, writeRelays) {
  const event = await signer.signEvent({ kind: 1, created_at: now(), tags: [], content })
  const local = await vault.outbox.event(event)
  if (!local.ok) throw new Error(`Haven refused the note: ${local.message}`)
  const urls = uniq(writeRelays)
  const results = await Promise.allSettled(pool.publish(urls, event))
  return { event, local, relays: results.map((r, i) => ({ url: urls[i], ok: r.status === "fulfilled", message: r.status === "fulfilled" ? r.value : String(r.reason?.message ?? r.reason) })) }
}
