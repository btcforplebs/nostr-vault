// The Popular feed, as the iPhone ranks it (haven-go dvm.go + popular_tally.go): a day of likes, reposts and zaps,
// counted only from people the user's web of trust knows, one vote per person per note at the strongest thing they
// did, three distinct people before a note shows, an age decay after 12 hours and at most three notes per author.
// The iPhone's trust graph is the relay's; here it's the user's follows and the people they follow. Everything here
// is strangers' data and stays in memory: nothing is written to Haven /feed.
import { verifyEvent } from "nostr-tools/pure"
import { pool, PROFILE_RELAYS, uniq } from "./pool.js"
import { followLists } from "./wot.js"
import { zapRequest } from "./notifications.js"
import { receiptTrust } from "./zaps.js"

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

/**
 * Who did it: the author, or for a zap the signer of its zap request; a receipt without a valid one counts for
 * nobody. `counts` (who may vote) is checked before the signature, so a stranger's zap costs no verify.
 * The request must also be for this note: a real request for note A wrapped in a fresh receipt whose `e` says B
 * would otherwise credit B, which is the whole trick. `counts` runs first so it still costs no verify.
 */
export function reactorOf(ev, verify = verifyEvent, counts = () => true) {
  if (ev.kind !== 9735) return counts(ev.pubkey) ? ev.pubkey : ""
  const req = zapRequest(ev)
  const forThisNote = (req?.tags ?? []).some(t => t[0] === "e" && t[1] === targetOf(ev))
  return req && forThisNote && counts(req.pubkey) && verify(req) ? req.pubkey : ""
}

/** note id -> Map(reactor -> weight), only trusted reactors who aren't blocked, each at the strongest thing they did. */
export function tally(events, trusted, verify = verifyEvent, blocked = new Set()) {
  const out = new Map()
  const counts = pk => trusted.has(pk) && !blocked.has(pk)
  for (const ev of events) {
    const w = engagementWeight(ev?.kind), target = w && targetOf(ev)
    if (!target) continue
    const who = reactorOf(ev, verify, counts)
    if (!who) continue
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
export function scoreNotes(notes, t, { floor = MIN_REACTORS, now = Math.floor(Date.now() / 1000), scores = null } = {}) {
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
    scores?.set(n.id, raw * decay)
  }
  scored.sort((a, b) => b.score - a.score || (a.note.id < b.note.id ? -1 : 1))
  const perAuthor = new Map()
  return scored.filter(({ note }) => {
    const c = perAuthor.get(note.pubkey) ?? 0
    perAuthor.set(note.pubkey, c + 1)
    return c < PER_AUTHOR
  }).map(s => s.note)
}

/**
 * The user, their follows and the people their follows follow: the follows' contact lists (wot.js followLists, shared
 * with the Web of Trust tab, fetched once per follow list this session). `query` is for tests.
 */
export async function trustSet(me, follows, { relays = PROFILE_RELAYS, query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const set = new Set([me, ...follows].filter(Boolean))
  for (const ev of (await followLists(me, follows, { relays, query })).values())
    for (const t of ev.tags ?? []) if (t[0] === "p" && /^[0-9a-f]{64}$/.test(t[1] ?? "")) set.add(t[1])
  return set
}

/**
 * The Popular page: notes ranked from the last day's engagement on these relays. Asks once for everyone's
 * engagement (as the iPhone does) and once for the follows' own, since a busy relay's 5,000 can miss them.
 * Blocked people's likes, reposts and zaps don't count. A zap receipt counts only if the payee's own zap service
 * published it and its signed request holds up (`trust`, zaps.js trustedReceipts; `ctx` is this account's, and
 * `trust` is for the tests). -> { notes, trusted, scores } (trusted: how many people count,
 * so the screen can say why it's empty; scores: note id -> its score, for the rank line). `query` is for tests.
 */
export async function fetchPopular({ me, follows, relays, vault, blocked = new Set(), now = Math.floor(Date.now() / 1000), ctx, trust = receiptTrust(ctx), query = (r, f, o) => pool.querySync(r, f, o) }) {
  const urls = uniq(relays)
  const since = now - WINDOW, kinds = [7, 6, 9735]
  // The trust set and the day's engagement don't depend on each other, so they are asked at the same time.
  const asks = [query(urls, { kinds, since, limit: 5000 }, { maxWait: 10000 })]
  for (let i = 0; i < follows.length; i += 250) asks.push(query(urls, { kinds: [7, 6], authors: follows.slice(i, i + 250), since, limit: 2000 }, { maxWait: 10000 }))
  const [trusted, answers] = await Promise.all([trustSet(me, follows, { query }), Promise.all(asks)])
  const byId = new Map()
  for (const evs of answers) for (const ev of evs) if (ev?.id) byId.set(ev.id, ev)
  // A receipt is anyone's event, so it is filtered before it can vote: only the payee's zap service's own, with a
  // signed request (`trust`, which looks each payee's zap service up). Only receipts that could vote are sent to it:
  // a trusted, unblocked zapper's verified request for this very note (reactorOf, the same test tally applies), so
  // a stranger's zap costs no lookup. Each payee is looked up once per load, all before anything is ranked.
  const all = [...byId.values()]
  const counts = pk => trusted.has(pk) && !blocked.has(pk)
  const canVote = all.filter(e => e.kind === 9735 && reactorOf(e, verifyEvent, counts))
  const okZaps = new Set(canVote.length ? (await trust(canVote).catch(() => [])).map(e => e.id) : [])
  const t = tally(all.filter(e => e.kind !== 9735 || okZaps.has(e.id)), trusted, verifyEvent, blocked)
  const ids = rankTargets(t)
  if (!ids.length) return { notes: [], trusted: trusted.size, scores: new Map() }
  // Bodies: Haven /feed first (read only), the relays for the rest.
  const found = new Map()
  if (vault) for (const ev of await vault.feed.query({ ids, kinds: [1] }).catch(() => [])) found.set(ev.id, ev)
  const missing = ids.filter(id => !found.has(id))
  if (missing.length) for (const ev of await query(urls, { ids: missing, kinds: [1] }, { maxWait: 8000 })) if (ev?.kind === 1 && missing.includes(ev.id)) found.set(ev.id, ev)
  // Only notes by people in the web show: trusted likes can lift a stranger's note, but it stays out (Logen 2026-11-04).
  const scores = new Map()
  return { notes: scoreNotes([...found.values()].filter(n => trusted.has(n.pubkey)), t, { now, scores }), trusted: trusted.size, scores }
}

// The Popular feed's own controls (iPhone PopularRankControls.swift; parity #21): who it ranks, and the rank line.
// Both are for this visit, as on the phone (FeedService.popularFilter, showPopularEngagement).

/** Everyone / People you follow / People you don't follow (PopularFilter.menuTitle). */
export const AUDIENCES = [["all", "Everyone"], ["follows", "People you follow"], ["nonFollows", "People you don't follow"]]
/** Whether a note's author is in `audience` (FeedFilterEngine's popular branch). */
export const audienceKeeps = (note, audience, follows) =>
  audience === "follows" ? follows.has(note.pubkey) : audience === "nonFollows" ? !follows.has(note.pubkey) : true
/** PopularRanking.ranks: each scored note's place in the order shown, from #1; a narrower audience renumbers. */
export function popularRanks(ids, scores) {
  const ranks = new Map()
  for (const id of ids) if (scores.has(id) && !ranks.has(id)) ranks.set(id, ranks.size + 1)
  return ranks
}
/** PopularRankLine.formatted: "1.2k" from 1000, else the whole number. */
export const rankScore = s => (s >= 1000 ? `${(s / 1000).toFixed(1)}k` : `${Math.round(s)}`)
