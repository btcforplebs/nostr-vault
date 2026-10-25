// Network -> in-page Haven. Every event that comes in is written to Haven (the user's own events to the
// outbox route, follows' notes to /feed); the screens read only from Haven.
import { verifyEvent } from "nostr-tools/pure"
import { normalizeURL } from "nostr-tools/utils"
import { pool, publishRelays, relayLists, uniq } from "./pool.js"

// Notes and reposts, plus the articles, polls, highlights, comments, pictures and generic reposts the iPhone shows in
// Following (FeedServiceTypes.timelineKinds). feed-kinds.js timelineShows decides which comments and kind 16s draw.
export const FEED_KINDS = [1, 6, 30023, 1068, 9802, 1111, 16, 20]
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

const norm = url => { try { return normalizeURL(url) } catch { return url } }
const accountQuery = (relays, pubkey) => pool.querySync(relays, { kinds: [0, 3, 10002], authors: [pubkey] }, { maxWait: 6000 })

/**
 * The account's kind 0, 3 and 10002 from `relays`, asked before Haven is up: boot starts this while haven.wasm
 * downloads, so the relays are connected and the answer is in hand when Haven starts. Hand it to refreshAccount.
 */
export function fetchAccount(pubkey, relays) {
  const events = accountQuery(relays, pubkey).catch(() => [])
  // The feed asks the account's read relays next: open them now as well.
  events.then(evs => { for (const url of account(evs).relays.read) pool.ensureRelay(url, { connectionTimeout: 5000 }).catch(() => {}) })
  return { relays, events }
}

/**
 * Fetch the account's replaceable events from the network into Haven, then read it back from Haven. `early`, a
 * fetchAccount already under way, counts as asking its relays: only the hint relays it didn't ask are asked now.
 */
export async function refreshAccount(vault, pubkey, hintRelays, { log = () => {}, early } = {}) {
  const asked = new Set(early?.relays.map(norm))
  const rest = hintRelays.filter(u => !asked.has(norm(u)))
  const evs = (await Promise.all([early?.events ?? [], rest.length ? accountQuery(rest, pubkey) : []])).flat()
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

/**
 * Pull follows' notes since the newest one cached (or the last two days) into Haven /feed. `onFirstPage` runs once
 * the first group of follows is stored, before the rest are asked. -> notes stored
 */
export async function syncFeed(vault, follows, relays, { onProgress = () => {}, onFirstPage = () => {} } = {}) {
  if (!follows.length) return 0
  // querySync treats a relay it can't reach as an empty answer, so check that at least one relay is up first. The
  // first one up is enough: the rest join the query as they connect, rather than the slowest connect (up to 5 s for
  // a host that never answers) holding back every relay's notes.
  await Promise.any(relays.map(url => pool.ensureRelay(url, { connectionTimeout: 5000 }))).catch(() => { throw new Error("no relay reachable") })
  const top = (await readFeed(vault, follows, { limit: 1 }))[0]
  const since = top ? top.created_at - 600 : now() - 2 * 86400
  let stored = 0, done = 0
  const sent = new Set()
  const chunk = async i => {
    // Each relay's answer is stored as it lands, so the fastest relay's notes show without waiting for the slowest
    // (up to maxWait). A note two relays send is written once: Haven takes one request per id at a time.
    // A relay whose notes Haven refused doesn't stop the others; the sync fails once they have all finished.
    const filter = { kinds: FEED_KINDS, authors: follows.slice(i, i + 250), since, limit: 500 }
    const failed = (await Promise.allSettled(relays.map(async url => {
      const evs = (await pool.querySync([url], filter, { maxWait: 8000 }).catch(() => [])).filter(e => !sent.has(e.id) && sent.add(e.id))
      const n = await storeAll(vault.feed, evs)
      if (n) onProgress({ done, of: follows.length, stored: (stored += n) })
    }))).find(r => r.status === "rejected")
    if (failed) throw failed.reason
    done = Math.min(done + 250, follows.length)
    onProgress({ done, of: follows.length, stored })
  }
  // The first 250 follows alone, so the first screen isn't slowed by the rest (asking them too put the first notes
  // ~2.5 s later), then FEED_CHUNKS_AT_ONCE groups at a time, not one after another: 1,000 follows took ~43 s in turn.
  await chunk(0)
  onFirstPage()
  const starts = Array.from({ length: Math.ceil(follows.length / 250) - 1 }, (_, k) => (k + 1) * 250).values()
  const errors = await Promise.allSettled(Array.from({ length: FEED_CHUNKS_AT_ONCE }, async () => { for (const i of starts) await chunk(i) }))
  const failed = errors.find(r => r.status === "rejected")
  if (failed) throw failed.reason
  return stored
}

/** How many groups of 250 follows syncFeed asks the relays for at once: one REQ each per relay. */
export const FEED_CHUNKS_AT_ONCE = 3

/** The user's own notes and articles from their write relays into Haven's outbox route. */
export async function syncOwn(vault, pubkey, relays) {
  // Articles get their own filter: with one shared limit, a busy account's notes fill it and no article comes back.
  const [notes, articles] = await Promise.all([
    pool.querySync(relays, { kinds: [1], authors: [pubkey], limit: 300 }, { maxWait: 8000 }),
    pool.querySync(relays, { kinds: [30023], authors: [pubkey], limit: 50 }, { maxWait: 8000 }),
  ])
  return storeAll(vault.outbox, [...notes, ...articles])
}

/** The phone's Import window and default start date: haven-go/import.go importOwnerNotes, HavenConfig.importStartDate. */
export const IMPORT_WINDOW = 10 * 86400
export const IMPORT_START_DATE = "2023-01-01"
/** How many ten-day windows importOwn asks the relays for at once. */
export const IMPORT_WINDOWS_AT_ONCE = 4
const day = t => new Date(t * 1000).toISOString().slice(0, 10)

/**
 * The phone's Import: everything the account wrote (no kinds in the filter, as on the phone), from now back to
 * `startDate` (yyyy-mm-dd, UTC), ten days at a time. A relay that caps its answer (its own limit) is asked again
 * below the oldest event it sent, until it reaches the window's start, so a busy window comes back whole.
 * onProgress({ progress 0..1, from: "yyyy-mm-dd", found, stored, empty }) after each window. -> { found, stored }
 */
export async function importOwn(vault, pubkey, relays, { startDate = IMPORT_START_DATE, onProgress = () => {}, maxWait = 8000 } = {}) {
  const start = Date.parse(`${startDate}T00:00:00Z`) / 1000
  if (!Number.isFinite(start)) throw new Error(`not a date: ${startDate}`)
  await Promise.any(relays.map(url => pool.ensureRelay(url, { connectionTimeout: 5000 }))).catch(() => { throw new Error("no relay reachable") })
  const end = now()
  const windows = []
  for (let until = end; until > start; until -= IMPORT_WINDOW) windows.push({ since: Math.max(start, until - IMPORT_WINDOW), until })
  const seen = new Set()
  let found = 0, stored = 0
  // Each relay is paged on its own: paging on all the relays' answers together stopped as soon as one relay with a
  // high cap reached the window's start, and a lower-capped relay's older notes in that window were never asked for.
  const fetchWindow = async ({ since, until }) => (await Promise.all(relays.map(async url => {
    let n = 0
    for (let u = until; ;) {
      const page = await pool.querySync([url], { authors: [pubkey], since, until: u }, { maxWait }).catch(() => [])
      const evs = page.filter(e => e.pubkey === pubkey && !seen.has(e.id) && seen.add(e.id))
      n += evs.length
      found += evs.length
      const s = await storeAll(vault.outbox, evs)
      stored += s // not `stored += await`: that reads stored before the await and drops the other windows' counts
      const oldest = page.reduce((m, e) => Math.min(m, e.created_at), u)
      if (!page.length || oldest >= u || oldest <= since) break
      u = oldest
    }
    return n
  }))).reduce((a, b) => a + b, 0)
  // IMPORT_WINDOWS_AT_ONCE windows in flight (one after another took ~10 min back to 2023 for a busy account), with
  // progress reported in order, newest window first, so the date line only walks back.
  const counts = []
  let next = 0, reported = 0
  const report = () => {
    for (; reported < windows.length && counts[reported] !== undefined; reported++) {
      const { since } = windows[reported]
      onProgress({ progress: Math.min(1, (end - since) / (end - start)), from: day(since), found, stored, empty: !counts[reported] })
    }
  }
  await Promise.all(Array.from({ length: IMPORT_WINDOWS_AT_ONCE }, async () => {
    while (next < windows.length) { const i = next++; counts[i] = await fetchWindow(windows[i]); report() }
  }))
  return { found, stored }
}

/**
 * Writes events into a Haven route 100 at a time, not one round trip after another: a first sync's 500 notes took
 * ~1 s in turn. Haven takes one request per id at a time, so a note another sync (Refresh, the background tick)
 * is writing right now counts as a duplicate here. -> how many were stored
 */
export async function storeAll(route, evs) {
  let stored = 0
  for (let i = 0; i < evs.length; i += 100) {
    const rs = await Promise.all(evs.slice(i, i + 100).map(ev => route.event(ev).catch(e => {
      if (/already in flight/.test(e?.message)) return { ok: false }
      throw e
    })))
    stored += rs.filter(r => r.ok).length
  }
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
