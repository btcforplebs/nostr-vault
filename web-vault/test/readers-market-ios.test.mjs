// Marketplace against the iPhone: the seller under a tile's price, the listing in header → seller → description →
// buy order with a plain-text description and Auction beside the price, chips from one category, and its empty states.
import test from "node:test"
import assert from "node:assert/strict"
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
const walk = (node, out = []) => {
  if (node == null || typeof node === "boolean") return out
  if (Array.isArray(node)) { node.forEach(x => walk(x, out)); return out }
  if (typeof node !== "object") { out.push(String(node)); return out }
  out.push(node)
  if (["AuthorName", "Avatar"].includes(node.type?.name)) return out
  if (typeof node.type === "function") walk(node.type(node.props), out)
  else walk(node.props?.children, out)
  return out
}
const text = n => walk(n).filter(x => typeof x === "string").join(" ")
const { MarketTile, MarketEmpty } = await import("../src/readers/MarketplaceScreen.jsx")
const src = readFileSync(new URL("../src/readers/MarketplaceScreen.jsx", import.meta.url), "utf8")
const L = { id: "1", pubkey: "a".repeat(64), title: "Hat", images: ["https://x/1.jpg"], isAuction: false, priceAmount: 21, priceCurrency: "SAT", category: "Other", summary: "**not markdown**" }

test("a tile shows the seller under the price", () => {
  const nodes = walk(MarketTile({ listing: L, onOpen() {} }))
  const i = nodes.findIndex(n => n.props?.class === "market-price"), j = nodes.findIndex(n => n.type?.name === "AuthorName")
  assert.ok(i > 0 && j > i, "seller after price")
})

test("the listing reads header, seller, description, buy; description is plain text; Auction sits by the price", () => {
  const at = k => src.indexOf(k)
  assert.ok(at('class="market-price big"') < at('class="reader-byline market-seller"'))
  assert.ok(at('class="reader-byline market-seller"') < at('class="market-description"'))
  assert.ok(at('class="market-description"') < at('class="market-buy"'))
  assert.equal(/<Markdown/.test(src), false)
  assert.match(src, /\{priceLabel\(l\)\}\{l\.isAuction && <span class="market-badge inline">Auction<\/span>\}/)
  assert.match(src, /\{l\.isAuction \? "Auction" : "Listing"\}/)
  assert.match(src, /cats\.length > 0 &&/)
})

test("the iPhone's empty states, each with its button; a failed load ends", () => {
  let went = ""
  const f = MarketEmpty({ scope: "following", failed: false, onGlobal: () => { went = "g" }, onRetry: () => { went = "r" } })
  assert.match(text(f), /No listings from your follows.*Switch to Global/)
  walk(f).find(n => n.type === "button").props.onClick()
  assert.equal(went, "g")
  assert.match(text(MarketEmpty({ scope: "global", failed: true, onGlobal() {}, onRetry() {} })), /Could not reach any relay.*Try again/)
  assert.match(text(MarketEmpty({ scope: "global", failed: false, onGlobal() {}, onRetry() {} })), /No listings found.*with a photo came back/)
  assert.match(src, /setFailed\(true\); setListings\(l => l \?\? \[\]\)/)
})
