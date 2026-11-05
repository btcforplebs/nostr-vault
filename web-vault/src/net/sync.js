// Network -> in-page Haven. Every event that comes in is written to Haven (the user's own events to the
// outbox route, follows' notes to /feed); the screens read only from Haven.
import { recordOwnList } from "./list-wipe-alarm.js"
import { verifyEvent } from "nostr-tools/pure"
import { nip77 } from "nostr-tools"
import { normalizeURL } from "nostr-tools/utils"
import { pool, publishRelays, relayLists, uniq } from "./pool.js"
import { appendClientTag } from "./client-tag.js"
import { neverConnectUrls } from "./never-connect.js"
import { withImportLock } from "./import-lock.js"

// Notes and reposts, plus the articles, polls, highlights, comments, pictures and generic reposts the iPhone shows in
// Following (FeedServiceTypes.timelineKinds). feed-kinds.js timelineShows decides which comments and kind 16s draw.
export const FEED_KINDS = [1, 6, 30023, 1068, 9802, 1111, 16, 20]
const now = () => Math.floor(Date.now() / 1000)
const newest = evs => evs.reduce((a, e) => (!a || e.created_at > a.created_at ? e : a), undefined)

// Profile, follows, relay list and Never Connect list (10006: the pool refuses those relays).
const ACCOUNT_KINDS = [0, 3, 10002, 10006]

/** The account as Haven has it: ACCOUNT_KINDS from the outbox route. Works offline. */
export async function readAccount(vault, pubkey) {
  const evs = await vault.outbox.query({ kinds: ACCOUNT_KINDS, authors: [pubkey] })
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
    neverConnect: by(10006) ? neverConnectUrls(by(10006)) : null, // null: no list here yet, keep what the pool has
  }
}

const norm = url => { try { return normalizeURL(url) } catch { return url } }
const accountQuery = (relays, pubkey) => pool.querySync(relays, { kinds: ACCOUNT_KINDS, authors: [pubkey] }, { maxWait: 6000 })

/**
 * The account's ACCOUNT_KINDS from `relays`, asked before Haven is up: boot starts this while haven.wasm
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
  // A save Haven doesn't answer (it runs on the page's thread and can be slow: "no answer to EVENT in 15000 ms") is
  // skipped and logged, not thrown: thrown, it ended the whole boot and the app stopped refreshing (Logen, 2026-11-03).
  // What wasn't saved still counts for this visit; Haven gets it on the next refresh. A refusal stays out, as before.
  const unsaved = []
  for (const k of ACCOUNT_KINDS) {
    const ev = newest(evs.filter(e => e.kind === k))
    if (!ev) continue
    let r
    try { r = await vault.outbox.event(ev) } catch (e) {
      log("account-store-failed", { kind: k, err: String(e?.message ?? e) })
      unsaved.push(ev)
      continue
    }
    if (!r.ok && !/^duplicate:/.test(r.message)) log("account-store-refused", { kind: k, message: r.message })
  }
  if (!unsaved.length) return readAccount(vault, pubkey)
  const held = await vault.outbox.query({ kinds: ACCOUNT_KINDS, authors: [pubkey] })
    .catch(e => { log("account-read-failed", { err: String(e?.message ?? e) }); return [] })
  return account([...held, ...unsaved])
}

/** The Following feed from Haven /feed, newest first. */
export async function readFeed(vault, follows, { limit = 100, until } = {}) {
  if (!follows.length) return []
  const evs = await vault.feed.query({ kinds: FEED_KINDS, authors: follows, limit, ...(until ? { until } : {}) })
  return evs.sort((a, b) => b.created_at - a.created_at)
}

/**
 * Pull follows' notes since the newest one cached (or the last two days) into Haven /feed. `onFirstPage` runs once
 * the first group of follows is stored, before the rest are asked. `tally` counts { failed: stores Haven didn't
 * answer, capped: relay pages cut at FEED_MAX_PAGES }. -> notes stored
 */
export async function syncFeed(vault, follows, relays, { onProgress = () => {}, onFirstPage = () => {}, tally = { failed: 0, capped: 0 },
  query = (r, f, o) => pool.querySync(r, f, o), reach = urls => Promise.any(urls.map(url => pool.ensureRelay(url, { connectionTimeout: 5000 }))) } = {}) {
  if (!follows.length) return 0
  tally.failed ??= 0; tally.capped ??= 0
  // querySync treats a relay it can't reach as an empty answer, so check that at least one relay is up first. The
  // first one up is enough: the rest join the query as they connect, rather than the slowest connect (up to 5 s for
  // a host that never answers) holding back every relay's notes.
  await reach(relays).catch(() => { throw new Error("no relay reachable") })
  const top = (await readFeed(vault, follows, { limit: 1 }))[0]
  const since = top ? top.created_at - 600 : now() - 2 * 86400
  let stored = 0, done = 0
  const sent = new Set()
  const chunk = async i => {
    // Each relay's answer is stored as it lands, so the fastest relay's notes show without waiting for the slowest
    // (up to maxWait). A note two relays send is written once: Haven takes one request per id at a time.
    // A relay whose notes Haven refused doesn't stop the others; the sync fails once they have all finished.
    // A relay that sends a full page has more: it is paged back (until = the page's oldest) until a page comes back
    // short, so a busy group of follows isn't cut at 500 with the rest never asked again (the next sync starts from the
    // newest cached note; Tidy 8). FEED_MAX_PAGES is the backstop.
    const filter = { kinds: FEED_KINDS, authors: follows.slice(i, i + 250), since, limit: FEED_PAGE }
    await Promise.all(relays.map(async url => {
      let until
      for (let n = 0; n < FEED_MAX_PAGES; n++) {
        const page = await query([url], until === undefined ? filter : { ...filter, until }, { maxWait: 8000 }).catch(() => [])
        const evs = page.filter(e => !sent.has(e.id) && sent.add(e.id))
        // A store Haven doesn't answer is counted, not thrown: one timeout no longer fails the whole sync (Tidy 6).
        const k = await storeAll(vault.feed, evs, { tally })
        if (k) onProgress({ done, of: follows.length, stored: (stored += k) })
        if (page.length < FEED_PAGE) return
        const oldest = page.reduce((m, e) => Math.min(m, e.created_at), Infinity)
        const next = evs.length ? oldest : oldest - 1 // a page of nothing new is one second: step past it
        if (next < since || next === until) return
        until = next
      }
      tally.capped++
    }))
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
/** One page of follows' notes from one relay, and how many pages a group may take since the last sync. */
export const FEED_PAGE = 500
export const FEED_MAX_PAGES = 20

/**
 * The user's own notes and articles from their write relays into Haven's outbox route. Each relay is asked on its
 * own and its answer kept as it lands, then `on()` is called when it brought something new, so Profile draws the
 * notes from the first relay instead of after the slowest (10 s vs 1.4 s for someone else's, Ted's web sweep
 * 2026-11-01). -> how many were stored
 */
export async function syncOwn(vault, pubkey, relays, { on, query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  let stored = 0
  const ask = filter => Promise.all(uniq(relays).map(async url => {
    const evs = await query([url], filter, { maxWait: 8000 }).catch(() => [])
    const n = evs.length ? await storeAll(vault.outbox, evs) : 0
    stored += n
    if (n) await on?.()
  }))
  // Articles get their own filter: with one shared limit, a busy account's notes fill it and no article comes back.
  await Promise.all([ask({ kinds: [1], authors: [pubkey], limit: 300 }), ask({ kinds: [30023], authors: [pubkey], limit: 50 })])
  return stored
}

/** The phone's Import window and default start date: haven-go/import.go importOwnerNotes, HavenConfig.importStartDate. */
export const IMPORT_WINDOW = 10 * 86400
export const IMPORT_START_DATE = "2023-01-01"
const day = t => new Date(t * 1000).toISOString().slice(0, 10)

// Moving in's limits, the same as haven-go/import_owner.go and import_paging.go (master a572c1b0).
/** Asked for per page; a relay that caps lower sends fewer and the paging goes on from its oldest. */
export const IMPORT_PAGE_LIMIT = 500
/** A page that hears nothing (no note, no EOSE) for this long ends with what it got; each note restarts it. */
export const IMPORT_IDLE_MS = 20_000
/** The most one page may take, however it trickles. */
export const IMPORT_PAGE_MAX_MS = 2 * 60_000
/** One relay's whole-history lane: past this it is read window by window instead, where every window ends. */
export const IMPORT_LANE_DEADLINE_MS = 15 * 60_000
/** A whole-history lane's backstop (2M notes); a window's is 200. */
export const IMPORT_LANE_MAX_PAGES = 4000
export const IMPORT_WINDOW_MAX_PAGES = 200
/** How long a relay may stay silent after NEG-OPEN before it counts as not speaking NIP-77. */
export const IMPORT_NEG_OPEN_MS = 8000
/** One relay's whole negentropy session. */
export const IMPORT_NEG_TIMEOUT_MS = 3 * 60_000
/** A relay silent (nothing, no EOSE) for this many windows in a row is dropped. */
export const IMPORT_SILENT_WINDOWS = 3
/** A relay found not to speak NIP-77 isn't asked again for a day (haven-go negCapRetryTTL). */
const NEG_RETRY_MS = 24 * 3600_000
const negUnsupported = new Map() // normalized url -> ms when it said no

/**
 * One page from one relay: what it sent, and whether it ended with EOSE (false: it went quiet, closed or failed).
 * Ends at EOSE, CLOSED, a full page, IMPORT_PAGE_MAX_MS, or idleMs without a note.
 */
async function askPage(url, filter, idleMs = IMPORT_IDLE_MS) {
  let relay
  try { relay = await pool.ensureRelay(url, { connectionTimeout: 5000 }) } catch { return { events: [], eose: false } }
  return new Promise(resolve => {
    const events = []
    let sub, done = false, idle
    const finish = eose => {
      if (done) return
      done = true
      clearTimeout(idle); clearTimeout(max)
      try { sub?.close() } catch {}
      resolve({ events, eose })
    }
    const restart = () => { clearTimeout(idle); idle = setTimeout(() => finish(false), idleMs) }
    const max = setTimeout(() => finish(false), IMPORT_PAGE_MAX_MS)
    restart()
    try {
      sub = relay.subscribe([filter], {
        onevent: e => { events.push(e); if (filter.limit && events.length >= filter.limit) finish(true); else restart() },
        oneose: () => finish(true),
        onclose: () => finish(false),
        eoseTimeout: IMPORT_PAGE_MAX_MS,
      })
    } catch { finish(false) }
  })
}

const UNSUPPORTED_NOTICE = /negentropy|NEG-OPEN|could not parse|unknown message|bad msg/i

/**
 * NIP-77 against one relay, download only: the ids it holds for `filter` that `have` (the vault's {id, created_at}
 * for the same filter) lacks. Throws { unsupported } when it says it doesn't speak NIP-77 (with `silent` when it
 * just didn't answer in time), { refused } on NEG-ERR.
 */
async function negentropyNeeds(url, filter, have, { openMs = IMPORT_NEG_OPEN_MS, timeoutMs = IMPORT_NEG_TIMEOUT_MS } = {}) {
  const relay = await pool.ensureRelay(url, { connectionTimeout: 5000 })
  const storage = new nip77.NegentropyStorageVector()
  for (const e of have) storage.insert(e.created_at, e.id)
  storage.seal()
  return new Promise((resolve, reject) => {
    const need = new Set()
    let answered = false, refused = false, ended = false, sync
    const prevNotice = relay.onnotice
    const end = (err, closed) => {
      if (ended) return
      ended = true
      clearTimeout(openT); clearTimeout(allT)
      relay.onnotice = prevNotice
      if (!closed) try { sync?.close() } catch {}
      if (err) reject(err); else resolve([...need])
    }
    relay.onnotice = msg => {
      if (!answered && UNSUPPORTED_NOTICE.test(msg)) end(Object.assign(new Error(`no NIP-77: ${msg}`), { unsupported: true }))
      prevNotice?.(msg)
    }
    const openT = setTimeout(() => { if (!answered) end(Object.assign(new Error("no NIP-77 answer"), { unsupported: true, silent: true })) }, openMs)
    const allT = setTimeout(() => end(new Error("negentropy timed out")), timeoutMs)
    try {
      sync = new nip77.NegentropySync(relay, storage, filter, {
        onneed: id => need.add(id),
        onclose: reason => end(refused || reason ? Object.assign(new Error(`negentropy refused: ${reason ?? "NEG-ERR"}`), { refused: true }) : null, true),
      })
      const custom = sync.subscription.oncustom
      sync.subscription.oncustom = data => { answered = true; if (data[0] === "NEG-ERR") refused = true; custom(data) }
      sync.start().catch(e => end(e))
    } catch (e) { end(e) }
  })
}

/** The network seams, replaced in tests: one page from one relay, and a NIP-77 session's needed ids. */
export const importNet = { page: askPage, negentropy: negentropyNeeds }

/**
 * The phone's Import (haven-go/import_owner.go, master a572c1b0): everything the account wrote since `startDate`
 * (yyyy-mm-dd, UTC), no kinds in the filter. Each relay on its own, all at once, one request in flight each:
 *  1. a relay that speaks NIP-77 hands over every id the vault lacks in one negentropy session; those notes are
 *     fetched by id, asked for again once if any don't come, and the relay is paged as in 2 if any still lack;
 *  2. every other relay pages its whole history newest first (no ten-day windows);
 *  3. a lane that stops partway, never answers, or runs past IMPORT_LANE_DEADLINE_MS is read the old way, ten days
 *     at a time, and dropped after IMPORT_SILENT_WINDOWS silent windows.
 * Then the notes that tag the account (replies, reactions, zaps to you) into the inbox, paged the same way per relay
 * (haven-go importTaggedNotes; Tidy 3). Messages (kinds 4, 13, 14, 1059) are left to the chat sync.
 * Download only: nothing is sent to a relay but requests. A note counts only once its id is the hash of its content
 * and its signature holds (and, for the owner lane, the account wrote it); stores run one batch at a time across every
 * relay, deletions after the rest of their batch, so a note and its deletion can't both get through Haven's check. A
 * note counts as had only once Haven has answered for it (Tidy 5), and a write Haven doesn't answer is counted, not
 * thrown (Tidy 6). Holds the import lock (import-lock.js): a second import in any tab is refused at once.
 * onProgress({ progress 0..1, from: "yyyy-mm-dd", found, stored, empty, tagged }).
 * -> { found, stored, failed, cut: relays that didn't finish, tagged: { found, stored }, result }, where result is
 *    "complete" (every relay finished and every write landed), "partial" or "failed" (nothing came in), as the apps.
 */
export function importOwn(vault, pubkey, relays, opts = {}) {
  return withImportLock(() => importOwnUnlocked(vault, pubkey, relays, opts))
}

/** The outcome the apps show: every relay finished and every write landed, or some of it, or nothing. */
export function importResult({ relays, cut, failed, stored, found }) {
  if (!cut.length && !failed) return "complete"
  if (cut.length < relays || stored > 0 || found > 0) return "partial"
  return "failed"
}

/** The line Settings and the Dashboard show when an import ends, complete / partial / failed as the apps. */
export function importLine({ result, found, stored, failed = 0, cut = [], tagged }) {
  const counts = `${found} found, ${stored} new` + (tagged?.found ? `, ${tagged.stored} new that tag you` : "")
  if (result === "complete") return `Import Complete! ${counts}.`
  if (result === "partial") {
    const why = [cut.length && `${cut.length} relay${cut.length === 1 ? "" : "s"} didn't finish`, failed && `${failed} couldn't be saved here`].filter(Boolean).join("; ")
    return `Import partly done: ${counts}${why ? `. ${why}` : ""}. Run it again to fill the gaps.`
  }
  return "Import failed: nothing came in from your relays. Check your connection and run it again."
}

const DM_KINDS = new Set([4, 13, 14, 1059, 1060])

async function importOwnUnlocked(vault, pubkey, relays, { startDate = IMPORT_START_DATE, onProgress = () => {}, maxWait = IMPORT_IDLE_MS,
  laneDeadlineMs = IMPORT_LANE_DEADLINE_MS } = {}) {
  const start = Date.parse(`${startDate}T00:00:00Z`) / 1000
  if (!Number.isFinite(start)) throw new Error(`not a date: ${startDate}`)
  await Promise.any(relays.map(url => pool.ensureRelay(url, { connectionTimeout: 5000 }))).catch(() => { throw new Error("no relay reachable") })
  const end = now()
  const tally = { failed: 0 }
  const cut = new Set()
  const tagged = { found: 0, stored: 0 }
  let found = 0, stored = 0

  const verified = e => { const { id, pubkey: pk, created_at, kind, tags, content, sig } = e; return verifyEvent({ id, pubkey: pk, created_at, kind, tags, content, sig }) }
  const inRange = (e, since, until) => e && e.created_at >= since && (until === undefined || e.created_at <= until)
  const real = (e, since, until) => inRange(e, since, until) && e.pubkey === pubkey && verified(e)
  const tagsMe = (e, since, until) => inRange(e, since, until) && e.pubkey !== pubkey && !DM_KINDS.has(e.kind)
    && (e.tags ?? []).some(t => t?.[0] === "p" && t[1] === pubkey) && verified(e)

  // Per destination: what Haven holds (stored or duplicate), what is being written now, and every id ever seen (found).
  const sink = (route, count) => {
    const had = new Set(), writing = new Set(), sighted = new Set()
    const again = new Map() // id -> a copy another relay sent while the first was being written
    let storing = Promise.resolve()
    const keepNow = evs => {
      for (const e of evs) if (!sighted.has(e.id)) { sighted.add(e.id); count.found++ }
      // A copy is written only if no other copy is held or in flight. One that failed (a timeout) isn't in `had`, so
      // the next relay's copy is written (Tidy 5), and a copy that came while it was in flight gets one more try.
      for (const e of evs) if (writing.has(e.id) && !had.has(e.id)) again.set(e.id, e)
      const fresh = evs.filter(e => !had.has(e.id) && !writing.has(e.id) && writing.add(e.id))
      if (!fresh.length) return storing
      const saved = e => { had.add(e.id); again.delete(e.id) }
      const run = storing.then(async () => {
        count.stored += await storeAll(route, fresh.filter(e => e.kind !== 5), { tally, onSaved: saved })
        count.stored += await storeAll(route, fresh.filter(e => e.kind === 5), { tally, onSaved: saved })
      }).finally(() => {
        for (const e of fresh) writing.delete(e.id)
        const retry = fresh.map(e => again.get(e.id)).filter(Boolean)
        for (const e of retry) again.delete(e.id)
        if (retry.length) keepNow(retry)
      })
      storing = run.catch(() => {})
      return run
    }
    // Waits for every write, including a retry queued by the last one.
    keepNow.drain = async () => { for (let s; s !== storing;) { s = storing; await s } }
    return keepNow
  }
  const own = { get found() { return found }, set found(v) { found = v }, get stored() { return stored }, set stored(v) { stored = v } }
  const keep = sink(vault.outbox, own)
  const keepTagged = sink(vault.inbox ?? vault.outbox, tagged)

  // Progress: each relay's share of the history covered (1 when it's done), averaged; `from` the oldest day reached.
  const covered = new Map(relays.map(url => [url, 0]))
  let oldestDay = end
  const report = (url, reached) => {
    if (reached !== undefined) {
      covered.set(url, Math.max(covered.get(url), Math.min(1, (end - Math.max(reached, start)) / Math.max(1, end - start))))
      if (reached < oldestDay) oldestDay = Math.max(reached, start)
    }
    const progress = [...covered.values()].reduce((a, b) => a + b, 0) / Math.max(1, covered.size)
    onProgress({ progress, from: day(oldestDay), found, stored, empty: false, tagged: tagged.found })
  }

  // One relay paged from `until` (or now) back to `since`. -> "done" | "short" | "silent" | "overran"
  const page = async (url, since, until, maxPages, deadline, { base = { authors: [pubkey] }, check = real, put = keep, onPage = report } = {}) => {
    let f = { ...base, since, limit: IMPORT_PAGE_LIMIT }
    if (until !== undefined) f.until = until
    const mine = new Set()
    let stepped = false
    for (let n = 0; ; n++) {
      if (deadline && Date.now() > deadline) return "overran"
      if (n === maxPages) return "short"
      const { events, eose } = await importNet.page(url, f, maxWait)
      // Checked before a note can count as new, or made-up notes keep a lane paging (Tron, PR 1663).
      const ok = events.filter(e => check(e, since, f.until))
      if (!ok.length) return eose ? "done" : n > 0 ? "short" : "silent"
      const oldest = ok.reduce((m, e) => Math.min(m, e.created_at), Infinity)
      const fresh = ok.filter(e => !mine.has(e.id) && mine.add(e.id))
      await put(fresh)
      onPage(url, oldest)
      let u = oldest // inclusive: notes sharing that second come back and are skipped
      if (!fresh.length) {
        if (stepped) return "done"
        stepped = true
        u = oldest - 1
      } else stepped = false
      if (u < since) return "done"
      f = { ...f, until: u }
    }
  }

  // The vault's own copy of the history, for the negentropy vector: paged, as Haven caps a query.
  const vaultHave = async () => {
    const have = new Map()
    let until
    for (;;) {
      const evs = await vault.outbox.query({ authors: [pubkey], since: start, ...(until !== undefined && { until }), limit: 5000 }).catch(() => [])
      const fresh = evs.filter(e => !have.has(e.id))
      for (const e of fresh) have.set(e.id, { id: e.id, created_at: e.created_at })
      if (!fresh.length) break
      until = evs.reduce((m, e) => Math.min(m, e.created_at), Infinity)
    }
    return [...have.values()]
  }
  let haveOnce
  const have = () => (haveOnce ??= vaultHave())

  // Fetch exactly `ids` from one relay; -> the ids it didn't hand over (or that failed the check).
  const byId = async (url, ids) => {
    const left = []
    for (let i = 0; i < ids.length; i += IMPORT_PAGE_LIMIT) {
      const batch = ids.slice(i, i + IMPORT_PAGE_LIMIT)
      const want = new Set(batch)
      const { events } = await importNet.page(url, { ids: batch, limit: batch.length }, maxWait)
      const ok = events.filter(e => want.has(e.id) && real(e, start))
      const got = new Set(ok.map(e => e.id))
      await keep(ok)
      left.push(...batch.filter(id => !got.has(id)))
    }
    return left
  }

  // NIP-77 for one relay, if it may speak it. -> true when every id it listed is now in hand.
  const negentropy = async url => {
    const key = norm(url)
    if (Date.now() - (negUnsupported.get(key) ?? -Infinity) < NEG_RETRY_MS) return false
    let need
    try {
      need = await importNet.negentropy(url, { authors: [pubkey], since: start }, await have())
    } catch (e) {
      // Only a relay that said no is skipped for a day. A silent one may just have been slow to answer while the
      // page was busy checking another relay's notes (relay.nos.social, live), so it's asked again next time.
      if (e?.refused || (e?.unsupported && !e.silent)) negUnsupported.set(key, Date.now())
      return false
    }
    let left = await byId(url, need)
    if (left.length) left = await byId(url, left) // asked once more, as the apps do
    if (left.length) return false
    report(url, start)
    return true
  }

  const redo = []
  await Promise.all(relays.map(async url => {
    if (await negentropy(url)) return
    const how = await page(url, start, undefined, IMPORT_LANE_MAX_PAGES, Date.now() + laneDeadlineMs)
    if (how === "done") report(url, start)
    else redo.push(url)
  }))

  // The old walk, ten days at a time, for the lanes that didn't finish. A relay finishes only if every window it was
  // asked for ended on its own; a dropped one, or a window cut short, leaves it in `cut` (the import is partial).
  if (redo.length) {
    const silent = new Map(redo.map(url => [url, 0]))
    let left = [...redo]
    for (let until = end; until > start && left.length; until -= IMPORT_WINDOW) {
      const since = Math.max(start, until - IMPORT_WINDOW)
      const hows = await Promise.all(left.map(url => page(url, since, until, IMPORT_WINDOW_MAX_PAGES)))
      left.forEach((url, i) => {
        silent.set(url, hows[i] === "silent" ? silent.get(url) + 1 : 0)
        if (hows[i] !== "done") cut.add(url)
      })
      left = left.filter(url => silent.get(url) < IMPORT_SILENT_WINDOWS)
    }
    for (const url of redo) report(url, start)
  }

  // Notes that tag you, every relay at once, paged back to the start date (a lane that doesn't finish leaves it cut).
  await Promise.all(relays.map(async url => {
    const how = await page(url, start, undefined, IMPORT_LANE_MAX_PAGES, Date.now() + laneDeadlineMs,
      { base: { "#p": [pubkey] }, check: tagsMe, put: keepTagged, onPage: () => report() })
    if (how !== "done" && how !== "silent") cut.add(url)
  }))
  await keep.drain()
  await keepTagged.drain()
  const out = { found, stored, failed: tally.failed, cut: [...cut], tagged: { ...tagged } }
  return { ...out, result: importResult({ relays: relays.length, ...out, found: found + tagged.found, stored: stored + tagged.stored }) }
}

/**
 * Writes events into a Haven route 100 at a time, not one round trip after another: a first sync's 500 notes took
 * ~1 s in turn. Haven takes one request per id at a time, so a note another sync (Refresh, the background tick)
 * is writing right now counts as a duplicate here. `onSaved(ev)` for each Haven now holds (stored or duplicate);
 * `tally` counts failed writes instead of throwing. -> how many were stored
 */
export async function storeAll(route, evs, { tally, onSaved } = {}) {
  let stored = 0
  for (let i = 0; i < evs.length; i += 100) {
    const rs = await Promise.all(evs.slice(i, i + 100).map(ev => route.event(ev).then(r => {
      if (r?.ok || /^duplicate:/.test(r?.message ?? "")) onSaved?.(ev)
      return r
    }, e => {
      if (/already in flight/.test(e?.message)) return { ok: false }
      // With a tally, a write Haven didn't answer (a timeout) is counted and the rest go on (Tidy 6); without one it
      // throws, as before.
      if (tally) { tally.failed = (tally.failed ?? 0) + 1; return { ok: false } }
      throw e
    })))
    stored += rs.filter(r => r?.ok).length
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
  // A list this browser signed is the owner's own edit: the wipe alarm stays quiet for it (list-wipe-alarm.js).
  recordOwnList(copy)
  return copy
}

/**
 * Sign, store in Haven's outbox, then send to the relays publishRelays picks. `tags`: a reply's or quote's (actions.js).
 * -> { event, local, relays: [{url, ok, message, local}] } with `local` set on this machine's own relay
 */
export async function publishNote(vault, signer, pubkey, content, writeRelays, tags = []) {
  return publishKind(vault, signer, pubkey, 1, content, writeRelays, tags)
}

/** A signed event no relay took, sent again as it is: it is already in Haven, so a retry neither signs a second note
 *  nor leaves two copies in the vault (bug hunt 2026-11-05 #7). -> publishKind's shape */
export async function republish(event, writeRelays) {
  const { network, local: own } = publishRelays(writeRelays)
  const urls = [...network, ...own]
  const results = await Promise.allSettled(pool.publish(urls, event))
  return { event, local: { ok: true, message: "" }, relays: results.map((r, i) => ({ url: urls[i], ok: r.status === "fulfilled", message: r.status === "fulfilled" ? r.value : String(r.reason?.message ?? r.reason), local: i >= network.length })) }
}

/** Whether `event` (signed, no relay took it) is the post `built` would make: same kind 1, content and tags (the client
 *  tag publishKind adds aside), so Post sends that one again instead of signing another. */
export function sameUnsent(event, built) {
  if (!event || event.kind !== 1 || event.content !== built.content) return false
  const tags = t => JSON.stringify((t ?? []).filter(x => x[0] !== "client"))
  return tags(event.tags) === tags(built.tags)
}

/** publishNote for any kind: an article (30023) or a poll (1068) from Compose goes out the same way. */
export async function publishKind(vault, signer, pubkey, kind, content, writeRelays, tags = []) {
  const template = { kind, created_at: now(), tags: appendClientTag(tags, kind), content }
  const event = checkSigned(await signer.signEvent(template), template, pubkey)
  const local = await vault.outbox.event(event)
  if (!local.ok) throw new Error(`Haven refused the ${kind === 1 ? "note" : "post"}: ${local.message}`)
  const { network, local: own } = publishRelays(writeRelays)
  const urls = [...network, ...own]
  const results = await Promise.allSettled(pool.publish(urls, event))
  return { event, local, relays: results.map((r, i) => ({ url: urls[i], ok: r.status === "fulfilled", message: r.status === "fulfilled" ? r.value : String(r.reason?.message ?? r.reason), local: i >= network.length })) }
}
