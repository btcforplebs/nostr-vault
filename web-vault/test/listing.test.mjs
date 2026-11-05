// Sell something (readers/listing.js): a NIP-99 classified (kind 30402) as the iPhone's ListingDraft writes it, read
// back through market.js parseListing as entered. Throwaway keys only; nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, finalizeEvent } from "nostr-tools/pure"
import { EMPTY_LISTING, CURRENCIES, LISTING_KIND, buildListing, canPublishListing, hasListing, listingHint, normalizedPrice,
  listingDraftOf, listingFromDraft } from "../src/readers/listing.js"
import { CATEGORIES, parseListing, priceLabel } from "../src/readers/market.js"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { composeType, COMPOSE_TYPES } = await import("../src/screens/compose/ComposeKinds.jsx")
await import("../src/screens/ComposeScreen.jsx") // the dispatcher, with the listing composer, still loads in node

const photo = n => ({ id: `p${n}`, status: "done", url: `https://media.example/${n}.jpg`, sha256: "a".repeat(64), mime: "image/jpeg", size: 1 })
const full = { ...EMPTY_LISTING, title: " Coldcard Mk4 ", summary: "Barely used", description: "Ships in the US.\nPay in sats.",
  price: "1,250,000", currency: "SATS", category: "Bitcoin", location: "Austin", photos: [photo(1), photo(2), { id: "p3", status: "uploading", preview: "blob:x" }] }

test("the tags are ListingDraft's, in its order; the description is the content", () => {
  const { content, tags } = buildListing(full, { d: "fixed-d", publishedAt: 1_800_000_000 })
  assert.equal(LISTING_KIND, 30402)
  assert.equal(content, "Ships in the US.\nPay in sats.")
  assert.deepEqual(tags, [
    ["d", "fixed-d"], ["title", "Coldcard Mk4"], ["summary", "Barely used"], ["published_at", "1800000000"],
    ["price", "1250000", "SATS"], ["location", "Austin"],
    ["image", "https://media.example/1.jpg"], ["image", "https://media.example/2.jpg"],
    ["t", "Bitcoin"], ["status", "active"],
  ])
  const bare = buildListing({ ...EMPTY_LISTING, title: "Mug", price: "5", currency: "USD", photos: [photo(9)] }, { d: "d2", publishedAt: 1 })
  assert.deepEqual(bare.tags.map(t => t[0]), ["d", "title", "published_at", "price", "image", "status"], "no summary, location or t when empty / None")
  assert.match(buildListing({ ...full }).tags[0][1], /^[0-9a-f-]{36}$/, "a fresh d per listing")
})

test("a listing published here reads back in the Marketplace grid as it was entered, every category included", () => {
  const sk = generateSecretKey()
  for (const category of CATEGORIES) {
    const l = { ...full, category, title: "Thing", summary: "", description: "plain" }
    const ev = finalizeEvent({ kind: LISTING_KIND, created_at: 1_800_000_000, ...buildListing(l, { d: `d-${category}` }) }, sk)
    const back = parseListing(ev)
    assert.ok(back, category)
    assert.equal(back.title, "Thing")
    assert.equal(back.category, category, category)
    assert.deepEqual(back.images, ["https://media.example/1.jpg", "https://media.example/2.jpg"])
    assert.equal(priceLabel(back), "1,250,000 sats")
    assert.equal(back.location, "Austin")
  }
  const usd = finalizeEvent({ kind: LISTING_KIND, created_at: 1, ...buildListing({ ...full, price: "45.00", currency: "USD" }, { d: "x" }) }, sk)
  assert.equal(priceLabel(parseListing(usd)), "45.00 USD")
})

test("List it needs a title, a price and a photo that is up; the hint says what's missing", () => {
  assert.equal(canPublishListing(full), true)
  assert.equal(canPublishListing({ ...full, title: "  " }), false)
  assert.equal(canPublishListing({ ...full, price: "abc" }), false)
  assert.equal(canPublishListing({ ...full, photos: [{ id: "x", status: "uploading" }] }), false)
  assert.equal(listingHint(EMPTY_LISTING), null, "a fresh form says nothing")
  assert.equal(listingHint({ ...EMPTY_LISTING, title: "x" }), "Add at least one photo to list it.")
  assert.equal(listingHint({ ...EMPTY_LISTING, photos: [photo(1)], price: "5" }), "Say what you're selling to list it.")
  assert.equal(listingHint({ ...EMPTY_LISTING, photos: [photo(1)], title: "x" }), "Add a price to list it.")
  assert.equal(listingHint({ ...EMPTY_LISTING, title: "x", photos: [{ id: "u", status: "uploading" }] }, { uploading: true }), null)
  for (const [p, want] of [["21000", "21000"], ["1,000.50", "1000.50"], ["0.5", "0.5"], ["-3", null], ["", null], ["1.2.3", null], ["abc", null]]) assert.equal(normalizedPrice(p), want, p)
  assert.deepEqual(CURRENCIES, ["SATS", "USD", "EUR", "CAD", "GBP"])
  assert.equal(hasListing(EMPTY_LISTING), false)
})

test("the draft keeps the fields and the photos that are up, not ones still uploading", () => {
  const d = listingDraftOf(full)
  assert.equal(d.photos.length, 2)
  assert.ok(!JSON.stringify(d).includes("blob:"))
  const back = listingFromDraft(JSON.parse(JSON.stringify(d)))
  assert.equal(back.title, full.title)
  assert.equal(back.category, "Bitcoin")
  assert.deepEqual(back.photos.map(p => [p.url, p.status]), [["https://media.example/1.jpg", "done"], ["https://media.example/2.jpg", "done"]])
  assert.equal(listingFromDraft({ currency: "DOGE", category: "Nope" }).currency, "SATS")
})

test("#/compose?type=listing opens Sell something; the New Post kinds stay five", () => {
  assert.equal(composeType("#/compose?type=listing"), "listing")
  assert.equal(composeType("#/compose?type=nope"), "note")
  assert.equal(COMPOSE_TYPES.length, 5)
  assert.ok(!COMPOSE_TYPES.some(([t]) => t === "listing"), "not a New Post kind: it opens from Marketplace")
})
