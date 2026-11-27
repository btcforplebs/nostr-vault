// One people ranker for every box that finds a person (search plan RESEARCH/NV_SEARCH_PLAN_2026_11_27.md 1a, W2): the
// Search tab, the WoT globe's Find someone, the Vault search, compose mentions and the New message picker. Twins:
// Apple Models/PeopleSearchRank.swift, Android data/model/PeopleSearchRank.kt.
//
// Sort key, lowest first:
//   1. Closeness: -1 thread people (mentions only), 0 you, 1 follows, 2 your web, 3 further out (hop 3+, from the
//      desktop's rank copy), 4 outside. Logen 5d1ce4cb: hop 3+ counts as inside your web.
//   2. Name match: exact name, display name or NIP-05 (case- and accent-folded) > starts with > a word starts with >
//      contains > only the about matches (or nothing does).
//   3. Trust score from the rank copy, high first.
//   4. Shorter name, then pubkey, so the order holds while results stream in.
// Blocked people are always left out. No follower or engagement counts: they are cheap to fake.

export const TIER = { thread: -1, you: 0, follow: 1, web: 2, further: 3, outside: 4 }
/** Tiers 0-3 are "in your web" (the Search tab's fold keeps the rest under "Outside your web"). */
export const INSIDE_MAX = TIER.further

/** Lowercase with accents taken off ("Zoë" -> "zoe"), trimmed. */
export const foldText = s => String(s ?? "").normalize("NFD").replace(/\p{M}/gu, "").toLowerCase().trim()

/** The names a person is found by: name, display name and NIP-05 (with its "_@" and its local part). */
export const namesOf = p => folded(p).names

// Folded names (and their words) per profile object: a box re-ranks on every keystroke and every profile batch, and
// folding (NFD + regex) every name each time was ~10x the old filter on a 150k web (Tron, #2689 read). Profiles are
// replaced, never edited, when a newer kind 0 lands (profiles.js store), so an object's names never go stale.
const foldCache = new WeakMap()
const NO_NAMES = { names: [], words: [] }
function folded(p) {
  if (!p || typeof p !== "object") return NO_NAMES
  let f = foldCache.get(p)
  if (f) return f
  const names = []
  for (const v of [p.name, p.display_name, p.displayName]) if (typeof v === "string" && v.trim()) names.push(foldText(v))
  if (typeof p.nip05 === "string" && p.nip05.trim()) {
    const n = foldText(p.nip05).replace(/^_@/, "")
    names.push(n)
    const local = n.split("@")[0]
    if (local && local !== n && local !== "_") names.push(local)
  }
  f = { names, words: names.flatMap(n => n.split(/[\s._\-@]+/).filter(Boolean)) }
  foldCache.set(p, f)
  return f
}

const foldQuery = query => foldText(query).replace(/^@/, "")
function matchFolded(q, p) {
  if (!q) return 4
  const { names, words } = folded(p)
  if (names.some(n => n === q)) return 0
  if (names.some(n => n.startsWith(q))) return 1
  if (words.some(w => w.startsWith(q))) return 2
  if (names.some(n => n.includes(q))) return 3
  return 4
}

/** How well `query` names someone with profile `p`: 0 exact, 1 starts with, 2 a word starts with, 3 contains,
 *  4 the about alone (or nothing). An empty query is 4 for everyone, so closeness decides. */
export const nameMatch = (query, p) => matchFolded(foldQuery(query), p)

/** `nameMatch` for one query over many people: the query is folded once. -> (p) -> 0..4 */
export const nameMatcher = query => { const q = foldQuery(query); return p => matchFolded(q, p) }

/** The closeness tier for `pk`. `c`: { me, own: Set (your other accounts), follows: Set, web: Set (hop 2), hopOf(pk)
 *  -> number|null (the rank copy), thread: Set }. */
export function tierOf(pk, c = {}) {
  if (c.thread?.has(pk)) return TIER.thread
  if (pk === c.me || c.own?.has(pk)) return TIER.you
  if (c.follows?.has(pk)) return TIER.follow
  const hop = c.hopOf?.(pk)
  if (c.web?.has(pk) || hop === 2) return TIER.web
  if (Number.isInteger(hop) && hop >= 3) return TIER.further
  return TIER.outside
}

/** Whether `pk` counts as inside your web (tier 3 or closer). */
export const isInside = (pk, c) => tierOf(pk, c) <= INSIDE_MAX

const shownName = p => String(p?.display_name || p?.displayName || p?.name || "")

/**
 * `pubkeys` (any order, repeats allowed) ranked for `query`. -> [pk], blocked left out, each once.
 * `c`: closeness (tierOf) plus { profileOf(pk) -> profile|null, scoreOf(pk) -> number|null, blocked: Set,
 * match: "names" (default) keeps only people whose names or NIP-05 contain the query, "any" keeps everyone (the
 * caller already matched them, e.g. a relay's NIP-50 answer or a Vault hit on the about) }.
 */
export function rankPeople(pubkeys, query, c = {}) {
  const profileOf = c.profileOf ?? (() => null)
  const keepAll = c.match === "any" || !foldText(query)
  const match = nameMatcher(query)
  const rows = []
  for (const pk of new Set(pubkeys)) {
    if (typeof pk !== "string" || c.blocked?.has(pk)) continue
    const p = profileOf(pk)
    const m = match(p)
    if (!keepAll && m > 3) continue
    const score = c.scoreOf?.(pk)
    rows.push({ pk, tier: tierOf(pk, c), m, score: typeof score === "number" ? score : -1, len: shownName(p).length || 999 })
  }
  rows.sort((a, b) => a.tier - b.tier || a.m - b.m || b.score - a.score || a.len - b.len || (a.pk < b.pk ? -1 : a.pk > b.pk ? 1 : 0))
  return rows.map(r => r.pk)
}

/** The rank copy's hop and score for `copy` (rank-copy-store.js rankCopyFor), as tierOf/rankPeople read them. */
export function fromRankCopy(copy) {
  if (!copy) return {}
  const row = pk => copy.people?.get(pk) ?? copy.globe?.get(pk) ?? null
  return { hopOf: pk => row(pk)?.hop ?? null, scoreOf: pk => row(pk)?.score ?? null }
}

/** Kind 0 events from a relay search, by how well `query` names them (exact > starts with > a word starts with >
 *  contains > about only), relay order kept inside each: the Welcome, referrer and read-only sign-in boxes, which
 *  have no web of trust yet (plan 2.9). */
export function byNameMatch(events, query) {
  const profile = ev => { try { const p = JSON.parse(ev?.content ?? ""); return p && typeof p === "object" ? p : null } catch { return null } }
  const match = nameMatcher(query)
  return events.map((ev, i) => [ev, match(profile(ev)), i]).sort((a, b) => a[1] - b[1] || a[2] - b[2]).map(([ev]) => ev)
}

/** Hashtags in results (plan 1c): the tag that is exactly the query first, then the one the most results carry,
 *  then A-Z. `counts`: Map(tag -> results carrying it). */
export function rankTags(counts, query) {
  const q = foldText(query).replace(/^#/, "")
  return [...counts.keys()].sort((a, b) => ((foldText(b) === q) - (foldText(a) === q)) || counts.get(b) - counts.get(a) || (a < b ? -1 : a > b ? 1 : 0))
}
