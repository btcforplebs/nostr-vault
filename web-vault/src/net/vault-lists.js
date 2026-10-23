// The Vault tab's lists, built the way the iPhone's Vault tab builds them (HavenApp VaultTabView, VaultActivity,
// VaultTypes): one "Vault" activity list of everything that came in, then Notes, Articles, Highlights, Media, Likes,
// Zaps and Followers, each with the phone's filters. The user's own events come from Haven's outbox. What others
// sent (replies, mentions, quotes, reposts, likes, zaps, follows) is read from the user's relays and kept in Haven's
// inbox route when it takes them, so the list still shows after a reload or offline. Nothing here signs.
import { pool, uniq } from "./pool.js"
import { groupNotifications, replyTarget, reactionEmoji, zapRequest, zapSats } from "./notifications.js"
import { imageItem } from "./note-media.js"

const HEX64 = /^[0-9a-f]{64}$/
export const ARTICLE_KIND = 30023
export const HIGHLIGHT_KIND = 9802
export const NOTE_KINDS = [1, 6]
/** Kinds the Vault list reads from the network for the user: everything the phone's inbox lists. */
export const INBOUND_KINDS = [1, 6, 7, 9735, HIGHLIGHT_KIND, ARTICLE_KIND]

/** The mode menu, in the phone's order. "activity" is shown as "Vault". */
export const MODES = [
  { id: "activity", title: "Vault" },
  { id: "notes", title: "Notes" },
  { id: "articles", title: "Articles" },
  { id: "highlights", title: "Highlights" },
  { id: "media", title: "Media" },
  { id: "likes", title: "Likes" },
  { id: "zaps", title: "Zaps" },
  { id: "followers", title: "Followers" },
]

/** Each mode's filters, named as the phone names them (VaultFilterChoice.name); `pill` is the short form the closed
 *  pill shows when the name is long. The first one is the default. */
export const FILTERS = {
  activity: [{ id: "all", title: "Everything", pill: "All" }, { id: "mentions", title: "Mentions" }],
  notes: [{ id: "all", title: "All notes", pill: "All" }, { id: "mine", title: "Your notes", pill: "Yours" }, { id: "tagged", title: "Mentions" }],
  articles: [{ id: "all", title: "All articles", pill: "All" }, { id: "recipes", title: "Recipes only", pill: "Recipes" }],
  highlights: [{ id: "all", title: "All highlights", pill: "All" }, { id: "mine", title: "Your highlights", pill: "Yours" }],
  // The phone's gallery filters (MediaGalleryToolbar), then the pictures in your notes, which the web showed before.
  media: [{ id: "all", title: "All media", pill: "All" }, { id: "photos", title: "Photos" }, { id: "videos", title: "Videos" }, { id: "gifs", title: "GIFs" }, { id: "notes", title: "In your notes", pill: "Notes" }],
  likes: [{ id: "received", title: "Likes received", pill: "Received" }, { id: "given", title: "Likes given", pill: "Given" }],
  zaps: [{ id: "received", title: "Zaps received", pill: "Received" }, { id: "given", title: "Zaps given", pill: "Given" }],
  followers: [{ id: "new", title: "Newest followers", pill: "Newest" }, { id: "all", title: "All followers", pill: "All" }],
}

export const isMode = id => MODES.some(m => m.id === id)
export const defaultFilter = mode => FILTERS[mode]?.[0]?.id ?? ""

const tag = (ev, name) => ev.tags.find(t => t[0] === name && t[1])?.[1]
const lastE = ev => { const es = ev.tags.filter(t => t[0] === "e" && HEX64.test(t[1] ?? "")); return es.length ? es[es.length - 1][1] : null }
const tagsMe = (ev, me) => ev.tags.some(t => t[0] === "p" && t[1] === me)
const byNewest = (a, b) => b.created_at !== a.created_at ? b.created_at - a.created_at : (a.id < b.id ? -1 : 1)
const dayOf = ts => { const d = new Date(ts * 1000); return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}` }

/** Picture links in a note: its imeta tags first, then bare links in the text. */
export function imagesOf(ev) {
  const urls = []
  for (const t of ev.tags ?? []) {
    if (t[0] !== "imeta") continue
    const u = t.slice(1).map(s => /^url\s+(\S+)/.exec(s)?.[1]).find(Boolean)
    if (u) urls.push(u)
  }
  for (const m of (ev.content ?? "").matchAll(/https?:\/\/\S+\.(?:png|jpe?g|gif|webp|avif)(?:\?\S*)?/gi)) urls.push(m[0])
  return uniq(urls)
}

/** One line of text for an event: an article's title or summary, else its text with the picture links left out. */
export function previewOf(ev) {
  if (ev.kind === ARTICLE_KIND) {
    const t = tag(ev, "title") || tag(ev, "summary")
    if (t) return t
  }
  const pictures = new Set(imagesOf(ev))
  return (ev.content ?? "").split(/\s+/).filter(w => w && !pictures.has(w)).join(" ")
}

/**
 * The "Vault" list: what others sent you, newest first, folded as the phone folds it (VaultActivity.lines).
 * Likes, plain zaps and reposts on one of your notes share a line; follows on one day share a line; a reply,
 * mention, quote, article, highlight or zap with words is a line of its own.
 * `mine` is the user's own notes (for what a like or repost was about); `follows` is [{ pubkey, at }] of people
 * who follow the user; `blocked` is a Set of pubkeys to leave out.
 * -> [{ id, kind, actors: [pubkey], created_at, openId, preview, emojis, sats, images, imagesBy }]; `imagesBy` is whose
 * note the images are from (whose mesh vault MediaImage may ask).
 */
export function activityRows(inbound, me, { mine = [], follows = [], blocked = new Set() } = {}) {
  const myText = new Map(mine.map(n => [n.id, previewOf(n)]))
  const myImages = new Map(mine.map(n => [n.id, imagesOf(n)]))
  const folds = new Map()
  const singles = []
  const seen = new Set()
  const fold = (kind, target, actor, at, { emoji, sats = 0 } = {}) => {
    const key = `${kind}:${target}`
    const f = folds.get(key) ?? { kind, target, actors: [], emojis: [], sats: 0, at: 0 }
    f.actors.push(actor)
    if (emoji) f.emojis.push(emoji)
    f.sats += sats
    f.at = Math.max(f.at, at)
    folds.set(key, f)
  }
  for (const ev of inbound) {
    if (!ev || seen.has(ev.id) || !Array.isArray(ev.tags)) continue
    seen.add(ev.id)
    if (ev.kind === 7) {
      const target = lastE(ev)
      if (ev.pubkey === me || !target || !myText.has(target) || blocked.has(ev.pubkey)) continue
      fold("like", target, ev.pubkey, ev.created_at, { emoji: reactionEmoji(ev.content) })
      continue
    }
    if (ev.kind === 9735) {
      const req = zapRequest(ev)
      if (!req) continue // no valid zap request: nobody can be named as the sender
      const sender = req.pubkey
      if (sender === me || blocked.has(sender)) continue
      const sats = zapSats(ev)
      const target = (req && lastE(req)) || lastE(ev)
      const comment = (req?.content ?? "").trim()
      if (target && myText.has(target) && !comment) fold("zap", target, sender, ev.created_at, { sats })
      else singles.push({ id: ev.id, kind: "zap", actors: [sender], created_at: ev.created_at, openId: target && myText.has(target) ? target : null,
        preview: comment || (target && myText.get(target)) || "", emojis: [], sats, images: comment ? [] : (target && myImages.get(target)) || [], imagesBy: me })
      continue
    }
    if (ev.pubkey === me || blocked.has(ev.pubkey)) continue
    if (ev.kind === 6) {
      const target = lastE(ev)
      if (target && myText.has(target)) fold("repost", target, ev.pubkey, ev.created_at)
      continue
    }
    if (![1, ARTICLE_KIND, HIGHLIGHT_KIND].includes(ev.kind) || !tagsMe(ev, me)) continue
    let kind = "mention"
    if (ev.kind === ARTICLE_KIND) kind = "article"
    else if (ev.kind === HIGHLIGHT_KIND) kind = "highlight"
    else {
      const quoted = tag(ev, "q")
      if (quoted && myText.has(quoted)) kind = "quote"
      else if (ev.tags.some(t => (t[0] === "e" || t[0] === "E") && t[1])) kind = "reply"
    }
    singles.push({ id: ev.id, kind, actors: [ev.pubkey], created_at: ev.created_at, openId: ev.id, preview: previewOf(ev), emojis: [], sats: 0, images: imagesOf(ev), imagesBy: ev.pubkey })
  }
  const folded = [...folds].map(([key, f]) => ({ id: key, kind: f.kind, actors: uniq(f.actors), created_at: f.at, openId: f.target,
    preview: myText.get(f.target) ?? "", emojis: uniq(f.emojis), sats: f.sats, images: myImages.get(f.target) ?? [], imagesBy: me }))
  const days = new Map()
  for (const f of follows) {
    if (f.pubkey === me || blocked.has(f.pubkey)) continue
    const d = dayOf(f.at)
    days.set(d, [...(days.get(d) ?? []), f])
  }
  const followLines = [...days].map(([d, list]) => {
    const sorted = [...list].sort((a, b) => b.at - a.at)
    return { id: `follow-${d}`, kind: "follow", actors: uniq(sorted.map(f => f.pubkey)), created_at: sorted[0].at, openId: null, preview: "", emojis: [], sats: 0, images: [] }
  })
  return [...singles, ...folded, ...followLines].sort(byNewest)
}

/** The "Vault" list's filters: everything, or only what you might answer (replies, mentions, quotes). */
export const activityFilter = (row, filter) => filter !== "mentions" || ["reply", "mention", "quote"].includes(row.kind)

/** Notes: your own and the ones tagging you, by the phone's Notes filters (ContentFilter all / mine / tagged). */
export function notesFor(own, inbound, me, filter, blocked = new Set()) {
  const mine = own.filter(e => NOTE_KINDS.includes(e.kind))
  const tagged = inbound.filter(e => e.kind === 1 && e.pubkey !== me && tagsMe(e, me) && !blocked.has(e.pubkey))
  const list = filter === "mine" ? mine : filter === "tagged" ? tagged : [...mine, ...tagged]
  return dedupe(list).sort(byNewest)
}

/** Recipes are articles tagged zapcooking or nostrcooking (the phone's recipesOnly). */
export const isRecipe = ev => (ev.tags ?? []).some(t => t[0] === "t" && /^(zapcooking|nostrcooking)$/i.test(t[1] ?? ""))

export function articlesFor(own, inbound, me, filter, blocked = new Set()) {
  const list = [...own.filter(e => e.kind === ARTICLE_KIND), ...inbound.filter(e => e.kind === ARTICLE_KIND && e.pubkey !== me && tagsMe(e, me) && !blocked.has(e.pubkey))]
  return dedupe(filter === "recipes" ? list.filter(isRecipe) : list).sort(byNewest)
}

export function highlightsFor(own, inbound, me, filter, blocked = new Set()) {
  const mine = own.filter(e => e.kind === HIGHLIGHT_KIND)
  if (filter === "mine") return dedupe(mine).sort(byNewest)
  return dedupe([...mine, ...inbound.filter(e => e.kind === HIGHLIGHT_KIND && e.pubkey !== me && tagsMe(e, me) && !blocked.has(e.pubkey))]).sort(byNewest)
}

/** What a highlight is from: the `r` link, else the `a` or `e` it points at. */
export function highlightSource(ev) {
  return tag(ev, "r") || tag(ev, "a") || tag(ev, "e") || ""
}

/** Media: every picture in your notes, newest first, with the note it came from.
 *  -> [{ url, noteId, created_at, item }] (`item`: for MediaImage, imageItem) */
export function mediaFor(own) {
  const seen = new Set()
  const out = []
  for (const ev of [...own].sort(byNewest)) {
    if (![1, ARTICLE_KIND].includes(ev.kind)) continue
    for (const url of imagesOf(ev)) {
      if (seen.has(url)) continue
      seen.add(url)
      out.push({ url, noteId: ev.id, created_at: ev.created_at, item: imageItem(url, ev.tags) })
    }
  }
  return out
}

/**
 * Likes: received (others' reactions on your notes, folded per note) or given (your own kind 7, one row each).
 * -> rows shaped like the Notifications screen's: { id, type, who, noteId, emoji, sats, created_at, events }
 */
export function likesFor(own, inbound, me, filter, blocked = new Set()) {
  if (filter === "given") return own.filter(e => e.kind === 7).sort(byNewest).map(e => ({ id: e.id, type: "reaction", who: [me], noteId: lastE(e), emoji: reactionEmoji(e.content), sats: 0, created_at: e.created_at, events: [e] }))
  return groupNotifications(inbound.filter(e => e.kind === 7), me).filter(r => r.type === "reaction" && !r.who.every(w => blocked.has(w)))
}

/** The sender of a zap receipt: the author of its valid zap request (notifications.js zapRequest), else nobody.
 *  The `P` tag alone is written by the receipt's publisher, so it names no one. */
export const zapSender = ev => zapRequest(ev)?.pubkey || ""

/** Zaps: received (on your notes, folded per note) or given (receipts whose request you signed, from the network). */
export function zapsFor(given, inbound, me, filter, blocked = new Set()) {
  if (filter === "given") {
    return dedupe(given.filter(e => e.kind === 9735 && zapSender(e) === me)).sort(byNewest)
      .map(e => ({ id: e.id, type: "zap", who: [me], noteId: lastE(zapRequest(e) ?? e), emoji: "", sats: zapSats(e), created_at: e.created_at, events: [e], to: tag(e, "p") }))
  }
  return groupNotifications(inbound.filter(e => e.kind === 9735), me).filter(r => r.type === "zap" && !r.who.every(w => blocked.has(w)))
}

/**
 * Followers from kind 3 lists that name the user: each author's newest list counts, and only if it still has them.
 * -> [{ pubkey, at }] newest first. The phone reads its follower ledger; the web reads the lists themselves.
 */
export function followersOf(lists, me, blocked = new Set()) {
  const newest = new Map()
  for (const ev of lists) {
    if (!ev || ev.kind !== 3 || ev.pubkey === me || !HEX64.test(ev.pubkey ?? "") || !Array.isArray(ev.tags)) continue
    const cur = newest.get(ev.pubkey)
    if (!cur || ev.created_at > cur.created_at) newest.set(ev.pubkey, ev)
  }
  return [...newest.values()].filter(ev => tagsMe(ev, me) && !blocked.has(ev.pubkey)).map(ev => ({ pubkey: ev.pubkey, at: ev.created_at })).sort((a, b) => b.at - a.at)
}

/** "Newest followers" are those that arrived after you last looked at the list; "all" is everyone. */
export const followersFilter = (list, filter, seenAt) => filter === "new" ? list.filter(f => f.at > (seenAt ?? 0)) : list

const SEEN = "nv-vault-followers-seen"
export const followersSeenAt = (me, storage = globalThis.localStorage) => Number(storage?.getItem(`${SEEN}:${me}`)) || 0
export const markFollowersSeen = (me, at, storage = globalThis.localStorage) => storage?.setItem(`${SEEN}:${me}`, String(at))

function dedupe(evs) {
  const seen = new Set()
  return evs.filter(e => e && !seen.has(e.id) && seen.add(e.id))
}

// ---- Reading and fetching ----

/** The user's own events the lists draw from, from Haven's outbox. */
export async function readOwn(vault, me) {
  const evs = await vault.outbox.query({ kinds: [...NOTE_KINDS, 7, HIGHLIGHT_KIND, ARTICLE_KIND], authors: [me], limit: 500 })
  return dedupe(evs)
}

/** What Haven's inbox already holds for the user (others' events that tag them), or [] when it has nothing. */
export async function readInbound(vault, me) {
  if (!vault.inbox) return []
  return dedupe(await vault.inbox.query({ kinds: INBOUND_KINDS, "#p": [me], limit: 500 }).catch(() => []))
}

// 100 writes at a time, not one round trip after another (sync.js storeAll). -> each write's answer
async function storeEach(route, evs) {
  const out = []
  for (let i = 0; i < evs.length; i += 100) out.push(...await Promise.all(evs.slice(i, i + 100).map(ev => route.event(ev).catch(() => ({ ok: false })))))
  return out
}

/** Others' events that tag the user from the network, kept in Haven's inbox when it takes them. -> events */
export async function fetchInbound(vault, me, relays, { limit = 200, since, trust = async evs => evs } = {}) {
  // `trust` drops forged zap receipts (zaps.js trustedReceipts) before Haven keeps them.
  const evs = await trust(await pool.querySync(relays, { kinds: INBOUND_KINDS, "#p": [me], limit, ...(since ? { since } : {}) }, { maxWait: 8000 }))
  if (vault.inbox) await storeEach(vault.inbox, evs)
  return dedupe(evs)
}

/**
 * The user's own reactions and highlights from the network into Haven's outbox: Import Notes (sync.js syncOwn) only
 * brings notes and articles, and a like made on the phone never passes through this page. -> stored
 */
export async function fetchOwnExtras(vault, me, relays, { limit = 200 } = {}) {
  const evs = await pool.querySync(relays, { kinds: [7, HIGHLIGHT_KIND], authors: [me], limit }, { maxWait: 8000 })
  return (await storeEach(vault.outbox, evs)).filter(r => r.ok).length
}

/** Kind 3 lists naming the user, from the network. */
export async function fetchFollowerLists(me, relays, { limit = 500 } = {}) {
  return pool.querySync(relays, { kinds: [3], "#p": [me], limit }, { maxWait: 8000 })
}

/** Zap receipts whose request the user signed (NIP-57 `P` tag), from the network. Most receipts carry it. */
export async function fetchGivenZaps(me, relays, { limit = 100 } = {}) {
  return pool.querySync(relays, { kinds: [9735], "#P": [me], limit }, { maxWait: 8000 })
}

/**
 * The Vault's network round: inbound, follower lists, zaps given and the user's own likes and highlights, asked at
 * once. Each one is handed to `on` as it lands, so the list on screen draws from the first answer and never waits on
 * the slowest: checking zaps given resolves every payee's zap service, ~20 s for 60 payees. -> once all are done,
 * the first error, or null
 */
export async function fetchVault(vault, me, relays, { trust = async evs => evs, on = {}, fetchers = {} } = {}) {
  const f = { fetchInbound, fetchFollowerLists, fetchGivenZaps, fetchOwnExtras, ...fetchers }
  const each = (p, apply = () => {}) => p.then(apply)
  const results = await Promise.allSettled([
    each(f.fetchInbound(vault, me, relays, { trust }), on.inbound),
    each(f.fetchFollowerLists(me, relays).catch(() => []), on.lists),
    each(f.fetchGivenZaps(me, relays).then(trust).catch(() => []), on.given),
    each(f.fetchOwnExtras(vault, me, relays).catch(() => 0), on.own),
  ])
  return results.find(r => r.status === "rejected")?.reason ?? null
}

export { replyTarget }
