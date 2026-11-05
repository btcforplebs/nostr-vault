// "Sell something": a NIP-99 classified listing (kind 30402), as the iPhone's Sell composer writes it
// (Models/ListingDraft.swift, Views/MarketplaceSellView.swift). There's no checkout here: buyers find the listing in
// Marketplace, on Shopstr or on Plebeian, and arrange payment with the seller. Pure, so tests can pin the tags; a
// listing published here reads back through market.js parseListing exactly as it was entered.
import { CATEGORIES, CLASSIFIED } from "./market.js"

export const LISTING_KIND = CLASSIFIED
/** Currencies offered: "SATS" is what Shopstr and Plebeian write for bitcoin prices; the rest are ISO 4217. */
export const CURRENCIES = ["SATS", "USD", "EUR", "CAD", "GBP"]
/** The categories offered, as the grid files them (MarketCategory); "Other" means none. */
export const LISTING_CATEGORIES = CATEGORIES
export const MAX_PHOTOS = 8

export const EMPTY_LISTING = Object.freeze({ title: "", summary: "", description: "", price: "", currency: "SATS", category: "Other", location: "", photos: [] })
const TEXT = ["title", "summary", "description", "price", "location"]
const trim = s => String(s ?? "").trim()

/** Digits and at most one decimal point, grouping commas dropped; null when it isn't a price. */
export function normalizedPrice(price) {
  const p = trim(price).replace(/,/g, "")
  return p && !p.startsWith("-") && /^\d*\.?\d+$|^\d+\.$/.test(p) && Number.isFinite(Number(p)) ? p : null
}

/** The photos that are up, in order: the first is the cover in the grid. */
export const uploaded = l => (l.photos ?? []).filter(p => p.status === "done" && p.url)

/** What "List it" needs: a title, a price and at least one photo up (the grid hides a listing without them). */
export const canPublishListing = l => !!trim(l.title) && normalizedPrice(l.price) != null && uploaded(l).length > 0
export const hasListing = l => TEXT.some(f => trim(l[f])) || (l.photos ?? []).length > 0 || l.category !== "Other"

/** Why "List it" is off, once something is written; a fresh form says nothing. */
export function listingHint(l, { uploading = false } = {}) {
  if (canPublishListing(l) || !hasListing(l) || uploading) return null
  if (!uploaded(l).length) return "Add at least one photo to list it."
  if (!trim(l.title)) return "Say what you're selling to list it."
  return "Add a price to list it."
}

/** -> { content, tags } for the kind 30402: ListingDraft.tags in its order. `d`, `publishedAt` for tests. */
export function buildListing(l, { d = crypto.randomUUID().toLowerCase(), publishedAt = Math.floor(Date.now() / 1000) } = {}) {
  const tags = [["d", d], ["title", trim(l.title)]]
  if (trim(l.summary)) tags.push(["summary", trim(l.summary)])
  tags.push(["published_at", String(publishedAt)])
  const price = normalizedPrice(l.price)
  if (price != null) tags.push(["price", price, CURRENCIES.includes(l.currency) ? l.currency : "SATS"])
  if (trim(l.location)) tags.push(["location", trim(l.location)])
  for (const p of uploaded(l)) tags.push(["image", p.url])
  // Shopstr and MyNostrSpace file listings by these names, and market.js classify reads them back to the same one.
  if (l.category && l.category !== "Other" && LISTING_CATEGORIES.includes(l.category)) tags.push(["t", l.category])
  tags.push(["status", "active"])
  return { content: trim(l.description), tags }
}

/** What a draft keeps: the fields, and the photos that are up (one still uploading has nothing behind it later). */
export const listingDraftOf = l => ({ ...Object.fromEntries(TEXT.map(f => [f, l[f] ?? ""])), currency: l.currency, category: l.category,
  photos: uploaded(l).map(({ url, sha256, mime, size }) => ({ url, sha256, mime, size })) })
export function listingFromDraft(d) {
  return { ...EMPTY_LISTING, ...Object.fromEntries(TEXT.map(f => [f, typeof d?.[f] === "string" ? d[f] : ""])),
    currency: CURRENCIES.includes(d?.currency) ? d.currency : "SATS",
    category: LISTING_CATEGORIES.includes(d?.category) ? d.category : "Other",
    photos: (Array.isArray(d?.photos) ? d.photos : []).filter(p => typeof p?.url === "string").slice(0, MAX_PHOTOS)
      .map((p, i) => ({ ...p, id: `kept-${i}`, preview: p.url, status: "done" })) }
}
