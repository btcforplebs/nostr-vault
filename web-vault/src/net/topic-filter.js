// Which hashtag posts a new account sees before it has a web of trust to read them through: the iPhone's
// TopicFeedFilter (HavenApp/Models/TopicFeedFilter.swift), ported as is. Unfiltered, a tag like #bitcoin was ~95% bots
// and link farms (sampled 2026-10-08: 569 posts -> 29 from 23 people). Every rule is a fact about the post or its
// author, never a list of people we chose, so nobody's web of trust is steered.
// - The author follows at least MIN_FOLLOWS people (bots and farms almost never follow anyone; unknown counts wait).
// - Fewer than MAX_HASHTAGS hashtags (hashtag stuffing).
// - Not a link to a site FARM_AUTHORS+ different accounts link to in the same feed (how farms post). Media don't count.
// - Not a copy of text already shown.
// - At most PER_AUTHOR posts per person.
// - Not marked adult (#nsfw and the like, or a NIP-36 content warning).
// - Not posted by an app or game on its player's behalf (its client tag names the site it links to).

/** Above a screened hashtag page: what it is, and the way out. */
export const SCREENED_LINE = "Unfiltered: people you don't know yet"

/** 20, not 10: the scheduled-content bots that got past 10 follow exactly 10 (sampled 2026-10-08). */
export const MIN_FOLLOWS = 20
export const MAX_HASHTAGS = 6
export const FARM_AUTHORS = 4
export const PER_AUTHOR = 2
export const ADULT_HASHTAGS = new Set(["nsfw", "porn", "xxx", "nude", "nudes", "onlyfans"])
/** Everyday Nostr apps: sharing a note's web link from the app you're in (Damus and damus.io) is a person posting. */
export const GENERAL_CLIENTS = new Set(["damus", "primal", "primalandroid", "primalios", "snort", "coracle", "yakihonne",
  "nostrudel", "amethyst", "iris", "nostrich", "jumble", "ditto", "olas", "nostur", "nostrapp", "habla", "highlighter",
  "zapstore", "nostrvault", "haven"])
const MEDIA = new Set(["jpg", "jpeg", "png", "gif", "webp", "heic", "mp4", "mov", "webm"])

const lettersOnly = s => String(s ?? "").toLowerCase().replace(/[^a-z0-9]/g, "")

/** Hosts of the non-media links in a post. */
export function linkDomains(content = "") {
  const out = new Set()
  for (const word of String(content).split(/\s+/)) {
    if (!/^https?:\/\//.test(word)) continue
    let u
    try { u = new URL(word) } catch { continue }
    const ext = u.pathname.includes(".") ? u.pathname.split(".").pop().toLowerCase() : ""
    if (MEDIA.has(ext)) continue
    out.add(u.hostname.toLowerCase())
  }
  return out
}

export const hashtagCount = tags => (tags ?? []).filter(t => t?.length >= 2 && t[0] === "t").length

/** Lowercased, whitespace-collapsed, links dropped (farms vary the link), first 120 characters. */
export const textKey = content => String(content ?? "").toLowerCase().split(/\s+/).filter(Boolean)
  .filter(w => !w.startsWith("http://") && !w.startsWith("https://") && !w.startsWith("nostr:")).join(" ").slice(0, 120)

export const isAdult = tags => (tags ?? []).some(t => t?.[0] === "content-warning" || (t?.length >= 2 && t[0] === "t" && ADULT_HASHTAGS.has(String(t[1]).toLowerCase())))

/** The client tag and a linked site's name agree ("Plebs vs. Zombies" and plebsvszombies.cc): the app wrote it. */
export function isAppMade(post) {
  const clients = (post.tags ?? []).filter(t => t?.length >= 2 && t[0] === "client").map(t => lettersOnly(t[1]))
    .filter(c => c.length >= 4 && !GENERAL_CLIENTS.has(c))
  if (!clients.length) return false
  const sites = [...linkDomains(post.content)].map(host => {
    const labels = host.split(".")
    return lettersOnly(labels.length >= 2 ? labels[labels.length - 2] : labels[0] ?? "")
  }).filter(s => s.length >= 4)
  return clients.some(c => sites.some(s => c.includes(s) || s.includes(c)))
}

/** `posts` newest first; `followCounts`: Map or object of how many people each author follows (unknown: missing).
 *  -> the posts to show, in the same order. */
export function screenTopic(posts, followCounts) {
  const count = pk => (followCounts instanceof Map ? followCounts.get(pk) : followCounts?.[pk])
  const domainAuthors = new Map()
  for (const p of posts) for (const d of linkDomains(p.content)) {
    if (!domainAuthors.has(d)) domainAuthors.set(d, new Set())
    domainAuthors.get(d).add(p.pubkey)
  }
  const farms = new Set([...domainAuthors].filter(([, a]) => a.size >= FARM_AUTHORS).map(([d]) => d))
  const seenText = new Set(), perAuthor = new Map(), out = []
  for (const p of posts) {
    const follows = count(p.pubkey)
    if (!(follows >= MIN_FOLLOWS)) continue
    if (hashtagCount(p.tags) >= MAX_HASHTAGS) continue
    if ([...linkDomains(p.content)].some(d => farms.has(d))) continue
    if (isAdult(p.tags) || isAppMade(p)) continue
    const key = textKey(p.content)
    if (seenText.has(key)) continue
    seenText.add(key)
    if ((perAuthor.get(p.pubkey) ?? 0) >= PER_AUTHOR) continue
    perAuthor.set(p.pubkey, (perAuthor.get(p.pubkey) ?? 0) + 1)
    out.push(p)
  }
  return out
}

/** How many people each author follows, from their newest kind 3: one query per 250 authors. -> Map pubkey -> count */
export async function followCounts(authors, relays, query) {
  const out = new Map(), newest = new Map()
  const list = [...new Set(authors)]
  for (let i = 0; i < list.length; i += 250) {
    const evs = await query(relays, { kinds: [3], authors: list.slice(i, i + 250) }, { maxWait: 6000 }).catch(() => [])
    for (const e of evs) if (e?.kind === 3 && (!newest.has(e.pubkey) || e.created_at > newest.get(e.pubkey).created_at)) newest.set(e.pubkey, e)
  }
  for (const [pk, e] of newest) out.set(pk, new Set((e.tags ?? []).filter(t => t[0] === "p" && /^[0-9a-f]{64}$/.test(t[1] ?? "")).map(t => t[1])).size)
  return out
}
