// Conduit listings (client tag "Conduit Merchant Portal") buy on Conduit, by coordinate; everything else stays on Plebeian.
// Shapes from the live capture in RESEARCH/NV_CONDUIT_BUY_LINK_2026_11_26.md.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { npubEncode } from "nostr-tools/nip19"
import { buyLink, conduitUrl, isConduit, parseListing, sellerMessage } from "../src/readers/market.js"

const PK = "f8ae6c13".padEnd(64, "0"), SELLER = "5e11e5".padEnd(64, "1"), ID = "4ca50dcf".padEnd(64, "2")
const CLIENT = ["client", "Conduit Merchant Portal", `31990:${PK}:conduit-merchant`, "wss://relay.conduit.market"]
const ev = (tags, kind = 30402) => ({ id: ID, kind, pubkey: SELLER, created_at: 1, content: "Hoodie",
  tags: [["title", "Genesis XXI Hoodie"], ["image", "https://img/h.jpg"], ["price", "60", "USD"], ...tags] })

test("a Conduit listing is told by its client tag, by name or by handler address", () => {
  assert.equal(isConduit([CLIENT]), true)
  assert.equal(isConduit([["client", "Conduit Merchant Portal"]]), true)
  assert.equal(isConduit([["client", "Renamed", `31990:${PK}:conduit-merchant`]]), true)
  assert.equal(isConduit([["client", "Shopstr", `31990:${PK}:shopstr`]]), false)
  assert.equal(isConduit([["t", "conduit"], ["r", "wss://relay.conduit.market"]]), false)
  assert.equal(isConduit(undefined), false)
})

test("Buy on Conduit opens the product by coordinate, encoded as the shop writes it", () => {
  const l = parseListing(ev([["d", "hoodie-2xl"], CLIENT]))
  assert.equal(l.conduit, true)
  const b = buyLink(l)
  assert.deepEqual([b.site, b.label, b.ownPage], ["Conduit", "Buy on Conduit", true])
  assert.equal(b.url, `https://shop.conduit.market/products/30402%3A${SELLER}%3Ahoodie-2xl`)
  assert.equal(sellerMessage(l), `Hi! I'm interested in “Genesis XXI Hoodie”.\n${b.url}`)
})

test("no d tag: the product by event id; a non-30402: the seller's shop by npub, and no link in the message", () => {
  assert.equal(conduitUrl({ kind: 30402, pubkey: SELLER, id: ID, d: null }), `https://shop.conduit.market/products/${ID}`)
  const p = parseListing(ev([["d", "x"], CLIENT], 30018))
  const b = buyLink(p)
  assert.deepEqual([b.label, b.url], ["Seller on Conduit", `https://shop.conduit.market/${npubEncode(SELLER)}`])
  assert.equal(sellerMessage(p), "Hi! I'm interested in “Genesis XXI Hoodie”.")
})

test("every other listing keeps Plebeian", () => {
  const l = parseListing(ev([["d", "x"], ["client", "Shopstr"]]))
  assert.equal(l.conduit, false)
  assert.deepEqual(buyLink(l), { site: "Plebeian", url: `https://plebeian.market/products/${ID}`, label: "Buy on Plebeian", ownPage: true })
})

test("the listing view draws the one buy button from buyLink, footer included", () => {
  const src = readFileSync(new URL("../src/readers/MarketplaceScreen.jsx", import.meta.url), "utf8")
  assert.match(src, /<a class="market-buy" href=\{buy\.url\}[^>]*>\{buy\.label\}<\/a>/)
  assert.doesNotMatch(src, /plebeianUrl\(l\)/)
})
