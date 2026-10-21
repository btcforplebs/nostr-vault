// The Marketplace feed, ported from the iPhone's MarketplaceFeedService, MarketListing, MarketCategory and
// MarketListingBook (Models/MarketListing.swift): NIP-15 products and auctions (30018, 30020) and NIP-99 classifieds
// (30402). Sellers are mostly strangers, so nothing is written to Haven; buying hands off to Plebeian Market.
import { pool } from "../net/pool.js"
import { globalTrust, trustedFilters } from "./trust.js"

export const PRODUCT = 30018, AUCTION = 30020, CLASSIFIED = 30402
export const MARKET_KINDS = [PRODUCT, AUCTION, CLASSIFIED]
/** Where listings live (MarketplaceFeedService.relayStrings): the owner's feed relays rarely carry any. */
export const MARKET_RELAYS = ["wss://relay.damus.io", "wss://relay.snort.social", "wss://relay.nostr.net", "wss://nostr.wine",
  "wss://relay.primal.net", "wss://relay.conduit.market"]
/** Global by default, unlike Recipes: almost nobody's follows sell anything. */
export const MARKET_SCOPES = [{ id: "global", label: "Global" }, { id: "following", label: "Following" }]
const KEY = "nv-market-scope"

export function loadScope(storage = globalThis.localStorage) {
  const s = storage?.getItem(KEY)
  return MARKET_SCOPES.some(x => x.id === s) ? s : "global"
}
export const saveScope = (s, storage = globalThis.localStorage) => storage?.setItem(KEY, s)

// MarketCategory: first rule whose keyword is in a topic, or is a word (or two-word phrase) of title + summary.
export const CATEGORIES = ["Bitcoin", "Art", "Clothing", "Food & Drink", "Home & Technology", "Health & Beauty", "Sports & Outside",
  "Services", "Books", "Pets", "Collectibles", "Entertainment", "Accessories", "Shoes", "Digital", "Physical", "Resale", "Exchange", "Other"]
const RULES = [
  ["Bitcoin", ["bitcoin", "btc", "sats", "crypto", "miner", "asic", "hardware wallet", "signing device"]],
  ["Art", ["art", "print", "painting", "drawing", "sculpture", "nft", "poster"]],
  ["Shoes", ["shoe", "shoes", "sneaker", "sneakers", "boot", "boots", "sandal", "sandals"]],
  ["Clothing", ["clothing", "shirt", "t-shirt", "hat", "hoodie", "apparel", "fashion", "wear"]],
  ["Food & Drink", ["food", "drink", "coffee", "tea", "beef", "meat", "steak", "wine", "beer"]],
  ["Home & Technology", ["technology", "tech", "electronics", "computer", "phone", "gadget", "software", "hardware", "home"]],
  ["Health & Beauty", ["health", "beauty", "soap", "cosmetic", "supplement", "vitamin", "skin"]],
  ["Sports & Outside", ["sports", "outside", "outdoor", "camping", "hiking", "gear"]],
  ["Services", ["service", "freelance", "job", "consulting", "design"]],
  ["Books", ["book", "books", "ebook", "reading", "novel", "magazine"]],
  ["Pets", ["pet", "pets", "dog", "cat", "animal"]],
  ["Collectibles", ["collectible", "rare", "vintage", "antique", "coin", "coins"]],
  ["Entertainment", ["entertainment", "movie", "film", "music", "game", "toy"]],
  ["Accessories", ["accessory", "accessories", "jewelry", "bag", "wallet", "watch"]],
  ["Digital", ["digital", "code", "license"]],
  ["Physical", ["physical"]],
  ["Resale", ["resale", "used", "secondhand"]],
  ["Exchange", ["exchange", "swap", "trade"]],
]

export function classify(topics, text) {
  const lowTopics = topics.map(t => String(t).toLowerCase())
  const low = String(text).toLowerCase()
  const words = new Set(low.split(/[^\p{L}\p{N}-]+/u).filter(Boolean))
  const padded = ` ${low} `
  for (const [cat, keys] of RULES) for (const k of keys) {
    if (lowTopics.some(t => t.includes(k))) return cat
    if (k.includes(" ") ? padded.includes(` ${k} `) : words.has(k)) return cat
  }
  return "Other"
}

const SAT_UNITS = new Set(["SAT", "SATS", "SATOSHI", "SATOSHIS"])
const amount = v => {
  if (typeof v === "string") return v.trim() || null
  if (typeof v === "number" && Number.isFinite(v)) return String(v) // JS writes 21000 without ".0", as the iPhone does
  return null
}
/** Stock of 0 (or less) is as unbuyable as sold; `null` means no limit. */
export function isOutOfStock(raw) {
  if (typeof raw === "number") return raw <= 0
  if (typeof raw === "string" && raw.trim() !== "" && Number.isFinite(Number(raw))) return Number(raw) <= 0
  return false
}
const http = s => { try { const u = new URL(String(s).trim()); return /^https?:$/.test(u.protocol) ? u.href : null } catch { return null } }

/** A listing, or null when it isn't one the grid shows: no title or image, "Untitled Product", sold, out of stock,
 *  or hidden. NIP-15 and Conduit put everything in JSON content; NIP-99 uses tags with a markdown body. */
export function parseListing(ev) {
  if (!ev || !MARKET_KINDS.includes(ev.kind)) return null
  const tags = Array.isArray(ev.tags) ? ev.tags : []
  const tag = n => tags.find(t => t.length >= 2 && t[0] === n)
  const val = n => { const v = tag(n)?.[1]; return typeof v === "string" && v.trim() ? v.trim() : null }
  let title = "", summary = "", images = [], price = "", currency = "", json = false, quantity
  let j = null
  try { j = JSON.parse(ev.content) } catch {}
  if (j && typeof j === "object" && !Array.isArray(j)) {
    json = true
    title = (typeof j.name === "string" ? j.name : typeof j.title === "string" ? j.title : "") || ""
    summary = (typeof j.description === "string" ? j.description : typeof j.summary === "string" ? j.summary : "") || ""
    images = Array.isArray(j.images) ? j.images.map(i => (typeof i === "string" ? i : i?.url)).filter(s => typeof s === "string") : []
    price = amount(j.price ?? j.starting_bid) ?? ""
    currency = typeof j.currency === "string" ? j.currency : ""
    quantity = j.quantity
  } else summary = String(ev.content ?? "")
  if (!title) title = val("title") ?? val("name") ?? ""
  if ((!json || !summary) && val("summary")) summary = val("summary")
  if (!images.length) images = tags.filter(t => t.length >= 2 && t[0] === "image").map(t => t[1])
  if (!price && tag("price")) { price = String(tag("price")[1]); if (!currency && tag("price").length >= 3) currency = String(tag("price")[2]) }
  title = title.trim()
  images = images.map(http).filter(Boolean)
  if (!title || title === "Untitled Product" || !images.length) return null
  if (val("status")?.toLowerCase() === "sold") return null
  if (isOutOfStock(quantity ?? val("quantity"))) return null
  if (val("visibility")?.toLowerCase() === "hidden") return null
  summary = summary.trim()
  return {
    id: ev.id, pubkey: ev.pubkey, kind: ev.kind, d: val("d"), title, summary, images, price: price || "?",
    currency: currency.trim().toUpperCase(), location: val("location"), createdAt: ev.created_at,
    category: classify(tags.filter(t => t.length >= 2 && t[0] === "t").map(t => t[1]), `${title} ${summary}`),
    isAuction: ev.kind === AUCTION,
  }
}

/** "21,000 sats" for a sat price (no unit means sats), else "25 USD". */
export function priceLabel({ price, currency }) {
  const unit = currency || "SATS"
  if (SAT_UNITS.has(unit)) return /^-?\d+$/.test(price) ? `${Number(price).toLocaleString("en-US")} sats` : `${price} sats`
  return `${price} ${unit}`
}

/** Where buying happens: Plebeian Market's product or auction page for the event. */
export const plebeianUrl = l => `https://plebeian.market/${l.isAuction ? "auction" : "products"}/${l.id}`

/** The newest event at each address wins, even one that no longer parses (sold, hidden, out of stock), which removes
 *  the listing; blocked sellers are left out. Newest first, ties by id. */
export function book(evs, blocked = new Set()) {
  const newest = new Map()
  for (const ev of evs) {
    if (!ev?.id || !MARKET_KINDS.includes(ev.kind) || blocked.has(ev.pubkey)) continue
    const d = ev.tags?.find(t => t.length >= 2 && t[0] === "d")?.[1]
    const addr = `${ev.kind}:${ev.pubkey}:${d ?? ev.id}`
    const have = newest.get(addr)
    if (!have || ev.created_at > have.created_at) newest.set(addr, ev)
  }
  return [...newest.values()].map(parseListing).filter(Boolean)
    .sort((a, b) => b.createdAt - a.createdAt || (a.id < b.id ? 1 : a.id > b.id ? -1 : 0))
}

/** The categories with a listing, in CATEGORIES order (Other last). */
export const marketCategories = listings => { const have = new Set(listings.map(l => l.category)); return CATEGORIES.filter(c => have.has(c)) }

export function marketFilter(scope, follows) {
  const f = { kinds: MARKET_KINDS, limit: 200 }
  if (scope !== "following") return f
  return follows.length ? { ...f, authors: follows } : null
}

export { trustedFilters, TRUSTED_AUTHORS_CAP } from "./trust.js"

/**
 * One load. Following: follows' listings. Global: sellers your web vouches for (you, your follows and the people they
 * follow, net/popular.js trustSet), as the iPhone's Global does; most of the open market is throwaway-key test posts.
 * With no web yet (no follows) Global fails closed. `query` and `trustOf` are for tests.
 * -> { listings, noWeb } or null when there was nothing to ask.
 */
export async function fetchListings({ scope, me, follows, blocked, query = (r, f, o) => pool.querySync(r, f, o), trustOf }) {
  const filter = marketFilter(scope, follows)
  if (!filter) return null
  let allowed = filter.authors && new Set(filter.authors), filters = [filter]
  if (scope !== "following") {
    allowed = await globalTrust(me, follows, trustOf)
    if (!allowed) return { listings: [], noWeb: true }
    filters = trustedFilters(filter, allowed)
  }
  const evs = (await Promise.all(filters.map(f => query(MARKET_RELAYS, f, { maxWait: 12000 })))).flat()
  return { listings: book(evs.filter(e => allowed.has(e?.pubkey)), blocked), noWeb: false }
}
