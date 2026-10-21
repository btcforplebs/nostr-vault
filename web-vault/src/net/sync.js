// Network -> in-page Haven. Every event that comes in is written to Haven (the user's own events to the
// outbox route, follows' notes to /feed); the screens read only from Haven.
import { verifyEvent } from "nostr-tools/pure"
import { pool, publishRelays, relayLists, uniq } from "./pool.js"

// Notes and reposts, plus the articles, polls and highlights the iPhone shows in Following (FeedServiceTypes.timelineKinds).
export const FEED_KINDS = [1, 6, 30023, 1068, 9802]
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
  // Articles get their own filter: with one shared limit, a busy account's notes fill it and no article comes back.
  const [notes, articles] = await Promise.all([
    pool.querySync(relays, { kinds: [1], authors: [pubkey], limit: 300 }, { maxWait: 8000 }),
    pool.querySync(relays, { kinds: [30023], authors: [pubkey], limit: 50 }, { maxWait: 8000 }),
  ])
  const evs = [...notes, ...articles]
  let stored = 0
  for (const ev of evs) if ((await vault.outbox.event(ev)).ok) stored++
  return stored
}

export async function readOwn(vault, pubkey, kinds, limit = 100) {
  const evs = await vault.outbox.query({ kinds, authors: [pubkey], limit })
  return evs.sort((a, b) => b.created_at - a.created_at)
}

/**
 * What the signer sent back must be the event asked for, validly signed by the signed-in account. Haven doesn't
 * check the author on its own: the outbox connection is authed with the whitelisted device key, so an event from
 * another key (an extension switched to another account mid-session) would be stored and published as this one's.
 */
export function checkSigned(event, template, pubkey) {
  if (event?.pubkey !== pubkey) throw new Error("Your signer signed with a different account than the one signed in here. Switch it back, or sign out and sign in again.")
  if (event.kind !== template.kind || event.content !== template.content || event.created_at !== template.created_at || JSON.stringify(event.tags) !== JSON.stringify(template.tags))
    throw new Error("Your signer changed the note before signing it, so it wasn't posted.")
  // A fresh copy: verifyEvent trusts a "verified" flag a signed event object carries, and that flag survives a spread.
  const { id, created_at, kind, tags, content, sig } = event
  const copy = { id, pubkey, created_at, kind, tags, content, sig }
  if (!verifyEvent(copy)) throw new Error("Your signer sent back a note with a bad signature, so it wasn't posted.")
  return copy
}

/**
 * Sign, store in Haven's outbox, then send to the relays publishRelays picks. `tags`: a reply's or quote's (actions.js).
 * -> { event, local, relays: [{url, ok, message, local}] } with `local` set on this machine's own relay
 */
export async function publishNote(vault, signer, pubkey, content, writeRelays, tags = []) {
  const template = { kind: 1, created_at: now(), tags, content }
  const event = checkSigned(await signer.signEvent(template), template, pubkey)
  const local = await vault.outbox.event(event)
  if (!local.ok) throw new Error(`Haven refused the note: ${local.message}`)
  const { network, local: own } = publishRelays(writeRelays)
  const urls = [...network, ...own]
  const results = await Promise.allSettled(pool.publish(urls, event))
  return { event, local, relays: results.map((r, i) => ({ url: urls[i], ok: r.status === "fulfilled", message: r.status === "fulfilled" ? r.value : String(r.reason?.message ?? r.reason), local: i >= network.length })) }
}
