// The Vault's search (iPhone VaultSearchBar + VaultSearchLogic): every word typed has to be in a person's names, about
// or NIP-05, or in a note's text or its title/summary/subject tags. It reads only this browser's relay (Haven's
// NIP-50 search, haven-go/search.go) and re-checks each hit here, as the phone does with its own stores.

import { rankPeople, rankTags } from "./people-rank.js"

export const ARTICLE_KIND = 30023
/** NIP-68 pictures, NIP-71 videos (normal and short), the older addressable video kinds (VaultSearchLogic.mediaKinds). */
export const MEDIA_KINDS = [20, 21, 22, 34235, 34236]
/** Notes, comments, polls, highlights, articles and media. Reposts are left out: their content is another note's JSON. */
export const NOTE_KINDS = [1, 1068, 1111, 9802, ARTICLE_KIND, ...MEDIA_KINDS]

export const SECTIONS = [
  { id: "people", title: "People" },
  { id: "notes", title: "Notes" },
  { id: "articles", title: "Articles" },
  { id: "media", title: "Media" },
  { id: "hashtags", title: "Hashtags" },
  { id: "links", title: "Links" },
]

/** The words to find, lowercased, or null under two characters (one character matches nearly everything). */
export function terms(query) {
  const q = String(query ?? "").trim().toLowerCase()
  if (q.length < 2) return null
  const t = q.split(/\s+/).filter(Boolean)
  return t.length ? t : null
}

/** Each word somewhere in one of the fields ("jane doe" finds name "jane" + nip05 "doe@x"). */
export const matchesFields = (words, fields) => {
  const hay = fields.filter(f => typeof f === "string").map(f => f.toLowerCase())
  return words.every(w => hay.some(h => h.includes(w)))
}

/** A note's searchable text: content plus title, summary and subject, what haven-go's searchText reads. */
export function matchesNote(words, ev) {
  const parts = [ev.content ?? "", ...(ev.tags ?? []).filter(t => ["title", "summary", "subject"].includes(t[0]) && typeof t[1] === "string").map(t => t[1])]
  return matchesFields(words, [parts.join("\n")])
}

/** The pubkey a query names: 64 hex, or an npub with a good checksum, with or without nostr:. */
export function pubkeyIn(query, decode) {
  const t = String(query ?? "").trim().toLowerCase().replace(/^nostr:/, "")
  if (/^[0-9a-f]{64}$/.test(t)) return t
  if (t.startsWith("npub1")) { try { const d = decode(t); return d.type === "npub" ? d.data : null } catch { return null } }
  return null
}

const profileOf = ev => { try { const p = JSON.parse(ev.content); return p && typeof p === "object" ? p : {} } catch { return {} } }

/** Whether a kind 0 belongs under People: a key query finds that one person; any other has to be in the names, about
 *  or NIP-05, not the hex key ("ab" would otherwise list nearly everyone). VaultSearchLogic.keepsPerson. */
export function keepsPerson(ev, words, key) {
  if (key) return ev.pubkey === key
  const p = profileOf(ev)
  return matchesFields(words, [p.display_name, p.displayName, p.name, p.about, p.nip05])
}

export const sectionOf = kind => kind === ARTICLE_KIND ? "articles" : MEDIA_KINDS.includes(kind) ? "media" : "notes"

/** `#word` hashtags in text, lowercased. */
export const hashtagsInText = text => [...String(text ?? "").matchAll(/#([\p{L}\p{N}_]+)/gu)].map(m => m[1].toLowerCase())

/** Hashtags on the matched notes that contain a word of the query (# ignored), from text and t tags: a tag that is
 *  exactly a word of the query first, then the one most notes carry, then A-Z (people-rank.js rankTags). */
export function hashtags(notes, query) {
  const words = String(query ?? "").toLowerCase().replace(/#/g, " ").split(/\s+/).filter(Boolean)
  if (!words.length) return []
  const counts = new Map()
  for (const n of notes) {
    const tags = new Set([...hashtagsInText(n.content), ...(n.tags ?? []).filter(t => t[0] === "t" && t[1]).map(t => t[1].toLowerCase())])
    for (const t of tags) if (words.some(w => t.includes(w))) counts.set(t, (counts.get(t) ?? 0) + 1)
  }
  const exact = new Set(words)
  return rankTags(counts, "").sort((a, b) => exact.has(b) - exact.has(a)) // stable: count, then A-Z, inside each
}

/** Sentence punctuation after a URL isn't part of it; a ) or ] is only when the URL has more closers than openers. */
export function trimUrl(raw) {
  let url = raw
  const count = (s, c) => s.split(c).length - 1
  for (;;) {
    const last = url.at(-1)
    if (last && ".,;:!?\"'".includes(last)) url = url.slice(0, -1)
    else if ((last === ")" && count(url, ")") > count(url, "(")) || (last === "]" && count(url, "]") > count(url, "["))) url = url.slice(0, -1)
    else return url
  }
}

/** Links in the matched notes, each URL once, in note order. */
export function links(notes) {
  const seen = new Set(), out = []
  for (const n of notes) for (const m of String(n.content ?? "").matchAll(/https?:\/\/\S+/g)) {
    const url = trimUrl(m[0])
    if (seen.has(url)) continue
    seen.add(url)
    out.push({ url, title: url.replace(/^https?:\/\//, ""), noteId: n.id })
  }
  return out
}

/**
 * Search this browser's relay. `stores`: Haven clients ({ query }) to read: the user's own notes, what others sent
 * them, the feed cache (where profiles are kept too). -> { people, notes, articles, media, hashtags, links, cut }
 * People by the shared ranker (you, follows, then the rest; best name match first); notes newest first. Blocked
 * authors are left out.
 * `mine`: the pubkey of the account in use, for "My notes": only notes it wrote (asked with `authors`, which Haven's
 * search applies before the words, haven-go/search.go) and no People section. Other added accounts don't count.
 */
export async function searchVault(stores, query, { follows = [], blocked = new Set(), decode, limit = 500, mine = null, me = null } = {}) {
  const words = terms(query)
  const empty = { people: [], notes: [], articles: [], media: [], hashtags: [], links: [], cut: false }
  if (!words) return empty
  const key = decode ? pubkeyIn(query, decode) : null
  const search = words.join(" ")
  let cut = false // a store gave back a full page: there may be more than is shown
  const ask = async filter => (await Promise.all(stores.map(async s => {
    const evs = await s.query({ ...filter, search, limit }).catch(() => [])
    if (evs.length >= limit) cut = true
    return evs
  }))).flat()
  const [profiles, found] = await Promise.all([
    mine ? [] : key ? (await Promise.all(stores.map(s => s.query({ kinds: [0], authors: [key], limit: 1 }).catch(() => [])))).flat() : ask({ kinds: [0] }),
    ask(mine ? { kinds: NOTE_KINDS, authors: [mine] } : { kinds: NOTE_KINDS }),
  ])
  const newest = new Map()
  for (const ev of profiles) if (ev?.kind === 0 && !blocked.has(ev.pubkey) && keepsPerson(ev, words, key) && !(newest.get(ev.pubkey)?.created_at >= ev.created_at)) newest.set(ev.pubkey, ev)
  // The shared people ranker (people-rank.js): you, follows, then everyone here; exact name > starts with > a word
  // starts with > contains > about only; shorter names first. Every one of them already matched, so none is dropped.
  const people = rankPeople([...newest.keys()], words.join(" "), { me, follows: new Set(follows), profileOf: pk => profileOf(newest.get(pk)), match: "any" })
  // A pasted npub finds its person even with no profile here yet.
  if (!mine && !people.length && key && String(query).trim().toLowerCase().replace(/^nostr:/, "").startsWith("npub1") && !blocked.has(key)) people.push(key)
  const byId = new Map()
  for (const ev of found) if (NOTE_KINDS.includes(ev?.kind) && !blocked.has(ev.pubkey) && (!mine || ev.pubkey === mine) && matchesNote(words, ev)) byId.set(ev.id, ev)
  const all = [...byId.values()].sort((a, b) => b.created_at - a.created_at)
  return {
    people,
    notes: all.filter(e => sectionOf(e.kind) === "notes"),
    articles: all.filter(e => sectionOf(e.kind) === "articles"),
    media: all.filter(e => sectionOf(e.kind) === "media"),
    hashtags: hashtags(all, query),
    links: links(all),
    cut,
  }
}

// The "Notes / My notes" switch over the Vault's search (plan NV_SEARCH_PLAN_2026_11_27.md 2.3, Logen 5d1ce4cb): it
// remembers its last setting, in this browser. Default Notes (everything in the Vault).
const MINE_KEY = "nv-vault-search-mine"
export const searchesMine = (storage = globalThis.localStorage) => { try { return storage?.getItem(MINE_KEY) === "on" } catch { return false } }
export const setSearchesMine = (on, storage = globalThis.localStorage) => { try { storage?.setItem(MINE_KEY, on ? "on" : "off") } catch {} }
