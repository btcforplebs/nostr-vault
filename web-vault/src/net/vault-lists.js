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
  // `followedAt`: when this browser first saw them follow (mergeLists), kept when they later edit their list.
  return [...newest.values()].filter(ev => tagsMe(ev, me) && !blocked.has(ev.pubkey)).map(ev => ({ pubkey: ev.pubkey, at: followedAtOf(ev) ?? ev.created_at })).sort((a, b) => b.at - a.at)
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

/** Events per read of Haven's stores. A full page means older ones may be left: readOlder asks for them. */
export const READ_PAGE = 500

const untilOf = until => until ? { until } : {}
const sinceOf = since => since ? { since } : {}

/** The user's own events the lists draw from, from Haven's outbox: the newest page, or the page before `until`. */
export async function readOwn(vault, me, { until, limit = READ_PAGE } = {}) {
  const evs = await vault.outbox.query({ kinds: [...NOTE_KINDS, 7, HIGHLIGHT_KIND, ARTICLE_KIND], authors: [me], limit, ...untilOf(until) })
  return dedupe(evs)
}

/** What Haven's inbox already holds for the user (others' events that tag them), or [] when it has nothing. */
export async function readInbound(vault, me, { until, limit = READ_PAGE } = {}) {
  if (!vault.inbox) return []
  return dedupe(await vault.inbox.query({ kinds: INBOUND_KINDS, "#p": [me], limit, ...untilOf(until) }).catch(() => []))
}

/**
 * The page of the user's own events and inbox before the oldest of each already read (the phone's loadMore, which
 * pages its vault and inbox with `until`). `more` says which store may still hold older ones; a store whose last
 * read came back short is done. Events on the cursor's second are read again and dropped by id, so none is skipped.
 * -> { own, inbound, more: { own, inbound } }
 */
export async function readOlder(vault, me, { own, inbound, more = { own: true, inbound: true }, limit = READ_PAGE }) {
  const page = async (on, read, list) => {
    if (!on || !list.length) return { evs: [], more: false }
    const until = list.reduce((m, e) => Math.min(m, e.created_at), Infinity)
    const evs = await read(vault, me, { until, limit }).catch(() => [])
    const have = new Set(list.map(e => e.id))
    const fresh = evs.filter(e => !have.has(e.id))
    return { evs: fresh, more: evs.length >= limit && fresh.length > 0 }
  }
  const [o, i] = await Promise.all([page(more.own, readOwn, own), page(more.inbound, readInbound, inbound)])
  return { own: o.evs, inbound: i.evs, more: { own: o.more, inbound: i.more } }
}

// 100 writes at a time, not one round trip after another (sync.js storeAll). -> each write's answer
async function storeEach(route, evs) {
  const out = []
  for (let i = 0; i < evs.length; i += 100) out.push(...await Promise.all(evs.slice(i, i + 100).map(ev => route.event(ev).catch(() => ({ ok: false })))))
  return out
}

/**
 * Asks each relay on its own and hands each answer to `on` as it lands, so one slow relay never holds the list
 * back (one querySync over all of them waited ~8.5 s for the slowest). An event a faster relay already handed on is
 * dropped by id. Rejects only when every relay failed. -> every event handed on, once all have answered
 */
export async function eachRelay(relays, filter, on = () => {}, { maxWait = 8000, query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const seen = new Set(), all = [], urls = uniq(relays)
  let failed = 0, last
  await Promise.all(urls.map(async url => {
    let evs
    try { evs = await query([url], filter, { maxWait }) } catch (e) { failed++; last = e; return }
    const fresh = evs.filter(e => e && !seen.has(e.id) && seen.add(e.id))
    if (!fresh.length) return
    all.push(...fresh)
    await on(fresh)
  }))
  if (urls.length && failed === urls.length) throw last
  return all
}

const isZap = e => e.kind === 9735

/**
 * Others' events that tag the user from the network, kept in Haven's inbox. Each relay's answer is handed to `on`
 * as it lands; its zap receipts follow once `trust` has checked them (zaps.js trustedReceipts: it resolves the zap
 * service), so a forged one is never drawn or kept. A receipt that can't be checked now is drawn, not kept: the
 * screen checks it again. -> events
 */
export async function fetchInbound(vault, me, relays, { limit = 200, since, trust = async evs => evs, on = () => {}, query } = {}) {
  const keep = evs => vault.inbox ? storeEach(vault.inbox, evs) : null
  const evs = await eachRelay(relays, { kinds: INBOUND_KINDS, "#p": [me], limit, ...sinceOf(since) }, async fresh => {
    const rest = fresh.filter(e => !isZap(e)), zaps = fresh.filter(isZap)
    if (rest.length) { on(rest); await keep(rest) }
    if (!zaps.length) return
    const checked = await trust(zaps).then(ok => ({ ok, sure: true }), () => ({ ok: zaps, sure: false }))
    if (checked.ok.length) { on(checked.ok); if (checked.sure) await keep(checked.ok) }
  }, { query })
  return dedupe(evs)
}

/**
 * The user's own reactions and highlights from the network into Haven's outbox: Import Notes (sync.js syncOwn) only
 * brings notes and articles, and a like made on the phone never passes through this page. -> stored
 */
export async function fetchOwnExtras(vault, me, relays, { limit = 200, since } = {}) {
  const evs = await pool.querySync(relays, { kinds: [7, HIGHLIGHT_KIND], authors: [me], limit, ...sinceOf(since) }, { maxWait: 8000 })
  return (await storeEach(vault.outbox, evs)).filter(r => r.ok).length
}

/** Kind 3 lists naming the user, from the network, each relay's handed to `on` as it lands (compactLists). */
export async function fetchFollowerLists(me, relays, { limit = 500, since, on = () => {}, query } = {}) {
  // `followedAt` is this browser's own note (mergeLists): a relay can add any key to an event's JSON, and the
  // signature does not cover it.
  return eachRelay(relays, { kinds: [3], "#p": [me], limit, ...sinceOf(since) }, evs => on(compactLists(evs.map(({ followedAt, ...ev }) => ev), me)), { query })
}

/** Zap receipts whose request the user signed (NIP-57 `P` tag), from the network, each relay's handed to `on` once
 *  `trust` has checked it. Most receipts carry the tag. */
export async function fetchGivenZaps(me, relays, { limit = 100, since, trust = async evs => evs, on = () => {}, query } = {}) {
  return eachRelay(relays, { kinds: [9735], "#P": [me], limit, ...sinceOf(since) }, async evs => {
    const ok = await trust(evs).catch(() => [])
    if (ok.length) on(ok)
  }, { query })
}

/**
 * The Vault's network round: inbound, follower lists, zaps given and the user's own likes and highlights, asked at
 * once, every relay on its own. Each answer is handed to `on` as it lands (`on.inbound`, `on.lists` and `on.given`
 * may be called once per relay), so the list on screen draws from the first answer and never waits on the slowest:
 * checking zaps given resolves every payee's zap service, ~20 s for 60 payees. `on.own` is called once, after the
 * user's own likes and highlights are in Haven. `since` asks only for what came after it. -> once all are done,
 * the first error, or null
 */
export async function fetchVault(vault, me, relays, { trust = async evs => evs, on = {}, fetchers = {}, since } = {}) {
  const f = { fetchInbound, fetchFollowerLists, fetchGivenZaps, fetchOwnExtras, ...fetchers }
  const hand = cb => evs => { if (evs?.length) cb?.(evs) }
  const results = await Promise.allSettled([
    f.fetchInbound(vault, me, relays, { trust, since, on: hand(on.inbound) }),
    f.fetchFollowerLists(me, relays, { since, on: hand(on.lists) }).catch(() => []),
    f.fetchGivenZaps(me, relays, { since, trust, on: hand(on.given) }).catch(() => []),
    f.fetchOwnExtras(vault, me, relays, { since }).catch(() => 0).then(n => on.own?.(n)),
  ])
  return results.find(r => r.status === "rejected")?.reason ?? null
}

// ---- Follower lists kept in this browser ----

/**
 * Kind 3 lists cut down to what Followers needs: each author's newest, with only a `p` tag for the user when it
 * still names them. A full list is ~50 KB and a big account has 1,000s of followers; the cut one is ~150 bytes,
 * small enough to keep between visits (keepLists) and to hand the screen.
 */
export function compactLists(lists, me) {
  const newest = new Map()
  for (const ev of lists) {
    if (!ev || ev.kind !== 3 || !HEX64.test(ev.pubkey ?? "") || !Array.isArray(ev.tags)) continue
    const cur = newest.get(ev.pubkey)
    if (!cur || ev.created_at > cur.created_at) newest.set(ev.pubkey, ev)
  }
  return [...newest.values()].map(ev => ({ id: ev.id, kind: 3, pubkey: ev.pubkey, created_at: ev.created_at, tags: tagsMe(ev, me) ? [["p", me]] : [], ...(followedAtOf(ev) ? { followedAt: ev.followedAt } : {}) }))
}
// A kept follow time can only be a whole second no later than the list it is kept on.
const followedAtOf = ev => Number.isInteger(ev.followedAt) && ev.followedAt > 0 && ev.followedAt <= ev.created_at ? ev.followedAt : undefined

/**
 * Newer follower lists over the ones held, per author. Someone who still follows the user keeps the time they were
 * first seen following (`followedAt`): editing their list for someone else is not a new follow, and must not move
 * their line to the top. -> compact lists
 */
export function mergeLists(prev, fresh, me) {
  const by = new Map(compactLists(prev, me).map(l => [l.pubkey, l]))
  for (const l of compactLists(fresh, me)) {
    const cur = by.get(l.pubkey)
    if (cur && cur.created_at >= l.created_at) continue
    by.set(l.pubkey, cur?.tags.length && l.tags.length ? { ...l, followedAt: followedAtOf(cur) ?? cur.created_at } : l)
  }
  return [...by.values()]
}

const LISTS = "nv-vault-follower-lists"
/** The follower lists this browser holds for `me` (compactLists), or [] when none or unreadable. */
export function readLists(me, storage = globalThis.localStorage) {
  try {
    const v = JSON.parse(storage?.getItem(`${LISTS}:${me}`) ?? "[]")
    return Array.isArray(v) ? compactLists(v, me) : []
  } catch { return [] }
}
/** Keeps the follower lists for the next visit. A full storage is not an error: the next visit asks the relays. */
export function keepLists(me, lists, storage = globalThis.localStorage) {
  try { storage?.setItem(`${LISTS}:${me}`, JSON.stringify(compactLists(lists, me))) } catch {}
}

// ---- What the screen draws ----

/** The rows the current mode and filter show, newest first: built once per change of what they're built from. */
export function itemsFor(mode, filter, { own = [], inbound = [], given = [], followers = [], me, blocked = new Set(), seenAt = 0 }) {
  switch (mode) {
    case "activity": return activityRows(inbound, me, { mine: own, follows: followers, blocked }).filter(r => activityFilter(r, filter))
    case "notes": return notesFor(own, inbound, me, filter, blocked)
    case "articles": return articlesFor(own, inbound, me, filter, blocked)
    case "highlights": return highlightsFor(own, inbound, me, filter, blocked)
    case "media": return filter === "notes" ? mediaFor(own) : []
    case "likes": return likesFor(own, inbound, me, filter, blocked)
    case "zaps": return zapsFor(given, inbound, me, filter, blocked)
    case "followers": return followersFilter(followers, filter, seenAt)
    default: return []
  }
}

/** Whose names a mode's rows show, in row order (the first two of a folded line, as Who draws them). */
export function peopleOf(mode, rows) {
  const out = []
  for (const r of rows) {
    if (mode === "activity") out.push(...r.actors.slice(0, 2))
    else if (mode === "likes" || mode === "zaps") out.push(...r.who.slice(0, 2), ...(r.to ? [r.to] : []))
    else if (mode === "followers") out.push(r.pubkey)
    else if (r.pubkey) out.push(r.pubkey)
  }
  return uniq(out.filter(pk => HEX64.test(pk ?? "")))
}

/** The newest moment a list on screen shows: inbound events and the follows among `lists`. 0 when it shows none. */
export function newestShown(inbound, lists = []) {
  let top = 0
  for (const e of inbound) if (e.created_at > top) top = e.created_at
  for (const l of lists) { const at = followedAtOf(l) ?? l.created_at; if (l.tags?.length && at > top) top = at }
  return top
}

/**
 * A network answer, split into what goes into the list now and what waits behind the "N new" pill, so the rows on
 * screen never move under the reader. Held: what is newer than `top` (newestShown when the list was drawn) and
 * would draw a line of its own, or move one up: an inbound event that makes a Vault row, a follower list from
 * someone who wasn't following. Older answers fill in below. `top` 0: nothing drawn yet, all goes in.
 * -> { now, later }
 */
export function splitArrivals(kind, fresh, { top, me, own = [], lists = [], blocked = new Set() }) {
  if (!top) return { now: fresh, later: [] }
  if (kind === "lists") {
    const following = new Set(followersOf(lists, me).map(f => f.pubkey))
    const isNew = l => l.tags?.length && l.created_at > top && !following.has(l.pubkey) && !blocked.has(l.pubkey)
    return { now: fresh.filter(l => !isNew(l)), later: fresh.filter(isNew) }
  }
  const later = fresh.filter(e => e.created_at > top)
  if (!later.length || !activityRows(later, me, { mine: own, blocked }).length) return { now: fresh, later: [] }
  return { now: fresh.filter(e => e.created_at <= top), later }
}

/** How many Vault lines the held answers would add, for the pill. */
export const heldCount = (held, me, own, blocked = new Set()) =>
  activityRows(held.inbound, me, { mine: own, follows: followersOf(held.lists, me, blocked), blocked }).length

// ---- Coming back to the tab ----

/** The Vault tab as it was left, per account, for as long as this page lives: the phone keeps VaultTabView alive
 *  between tabs, so its list, mode, filter and scroll are where they were. A reload starts fresh. */
const kept = new Map()
export const keepVault = (me, state) => { kept.set(me, { ...state, at: Math.floor(Date.now() / 1000) }) }
export const keptVault = me => kept.get(me) ?? null
/** Where to ask the relays from when coming back: a minute before the tab was left, for relays' clocks and late
 *  arrivals. Ids already held are merged away. */
export const sinceKept = k => k?.at ? Math.max(0, k.at - 60) : undefined

export { replyTarget }
