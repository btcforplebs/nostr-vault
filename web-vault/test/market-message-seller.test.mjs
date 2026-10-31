// Message seller (MarketplaceListingSheet): the DM with the seller, the iPhone's opening line typed in for you.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { messageSellerHash, sellerMessage } from "../src/readers/market.js"
import { dmPrefill } from "../src/net/dms.js"

const pk = "c".repeat(64), id = "d".repeat(64)
const listing = (kind, title) => ({ id, pubkey: pk, kind, title })

test("the opening line names the listing; the Plebeian link only when it is the listing's own page", () => {
  assert.equal(sellerMessage(listing(30402, "Road bike")), `Hi! I'm interested in “Road bike”.\nhttps://plebeian.market/products/${id}`)
  assert.equal(sellerMessage(listing(30018, "Hat")), "Hi! I'm interested in “Hat”.") // profile link says nothing about which item
  assert.equal(sellerMessage(listing(30402, "")), `Hi! I'm interested in your listing.\nhttps://plebeian.market/products/${id}`)
})

test("the DM route carries it, and the conversation types it in (dmPrefill), not sends it", () => {
  const hash = messageSellerHash(listing(30402, "Road bike & helmet?"))
  assert.match(hash, new RegExp(`^#/dm/${pk}\\?text=`))
  const { text, hash: rest } = dmPrefill(hash)
  assert.equal(text, sellerMessage(listing(30402, "Road bike & helmet?")))
  assert.equal(rest, `#/dm/${pk}`)
})

test("the listing offers it, but not on your own listing or when read-only", () => {
  const src = readFileSync(new URL("../src/readers/MarketplaceScreen.jsx", import.meta.url), "utf8")
  assert.match(src, /\{ctx && l\.pubkey !== ctx\.session\?\.pubkey && !ctx\.signer\?\.readOnly && <a class="market-message" href=\{messageSellerHash\(l\)\}>Message seller<\/a>\}/)
})
