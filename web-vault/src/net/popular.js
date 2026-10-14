// The Popular feed, as the iPhone ranks it (haven-go dvm.go + popular_tally.go): a day of likes, reposts and zaps,
// counted only from people the user's web of trust knows, one vote per person per note at the strongest thing they
// did, three distinct people before a note shows, an age decay after 12 hours and at most three notes per author.
// The iPhone's trust graph is the relay's; here it's the user's follows and the people they follow. Everything here
// is strangers' data and stays in memory: nothing is written to Haven /feed.
import { verifyEvent } from "nostr-tools/pure"
import { pool, PROFILE_RELAYS, uniq } from "./pool.js"

export const WINDOW = 24 * 3600 // seconds of engagement asked for
export const MIN_REACTORS = 3 // distinct trusted people, not counting the author (dvm.go minTrustedReactors)
export const PER_AUTHOR = 3 // dvm.go maxNotesPerAuthor
export const TOP = 100 // notes whose bodies are fetched and scored

/** Like 1, repost 2, zap 3 (popular_tally.go engagementWeight); anything else doesn't count. */
export const engagementWeight = kind => ({ 7: 1, 6: 2, 9735: 3 })[kind] ?? 0

/** The note an engagement is about: the last `e` tag (NIP-25), as dvm.go reactionTargetID. */
export function targetOf(ev) {
  let id = ""
  for (const t of ev.tags ?? []) if (t[0] === "e" && /^[0-9a-f]{64}$/.test(t[1] ?? "")) id = t[1]
  return id
}

/** Who did it. A zap receipt (9735) is signed by the payee's wallet, so the zapper is the signed zap request in its
 *  `description` tag; a receipt without a valid one counts for nobody. */
export function reactorOf(ev, verify = verifyEvent) {
  if (ev.kind !== 9735) return ev.pubkey
  try {
    const req = JSON.parse(ev.tags.find(t => t[0] === "description")?.[1] ?? "")
    return req?.kind === 9734 && verify(req) ? req.pubkey : ""
  } catch { return "" }
}

/** note id -> Map(reactor -> weight), only trusted reactors, each at the strongest thing they did. */
export function tally(events, trusted, verify = verifyEvent) {
  const out = new Map()
  for (const ev of events) {
    const w = engagementWeight(ev?.kind), target = w && targetOf(ev)
    if (!target) continue
    const who = reactorOf(ev, verify)
    if (!who || !trusted.has(who)) continue
    const reactors = out.get(target) ?? new Map()
    if (w > (reactors.get(who) ?? 0)) reactors.set(who, w)
    out.set(target, reactors)
  }
  return out
}

/** The ids worth fetching: at least `floor` reactors, highest summed weight first, ties by id (dvm.go rankTargets). */
export function rankTargets(t, floor = MIN_REACTORS, top = TOP) {
  const ranked = []
  for (const [id, reactors] of t) {
    if (reactors.size < floor) continue
    let score = 0
    for (const w of reactors.values()) score += w
    ranked.push({ id, score })
  }
  return ranked.sort((a, b) => b.score - a.score || (a.id < b.id ? -1 : 1)).slice(0, top).map(r => r.id)
}

/** Scored notes, best first: the author's own engagement left out (and the floor checked again without it), the
 *  score decayed 5% an hour after 12 hours down to a fifth, then at most PER_AUTHOR per author (dvm.go scoreNotes). */
export function scoreNotes(notes, t, { floor = MIN_REACTORS, now = Math.floor(Date.now() / 1000) } = {}) {
  const seen = new Set(), scored = []
  for (const n of notes) {
    if (seen.has(n.id)) continue
    seen.add(n.id)
    let raw = 0, distinct = 0
    for (const [pk, w] of t.get(n.id) ?? []) if (pk !== n.pubkey) { raw += w; distinct++ }
    if (distinct < floor) continue
    const ageHours = (now - n.created_at) / 3600
    const decay = Math.max(0.2, 1 - Math.max(0, ageHours - 12) * 0.05)
    scored.push({ note: n, score: raw * decay })
  }
  scored.sort((a, b) => b.score - a.score || (a.note.id < b.note.id ? -1 : 1))
  const perAuthor = new Map()
  return scored.filter(({ note }) => {
    const c = perAuthor.get(note.pubkey) ?? 0
    perAuthor.set(note.pubkey, c + 1)
    return c < PER_AUTHOR
  }).map(s => s.note)
}

// The trust set is a few hundred contact lists: built once per follow list this session, memory only.
let trustCache = { key: "", set: null }

/** The user, their follows and the people their follows follow. `query` is for tests. */
export async function trustSet(me, follows, relays, { query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const key = `${me}:${follows.length}:${follows[0] ?? ""}:${follows.at(-1) ?? ""}`
  if (trustCache.key === key) return trustCache.set
  const set = new Set([me, ...follows].filter(Boolean))
  const newest = new Map()
  for (let i = 0; i < follows.length; i += 250) {
    const chunk = follows.slice(i, i + 250)
    const evs = await query(uniq([...relays, ...PROFILE_RELAYS]), { kinds: [3], authors: chunk, limit: chunk.length }, { maxWait: 8000 })
    for (const ev of evs) if (ev?.kind === 3 && chunk.includes(ev.pubkey) && !(newest.get(ev.pubkey)?.created_at >= ev.created_at)) newest.set(ev.pubkey, ev)
  }
  for (const ev of newest.values()) for (const t of ev.tags ?? []) if (t[0] === "p" && /^[0-9a-f]{64}$/.test(t[1] ?? "")) set.add(t[1])
  trustCache = { key, set }
  return set
}

/**
 * The Popular page: notes ranked from the last day's engagement on these relays. Asks once for everyone's
 * engagement (as the iPhone does) and once for the follows' own, since a busy relay's 5,000 can miss them.
 * -> { notes, trusted } (trusted: how many people count, so the screen can say why it's empty). `query` is for tests.
 */
export async function fetchPopular({ me, follows, relays, vault, now = Math.floor(Date.now() / 1000), query = (r, f, o) => pool.querySync(r, f, o) }) {
  const trusted = await trustSet(me, follows, relays, { query })
  const urls = uniq(relays)
  const since = now - WINDOW, kinds = [7, 6, 9735]
  const asks = [query(urls, { kinds, since, limit: 5000 }, { maxWait: 10000 })]
  for (let i = 0; i < follows.length; i += 250) asks.push(query(urls, { kinds: [7, 6], authors: follows.slice(i, i + 250), since, limit: 2000 }, { maxWait: 10000 }))
  const byId = new Map()
  for (const evs of await Promise.all(asks)) for (const ev of evs) if (ev?.id) byId.set(ev.id, ev)
  const t = tally(byId.values(), trusted)
  const ids = rankTargets(t)
  if (!ids.length) return { notes: [], trusted: trusted.size }
  // Bodies: Haven /feed first (read only), the relays for the rest.
  const found = new Map()
  if (vault) for (const ev of await vault.feed.query({ ids, kinds: [1] }).catch(() => [])) found.set(ev.id, ev)
  const missing = ids.filter(id => !found.has(id))
  if (missing.length) for (const ev of await query(urls, { ids: missing, kinds: [1] }, { maxWait: 8000 })) if (ev?.kind === 1 && missing.includes(ev.id)) found.set(ev.id, ev)
  return { notes: scoreNotes([...found.values()], t, { now }), trusted: trusted.size }
}
