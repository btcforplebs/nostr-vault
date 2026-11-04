// Moving in also brings back the user's older list versions (Logen 2026-11-04, a Lazarus follow-up): when the vault
// imports the user's notes (Vault Dashboard › Import notes), the relays are also asked for every version of the
// user's lists they still hold, and each one the vault doesn't have yet is filed in its list history (Haven /lists,
// haven-go fileImportedVersion), where Settings › Recover a List finds it.
//
// Store only: nothing here signs or publishes, and nothing reaches the outbox, so an old version never becomes the
// current list. The scan follows the Lazarus spec (dmnyc/lazarus SPEC.md 0.6.2-draft, Scan): the user's own relays
// (read and write), the defaults, and an archival set that keeps full replaceable history; one request per kind per
// relay with a per-relay timeout; every event's signature, author and kind checked before it counts or moves a paging
// cursor; a full page asks again with `until` at the oldest one it returned; deduplicated by id. Each relay's outcome
// is kept: only an EOSE counts as an answer. No relay is answered AUTH (the pool has no auth handler), so the history
// relays aren't told the account itself is asking. The whole list search is the user's choice, off by default
// (Logen 2026-11-04: the history relays see the IP that asks and add about a minute; 09:42Z: unticked, the user's own
// relays aren't asked for older versions either, the rule the apps keep). The scan can be skipped while it runs:
// what was found so far is kept and filed.
import { askRelay } from "./follows.js"
import { ownVersion, byNewest, keptVersions } from "./list-versions.js"
import { MERGE_KINDS } from "./list-version-merge.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "./pool.js"
import { storeEvent } from "./backup.js"

/** Relays observed keeping full replaceable history (Lazarus spec, informative). Configuration, not protocol. */
export const HISTORY_RELAYS = ["wss://hist.nostr.land", "wss://relay.ditto.pub"]
/** The lists asked for: every kind Recover a List handles, and the relay list. */
export const HISTORY_KINDS = [...MERGE_KINDS.map(k => k.kind), 10002]
/** Per request (Lazarus: at least 50), pages per relay and kind, and the per-relay timeout (Lazarus reference). */
export const PAGE = 100
export const MAX_PAGES = 5
export const ASK_MS = 6000

const now = () => Math.floor(Date.now() / 1000)

/** The relays a scan asks: the user's own (read and write) and the defaults, each once, plus the archival set only
 *  when the user ticked it (`history`). */
export const scanRelays = (account, { history = false } = {}) =>
  uniq([...(account?.relays?.read ?? []), ...(account?.relays?.write ?? []), ...DEFAULT_RELAYS, ...PROFILE_RELAYS, ...(history ? HISTORY_RELAYS : [])])

/** `p`, or an empty not-answered reply as soon as `signal` aborts (a Skip doesn't wait on a slow relay). */
const orSkip = (p, signal) => !signal ? p : signal.aborted ? Promise.resolve(SKIPPED) : new Promise(resolve => {
  const stop = () => resolve(SKIPPED)
  signal.addEventListener("abort", stop, { once: true })
  p.then(r => { signal.removeEventListener("abort", stop); resolve(r) }, () => { signal.removeEventListener("abort", stop); resolve({ events: [], answered: false }) })
})
const SKIPPED = { events: [], answered: false, skipped: true }

/**
 * Every valid version of each of `kinds` the relays hold for `pubkey`. -> { versions: [event] (newest first, each
 * once), outcomes: Map(url -> "answered" | "failed" | "skipped"), skipped }. A relay counts as answered when it sent
 * EOSE for at least one request; one that never did failed. `signal` (an AbortSignal, the Skip button) ends the scan
 * at once with what it found so far. `ask(url, filter, ms)`: follows.js askRelay, for tests.
 */
export async function scanListHistory({ pubkey, relays, kinds = HISTORY_KINDS, ask = askRelay, at = now(), onProgress = () => {}, signal }) {
  const byId = new Map()
  const outcomes = new Map()
  let done = 0
  const total = relays.length * kinds.length
  await Promise.all(relays.map(async url => {
    let answered = false
    for (const kind of kinds) {
      if (signal?.aborted) break
      let until
      for (let page = 0; page < MAX_PAGES; page++) {
        const filter = { kinds: [kind], authors: [pubkey], limit: PAGE, ...(until !== undefined ? { until } : {}) }
        const r = await orSkip(ask(url, filter, ASK_MS).catch(() => ({ events: [], answered: false })), signal)
        if (r.skipped || !r.answered) break
        answered = true
        // Relays are untrusted: only the account's own, validly signed copies of this kind count.
        const valid = (r.events ?? []).filter(ev => ownVersion(ev, pubkey, kind, at))
        for (const ev of valid) if (!byId.has(ev.id)) byId.set(ev.id, ev)
        if ((r.events?.length ?? 0) < PAGE || !valid.length) break
        const oldest = valid.reduce((m, ev) => Math.min(m, ev.created_at), Infinity)
        if (until !== undefined && oldest >= until) break // nothing older: exhausted
        until = oldest // inclusive, so the next page repeats it; the id map drops the repeat
      }
      if (!signal?.aborted) onProgress({ done: ++done, total, found: byId.size })
    }
    outcomes.set(url, answered ? "answered" : signal?.aborted ? "skipped" : "failed")
  }))
  return { versions: [...byId.values()].sort(byNewest), outcomes, skipped: !!signal?.aborted }
}

/** Nothing was looked for: the box under Import notes was unticked. */
export const LIST_SEARCH_OFF = Object.freeze({ found: 0, byKind: {}, answered: 0, asked: 0, refused: 0, skipped: false, off: true })

/**
 * Scan the relays and file every version the vault doesn't hold yet in its list history. The vault's own copies
 * (the outbox's current lists and the history it kept) aren't counted or sent again. `history`: the user's tick.
 * Unticked, nothing is asked anywhere, the user's own relays included (LIST_SEARCH_OFF); ticked, the own relays, the
 * defaults and the archival set. `signal`: Skip; what was found by then is still filed. -> { found (versions filed
 * now), byKind: { kind: n }, answered, asked, refused, skipped }. `ask`, `relays`: for tests.
 */
export async function importListHistory(ctx, { history = false, relays = scanRelays(ctx.account, { history }), kinds = HISTORY_KINDS, ask = askRelay, onProgress, signal } = {}) {
  if (!history) return LIST_SEARCH_OFF
  const me = ctx.session.pubkey
  const filter = { kinds, authors: [me] }
  // This read also AUTHs the /lists connection, which a write needs.
  const [kept, current] = await Promise.all([
    keptVersions(ctx.vault.lists, filter).catch(() => []),
    ctx.vault.outbox.query(filter).catch(() => []),
  ])
  const have = new Set([...kept, ...current].map(ev => ev.id))
  const { versions, outcomes, skipped } = await scanListHistory({ pubkey: me, relays, kinds, ask, onProgress, signal })
  const store = storeEvent(ctx.vault.lists)
  const byKind = {}
  let found = 0, refused = 0
  // Oldest first is no better than newest first: Haven trims the list once, at its next version (fileImportedVersion).
  for (const ev of versions) {
    if (have.has(ev.id)) continue
    const r = await store(ev)
    if (r.ok) { found++; byKind[ev.kind] = (byKind[ev.kind] ?? 0) + 1 }
    else if (!/^duplicate:/.test(r.message ?? "")) refused++
  }
  const answered = [...outcomes.values()].filter(o => o === "answered").length
  return { found, byKind, answered, asked: relays.length, refused, skipped }
}

/** The line Import notes ends with: a plain count. */
export function historyLine({ found, answered, skipped = false, off = false }) {
  if (off) return ""
  if (skipped) return found ? `Skipped the rest of the search: kept ${found.toLocaleString()} older ${found === 1 ? "version" : "versions"} of your lists found so far. See them in Settings › Recover a List.`
    : "Skipped looking for older versions of your lists."
  if (!answered) return "Couldn't reach the relays to look for older versions of your lists."
  if (!found) return "No older versions of your lists found."
  return `Found ${found.toLocaleString()} older ${found === 1 ? "version" : "versions"} of your lists. See them in Settings › Recover a List.`
}
