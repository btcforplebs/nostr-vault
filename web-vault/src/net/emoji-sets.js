// Custom emoji sets (NIP-30 + NIP-51), the web half of RESEARCH/NV_CUSTOM_EMOJI_PLAN.md §4.4: your emoji list
// (kind 10030) names sets (kind 30030) by their address in `a` tags; a set holds `["emoji", shortcode, url]` tags.
// Loose `emoji` tags in a 10030 are left alone and never listed (Logen's pick 6). Adding or removing a set rewrites the
// 10030 through list-edit.js publishList (newest copy anywhere first, every other tag kept). Adding a set also sends its
// author's own signed 30030 to your relays and keeps it in this browser's vault, so the set outlives its author's
// relays. The web makes no image copies: those need a mesh-key emoji note on /files, which the web never writes
// (Logen 2026-11-12; Tod 2026-11-13 13:24Z), so Save copies and zip import live in the apps.
import { verifyEvent } from "nostr-tools/pure"
import { decode, naddrEncode } from "nostr-tools/nip19"
import { pool, publishRelays, uniq, DEFAULT_RELAYS } from "./pool.js"
import { publishList, latestList } from "./list-edit.js"
import { MAX_SKEW } from "./follows.js"

export const EMOJI_LIST_KIND = 10030
export const EMOJI_SET_KIND = 30030
/** Sets the Emoji page reads from your list (the apps read 20 for the picker; the page reads more, plan §4.2). */
export const SET_CAP = 100
/** Browse: how many sets each ask brings back, and how far back the global one looks (Amethyst's numbers). */
export const BROWSE_LIMIT = 200
export const BROWSE_SINCE = 30 * 86400
/** Follows asked per browse filter, so one REQ stays a size relays take. */
export const AUTHORS_PER_ASK = 500

const HEX64 = /^[0-9a-f]{64}$/
/** NIP-30: letters, digits and underscores; hyphens are common in the wild and taken too. */
const SHORTCODE = /^[A-Za-z0-9_-]+$/
export const isShortcode = s => typeof s === "string" && SHORTCODE.test(s)
const now = () => Math.floor(Date.now() / 1000)

/** An https link worth showing as an emoji (no other scheme: a set is public, and so is anything it names). */
export function httpsUrl(raw) {
  if (typeof raw !== "string" || !/^https:\/\//i.test(raw.trim())) return null
  try { return new URL(raw.trim()).href } catch { return null }
}

/** "30030:<pubkey>:<d>" -> { kind, pubkey, d } | null. Only emoji sets. The d may hold colons. */
export function parseAddress(a) {
  const m = /^(\d+):([0-9a-f]{64}):(.*)$/s.exec(String(a ?? ""))
  if (!m || Number(m[1]) !== EMOJI_SET_KIND) return null
  return { kind: EMOJI_SET_KIND, pubkey: m[2], d: m[3] }
}
export const addressOf = ev => `${EMOJI_SET_KIND}:${ev.pubkey}:${(ev.tags ?? []).find(t => t[0] === "d")?.[1] ?? ""}`

/** The set as the page shows it, or null for anything that isn't a 30030. Emoji: valid shortcode and https link, the
 *  first one per shortcode (a set that names a code twice shows it once). */
export function parseEmojiSet(ev) {
  if (ev?.kind !== EMOJI_SET_KIND || !HEX64.test(ev.pubkey ?? "") || !Array.isArray(ev.tags)) return null
  const tag = n => ev.tags.find(t => Array.isArray(t) && t[0] === n && typeof t[1] === "string")?.[1]
  const d = tag("d") ?? ""
  const emoji = []
  const seen = new Set()
  for (const t of ev.tags) {
    if (!Array.isArray(t) || t[0] !== "emoji" || !isShortcode(t[1]) || seen.has(t[1])) continue
    const url = httpsUrl(t[2])
    if (!url) continue
    seen.add(t[1])
    emoji.push({ code: t[1], url })
  }
  return {
    address: `${EMOJI_SET_KIND}:${ev.pubkey}:${d}`, author: ev.pubkey, d, createdAt: ev.created_at ?? 0,
    title: (tag("title") || tag("name") || d || "Emoji set").trim(), description: tag("description") ?? "", image: httpsUrl(tag("image")),
    emoji, event: ev,
  }
}

/** The sets your 10030 names, in its order, each once, SET_CAP at most. Loose emoji tags are not sets. */
export function listedSets(list) {
  return uniq((list?.tags ?? []).filter(t => t[0] === "a" && parseAddress(t[1])).map(t => t[1])).slice(0, SET_CAP)
}
/** The 10030's tags with `address` added at the end (once), every other tag kept as it was. */
export function withSet(tags, address) {
  const all = tags ?? []
  return all.some(t => t[0] === "a" && t[1] === address) ? all : [...all, ["a", address]]
}
/** The 10030's tags without `address`; loose emoji and anything else stay. */
export const withoutSet = (tags, address) => (tags ?? []).filter(t => !(t[0] === "a" && t[1] === address))

/** A pasted set link: naddr1…, nostr:naddr1… or a bare "30030:<pubkey>:<d>". -> { address, relays } | null */
export function decodeSetLink(text) {
  const s = String(text ?? "").trim().replace(/^nostr:/i, "")
  if (parseAddress(s)) return { address: s, relays: [] }
  if (!/^naddr1/i.test(s)) return null
  try {
    const { type, data } = decode(s.toLowerCase())
    if (type !== "naddr" || data.kind !== EMOJI_SET_KIND || !HEX64.test(data.pubkey)) return null
    return { address: `${EMOJI_SET_KIND}:${data.pubkey}:${data.identifier}`, relays: (data.relays ?? []).filter(r => /^wss:\/\//.test(r)) }
  } catch { return null }
}
export const setLink = set => naddrEncode({ kind: EMOJI_SET_KIND, pubkey: set.author, identifier: set.d })

const verified = ({ id, pubkey, created_at, kind, tags, content, sig }) => {
  try { return verifyEvent({ id, pubkey, created_at, kind, tags, content, sig }) } catch { return false }
}
const nip01 = ({ id, pubkey, created_at, kind, tags, content, sig }) => ({ id, pubkey, created_at, kind, tags, content, sig })

/** Newest signed copy per address, among `events`, for the `addresses` asked (a relay may send others). */
export function newestByAddress(events, addresses, at = now()) {
  const want = new Set(addresses)
  const out = new Map()
  for (const ev of events) {
    if (ev?.kind !== EMOJI_SET_KIND || ev.created_at >= at + MAX_SKEW) continue
    const a = addressOf(ev)
    if (!want.has(a)) continue
    const have = out.get(a)
    if (!have || ev.created_at > have.created_at || (ev.created_at === have.created_at && ev.id < have.id)) out.set(a, ev)
  }
  return out
}

/** One filter per author, the sets' d tags together. */
export function setFilters(addresses) {
  const byAuthor = new Map()
  for (const a of addresses) {
    const p = parseAddress(a)
    if (p) byAuthor.set(p.pubkey, [...(byAuthor.get(p.pubkey) ?? []), p.d])
  }
  return [...byAuthor].map(([pk, ds]) => ({ kinds: [EMOJI_SET_KIND], authors: [pk], "#d": uniq(ds) }))
}

/** Where sets are read: your relays, the defaults, and any the link named. */
export const setRelays = (ctx, extra = []) => uniq([...extra, ...ctx.account.relays.read, ...ctx.account.relays.write, ...DEFAULT_RELAYS])

/**
 * The sets at `addresses`: this browser's vault first (copies kept on Add, so a set its author's relays lost still
 * shows), then the relays. A newer copy from the relays is kept in the vault too, unless `keep` is false (a pasted
 * link only opens the set: it is kept on Add, Tron PR 2023 S2). -> Map address -> parsed set.
 * `query` and `vault` are for tests.
 */
export async function fetchSets(ctx, addresses, { relays = setRelays(ctx), query = (r, f, o) => pool.querySync(r, f, o), maxWait = 6000, keep = true } = {}) {
  const filters = setFilters(addresses)
  if (!filters.length) return new Map()
  const local = (await Promise.all(filters.map(f => ctx.vault.outbox.query(f).catch(() => [])))).flat()
  const net = (await Promise.all(filters.map(f => query(relays, f, { maxWait }).catch(() => [])))).flat().filter(verified)
  const best = newestByAddress([...local, ...net], addresses)
  const kept = new Set(local.map(e => e.id))
  if (keep) await Promise.all([...best.values()].filter(ev => !kept.has(ev.id)).map(ev => ctx.vault.outbox.event(nip01(ev)).catch(() => {})))
  return new Map([...best].map(([a, ev]) => [a, parseEmojiSet(ev)]).filter(([, s]) => s))
}

/** Browse asks: your follows' sets first, then everyone's from the last month (Amethyst FilterBrowseEmojiSets*). */
export function browseFilters(follows, at = now()) {
  const people = uniq(follows ?? []).filter(pk => HEX64.test(pk))
  const byFollows = []
  for (let i = 0; i < people.length; i += AUTHORS_PER_ASK)
    byFollows.push({ kinds: [EMOJI_SET_KIND], authors: people.slice(i, i + AUTHORS_PER_ASK), limit: BROWSE_LIMIT })
  return { byFollows, global: { kinds: [EMOJI_SET_KIND], limit: BROWSE_LIMIT, since: at - BROWSE_SINCE } }
}

/** Browse results: newest copy per set, sets with no emoji and authors you blocked left out; your follows' sets first,
 *  then newest first. `follows` is a Set. */
export function browseList(events, { follows = new Set(), blocked = new Set(), at = now() } = {}) {
  const best = new Map()
  for (const ev of events) {
    if (ev?.kind !== EMOJI_SET_KIND || ev.created_at >= at + MAX_SKEW || blocked.has(ev.pubkey)) continue
    const a = addressOf(ev)
    const have = best.get(a)
    if (!have || ev.created_at > have.created_at) best.set(a, ev)
  }
  return [...best.values()].map(parseEmojiSet).filter(s => s && s.emoji.length)
    .sort((x, y) => (follows.has(y.author) - follows.has(x.author)) || y.createdAt - x.createdAt)
}

/** Browse: follows first, then global. `query` is for tests. -> [parsed set] */
export async function browseSets(ctx, { blocked = new Set(), query = (r, f, o) => pool.querySync(r, f, o), at = now() } = {}) {
  const relays = setRelays(ctx)
  const { byFollows, global } = browseFilters(ctx.account.follows, at)
  const asks = [...byFollows, global].map(f => query(relays, f, { maxWait: 6000 }).catch(() => []))
  const events = (await Promise.all(asks)).flat().filter(verified)
  return browseList(events, { follows: new Set(ctx.account.follows ?? []), blocked, at })
}

/** Your newest 10030 (list-edit.js latestList: your relays must answer before it may be edited). */
export const readEmojiList = (ctx, opts) => latestList(ctx, EMOJI_LIST_KIND, opts)

/**
 * Add or remove a set: the 10030 signed again with one `a` tag more or less, starting from `previous` (the copy the
 * page shows; publishList refuses when a newer one turned up). On add, the set's own event goes to your relays and into
 * this browser's vault (keepSet). -> { event, relays, kept? }; throws as publishList does.
 */
export async function changeSet(ctx, { set, add, previous }, { publish = publishList, keep = keepSet } = {}) {
  const tags = add ? withSet(previous?.tags, set.address) : withoutSet(previous?.tags, set.address)
  const out = await publish(ctx, EMOJI_LIST_KIND, tags, { previous })
  if (!add) return out
  return { ...out, kept: await keep(ctx, set.event).catch(e => ({ error: String(e?.message ?? e) })) }
}

/**
 * Someone's set, as they signed it, sent to your write relays and kept in this browser's vault: nothing is signed or
 * changed. -> { sent, of, vault: "" | why the vault didn't take it }. `send` is for tests.
 */
export async function keepSet(ctx, ev, { send = (urls, e) => pool.publish(urls, e) } = {}) {
  if (ev?.kind !== EMOJI_SET_KIND || !verified(ev)) throw new Error("That set's signature doesn't check out, so it wasn't sent.")
  const event = nip01(ev)
  const { network } = publishRelays(ctx.account.relays.write)
  const urls = uniq([...network])
  const results = urls.length ? await Promise.allSettled(send(urls, event)) : []
  const sent = results.filter(r => r.status === "fulfilled").length
  const r = await ctx.vault.outbox.event(event).catch(e => ({ ok: false, message: String(e?.message ?? e) }))
  const vault = r?.ok || /^duplicate:/.test(r?.message ?? "") ? "" : (r?.message || "your vault didn't take it")
  return { sent, of: urls.length, vault }
}

