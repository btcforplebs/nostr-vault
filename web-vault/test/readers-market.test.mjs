// The Marketplace reader: listings parsed as the iPhone parses them (NIP-15 JSON, NIP-99 tags, Conduit), what is left
// out, prices, categories, and the newest-per-address book.
import test from "node:test"
import assert from "node:assert/strict"
import { parseListing, priceLabel, classify, book, marketCategories, marketFilter, fetchListings, plebeianUrl, loadScope, isOutOfStock, MARKET_RELAYS, trustedFilters, TRUSTED_AUTHORS_CAP } from "../src/readers/market.js"

const A = "a".repeat(64), C = "c".repeat(64)
let n = 0
const ev = (o = {}) => ({ id: (o.id ?? String(++n)).padStart(64, "0"), kind: o.kind ?? 30018, pubkey: o.pubkey ?? A, created_at: o.at ?? 100,
  content: o.content ?? JSON.stringify({ name: "Hat", description: "A warm hat", images: ["https://img/h.jpg"], price: 21000, currency: "sat" }),
  tags: o.tags ?? [["d", o.d ?? `p${n}`]] })

test("a NIP-15 product reads from JSON: name, description, images, price and currency", () => {
  const l = parseListing(ev())
  assert.equal(l.title, "Hat")
  assert.equal(l.summary, "A warm hat")
  assert.deepEqual(l.images, ["https://img/h.jpg"])
  assert.equal(priceLabel(l), "21,000 sats")
  assert.equal(l.category, "Clothing")
})

test("a NIP-99 classified reads from tags, keeping the short summary tag", () => {
  const l = parseListing(ev({ kind: 30402, content: "Long **markdown** body", tags: [["d", "c"], ["title", "Bike"], ["summary", "Road bike"], ["image", "https://img/b.jpg"], ["price", "250", "usd"], ["location", "Austin"]] }))
  assert.deepEqual([l.title, l.summary, priceLabel(l), l.location, l.isAuction], ["Bike", "Road bike", "250 USD", "Austin", false])
})

test("Conduit's JSON 30402 with image objects and an auction's starting bid", () => {
  const c = parseListing(ev({ kind: 30402, content: JSON.stringify({ title: "Print", summary: "Signed", images: [{ url: "https://img/p.jpg" }] }), tags: [["d", "x"], ["price", "5"]] }))
  assert.deepEqual([c.title, c.images[0], priceLabel(c), c.category], ["Print", "https://img/p.jpg", "5 sats", "Art"])
  const a = parseListing(ev({ kind: 30020, content: JSON.stringify({ name: "Coin", images: ["https://img/c.jpg"], starting_bid: 1000 }) }))
  assert.ok(a.isAuction)
  assert.equal(priceLabel(a), "1,000 sats")
  assert.match(plebeianUrl(a), /^https:\/\/plebeian\.market\/auction\//)
  assert.match(plebeianUrl(c), /^https:\/\/plebeian\.market\/products\//)
})

test("left out: no title, Untitled Product, no http image, sold, out of stock, hidden", () => {
  const j = o => JSON.stringify({ name: "Hat", images: ["https://img/h.jpg"], ...o })
  assert.equal(parseListing(ev({ content: j({ name: "" }) })), null)
  assert.equal(parseListing(ev({ content: j({ name: "Untitled Product" }) })), null)
  assert.equal(parseListing(ev({ content: j({ images: ["javascript:x", "ftp://y"] }) })), null)
  assert.equal(parseListing(ev({ content: j({ quantity: 0 }) })), null)
  assert.ok(parseListing(ev({ content: j({ quantity: null }) })), "null quantity = no limit")
  assert.equal(parseListing(ev({ tags: [["d", "s"], ["status", "Sold"]] })), null)
  assert.equal(parseListing(ev({ tags: [["d", "s"], ["visibility", "hidden"]] })), null)
  assert.equal(parseListing(ev({ kind: 30402, content: "body", tags: [["title", "T"], ["image", "https://i/x.jpg"], ["quantity", "0"]] })), null)
  assert.equal(parseListing({ ...ev(), kind: 1 }), null)
  assert.equal(parseListing(ev()).price, "21000")
  assert.equal(parseListing(ev({ content: j({}) })).price, "?")
  assert.ok(!isOutOfStock("lots"))
})

test("categories: topics first, then whole words or two-word phrases, in the iPhone's rule order", () => {
  assert.equal(classify(["bitcoin-hardware"], ""), "Bitcoin")
  assert.equal(classify([], "Trezor hardware wallet"), "Bitcoin", "the phrase wins before Home & Technology's 'hardware'")
  assert.equal(classify([], "Leather boots"), "Shoes")
  assert.equal(classify([], "Bootstrap course"), "Other", "a keyword inside a word doesn't count")
  assert.equal(classify([], "t-shirt"), "Clothing")
})

test("the book: newest per address, a sold edit removes the listing, blocked sellers out, newest first", () => {
  const live = ev({ d: "hat", at: 1 }), sold = ev({ d: "hat", at: 2, tags: [["d", "hat"], ["status", "sold"]] })
  const other = ev({ d: "cap", at: 3, content: JSON.stringify({ name: "Cap", images: ["https://img/c.jpg"] }) })
  const stranger = ev({ pubkey: C, d: "mug", at: 4 })
  assert.deepEqual(book([live, other], new Set()).map(l => l.title), ["Cap", "Hat"])
  assert.deepEqual(book([sold, live, other, stranger], new Set([C])).map(l => l.title), ["Cap"])
  assert.deepEqual(marketCategories(book([live, other, ev({ d: "z", content: JSON.stringify({ name: "Thing", images: ["https://i/t.jpg"] }) })])), ["Clothing", "Other"])
})

test("filter and load: Following only follows' listings, from the market relays", async () => {
  assert.equal(loadScope({ getItem: () => null }), "global")
  assert.deepEqual(marketFilter("global", []), { kinds: [30018, 30020, 30402], limit: 200 })
  assert.equal(marketFilter("following", []), null)
  let relays
  const { listings } = await fetchListings({ scope: "following", follows: [A], blocked: new Set(), query: async (r, f) => { relays = r; assert.deepEqual(f.authors, [A]); return [ev(), ev({ pubkey: C })] } })
  assert.equal(listings.length, 1, "a relay's stray author is dropped")
  assert.deepEqual(relays, MARKET_RELAYS)
})

test("Global keeps only sellers the web of trust vouches for, asking trusted authors first; no follows fails closed", async () => {
  const T = "7".repeat(64)
  const asked = []
  const { listings } = await fetchListings({ scope: "global", me: A, follows: [T], blocked: new Set(), trustOf: async () => new Set([A, T]),
    query: async (r, f) => { asked.push(f); return [ev({ pubkey: T, d: "t" }), ev({ pubkey: C, d: "spam" })] } })
  assert.deepEqual(listings.map(l => l.pubkey), [T])
  assert.deepEqual(asked.map(f => f.authors ?? null), [[A, T].sort(), null], "trusted authors first, then open")
  const none = await fetchListings({ scope: "global", me: A, follows: [], blocked: new Set(), trustOf: async () => { throw new Error("asked") }, query: async () => { throw new Error("asked") } })
  assert.deepEqual(none, { listings: [], noWeb: true })
  const many = new Set(Array.from({ length: 600 }, (_, i) => i.toString(16).padStart(64, "0")))
  assert.equal(trustedFilters({ kinds: [1] }, many)[0].authors.length, TRUSTED_AUTHORS_CAP)
})
