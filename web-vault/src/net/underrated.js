// The Underrated feed, as the iPhone and Android rank it (haven-go feed_underrated.go): Popular turned over. Popular
// puts the most engaged notes first; Underrated looks for the note that did well *for its author*, among people you
// don't follow whom your follows follow (one step out; your follows are left out entirely). People who post less and
// are known to fewer of your follows score higher, likes, reposts and zaps are weighed against what that person
// usually gets, and notes bridged in from another network (NIP-48 "proxy" tag) get extra weight.
// It counts the same engagement Popular does (popular.js trustedTally: only your web's likes, reposts and checked
// zaps, never the author's own, Popular's bar of three people) over two days, and withholds the feed while your
// follows' contact lists aren't in. Who then shows is the feed gate's call (feed-gate.js, Reach: your web + a few one
// hop out by default). Strangers' data, held in memory: nothing is written to Haven /feed.
import { pool } from "./pool.js"
import { followLists } from "./wot.js"
import { receiptTrust } from "./zaps.js"
import { MIN_REACTORS, rankTargets, trustedTally, noteBodies } from "./popular.js"

export const WINDOW = 48 * 3600 // underratedWindow: two days (Popular looks back one)
export const MAX_CANDIDATES = 1000 // underratedMaxCandidates: bodies looked up, most engaged first
export const MAX_NOTES = 300 // underratedMaxNotes
export const PER_AUTHOR = 2 // underratedMaxPerAuthor
export const BRIDGE_BOOST = 1.5 // underratedBridgeBoost
export const POST_COUNT_LIMIT = 200 // underratedPostCountLimit
export const UNKNOWN_POSTS = 8 // underratedUnknownPosts: no "posts less" boost for someone /feed knows nothing of
const COUNT_READS_AT_ONCE = 16

/** Why an empty Underrated is empty (feed_underrated.go underratedEmptyReason; Apple UnderratedEmptyReason). */
export const REASONS = Object.freeze({ webNotReady: "web_not_ready", webIncomplete: "web_incomplete", nothingQualified: "nothing_qualified" })
/** The empty screen's words for each reason (Apple UnderratedEmptyState; the web has no wider-network job to offer). */
export const EMPTY_TEXT = {
  [REASONS.webNotReady]: "Underrated is waiting for your web: your follows' follow lists haven't come back from your relays yet.",
  [REASONS.webIncomplete]: "Underrated shows people your follows follow, and none of your follows' lists named anyone you don't follow yet.",
  [REASONS.nothingQualified]: "Nothing underrated yet: it shows people your follows follow and you don't, once a few people in your web like, repost or zap them. Check back later.",
}

/** A NIP-48 proxy tag with a source: the note was brought over from another network (isBridged). */
export const isBridged = note => (note.tags ?? []).some(t => t.length >= 3 && t[0] === "proxy" && !!t[1])

/**
 * One step out (oneStepOutFrom): pubkey -> how many of your follows follow them, for everyone at least one follow
 * follows who isn't you or a follow. A blocked follow vouches for nobody. `lists`: wot.js followLists.
 */
export function oneStepOut(me, follows, lists, blocked = new Set()) {
  const mine = new Set(follows)
  const out = new Map()
  for (const f of mine) {
    if (blocked.has(f)) continue
    const named = new Set()
    for (const t of lists.get(f)?.tags ?? []) if (t[0] === "p" && /^[0-9a-f]{64}$/.test(t[1] ?? "")) named.add(t[1])
    for (const pk of named) if (pk !== me && !mine.has(pk)) out.set(pk, (out.get(pk) ?? 0) + 1)
  }
  return out
}

/** The trusted reactors' summed weight on a note and how many there are, the author left out (scoreExcludingAuthor). */
function excludingAuthor(reactors, author) {
  let raw = 0, distinct = 0
  for (const [pk, w] of reactors ?? []) if (pk !== author) { raw += w; distinct++ }
  return { raw, distinct }
}

/**
 * Resolved notes ranked (scoreUnderrated). Per note, with raw its trusted reactors' summed weight (author left out):
 *   base   = log2(1 + raw)                 engagement counts, damped
 *   lift   = (raw + 1) / (usual + 1)       against the author's own usual in the window
 *   posts  = 1 / (1 + log2(posts))         fewer posts, more weight (unknown to /feed: UNKNOWN_POSTS)
 *   reach  = 1 / (1 + log2(1 + vouches))   known to fewer of your follows
 *   bridge = BRIDGE_BOOST for a bridged note
 *   decay  = Popular's: full for 12 h, then down to 0.2
 * Only people one step out (`reach`: pubkey -> vouches) at Popular's bar; best first, ties on id, PER_AUTHOR each,
 * MAX_NOTES in all. `posts`: pubkey -> posts /feed has from them in the window. `scores` gets id -> score.
 */
export function scoreUnderrated(notes, t, { reach, posts = new Map(), now = Math.floor(Date.now() / 1000), scores = null } = {}) {
  const cands = [], authorTotal = new Map(), authorNotes = new Map(), seen = new Set()
  for (const n of notes) {
    if (!n || seen.has(n.id)) continue
    seen.add(n.id)
    if (!reach?.has(n.pubkey)) continue
    const { raw, distinct } = excludingAuthor(t.get(n.id), n.pubkey)
    if (distinct < MIN_REACTORS) continue
    cands.push({ n, raw })
    authorTotal.set(n.pubkey, (authorTotal.get(n.pubkey) ?? 0) + raw)
    authorNotes.set(n.pubkey, (authorNotes.get(n.pubkey) ?? 0) + 1)
  }
  const ranked = cands.map(({ n, raw }) => {
    const pk = n.pubkey, known = posts.get(pk) ?? 0, seenHere = authorNotes.get(pk)
    let count = Math.max(known, seenHere, 1)
    const usual = authorTotal.get(pk) / count
    if (known <= 0) count = Math.max(seenHere, UNKNOWN_POSTS) // unknown: the usual is what we saw, no "posts less" boost
    let score = Math.log2(1 + raw) * ((raw + 1) / (usual + 1)) * (1 / (1 + Math.log2(count)))
    score *= 1 / (1 + Math.log2(1 + Math.max(reach.get(pk), 0)))
    if (isBridged(n)) score *= BRIDGE_BOOST
    const ageHours = (now - n.created_at) / 3600
    score *= Math.max(0.2, 1 - Math.max(0, ageHours - 12) * 0.05)
    return { n, score }
  }).sort((a, b) => b.score - a.score || (a.n.id < b.n.id ? -1 : 1))
  const perAuthor = new Map(), out = []
  for (const { n, score } of ranked) {
    const c = perAuthor.get(n.pubkey) ?? 0
    if (c >= PER_AUTHOR) continue
    perAuthor.set(n.pubkey, c + 1)
    if (out.length >= MAX_NOTES) break
    out.push(n)
    scores?.set(n.id, score)
  }
  return out
}

/** How many posts Haven /feed holds from each author in the window (localPostCounts). A failed read is unknown. */
async function postCounts(vault, authors, since) {
  const counts = new Map()
  if (!vault) return counts
  for (let i = 0; i < authors.length; i += COUNT_READS_AT_ONCE) {
    await Promise.all(authors.slice(i, i + COUNT_READS_AT_ONCE).map(pk =>
      vault.feed.query({ kinds: [1, 30023], authors: [pk], since, limit: POST_COUNT_LIMIT }).then(evs => counts.set(pk, evs.length), () => {})))
  }
  return counts
}

/** Why an empty answer is empty: no lists back yet, nobody one step out, or nothing cleared the bar. */
export const emptyReason = (lists, reach) => (!lists?.size ? REASONS.webNotReady : !reach?.size ? REASONS.webIncomplete : REASONS.nothingQualified)

/**
 * The Underrated page, worked out fresh each time (feed_underrated.go: no cached answer). -> { notes, reason, scores }
 * (reason: "" with notes, else REASONS; scores: note id -> score). `lists`, `trust` and `query` are for tests.
 */
export async function fetchUnderrated({ me, follows, relays, vault, blocked = new Set(), now = Math.floor(Date.now() / 1000), ctx, trust = receiptTrust(ctx),
  query = (r, f, o) => pool.querySync(r, f, o), lists = null }) {
  const scores = new Map()
  // Fails closed, as Popular does: without the follows' lists nobody can be named one step out.
  const got = lists ?? await followLists(me, follows, { query })
  const reach = oneStepOut(me, follows, got, blocked)
  if (!got.size || !reach.size) return { notes: [], reason: emptyReason(got, reach), scores }
  const { t } = await trustedTally({ me, follows, relays, blocked, now, window: WINDOW, trust, query })
  const ids = rankTargets(t, MIN_REACTORS, MAX_CANDIDATES)
  if (!ids.length) return { notes: [], reason: REASONS.nothingQualified, scores }
  const bodies = [...(await noteBodies(ids, { vault, relays, query })).values()].filter(n => reach.has(n.pubkey))
  const posts = await postCounts(vault, [...new Set(bodies.map(n => n.pubkey))], now - WINDOW)
  const notes = scoreUnderrated(bodies, t, { reach, posts, now, scores })
  return { notes, reason: notes.length ? "" : REASONS.nothingQualified, scores }
}
