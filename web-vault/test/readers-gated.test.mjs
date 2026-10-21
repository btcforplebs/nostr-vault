// Locked (gated) articles: recognised by the iPhone's GatedArticle rules, teaser without the call to action, a lock
// card with Open in Fanfares, and no unlock or payment on the web.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { bech32 } from "@scure/base"
import { gatedArticle, stripTeaser, teaserUnlockUrl, fanfaresLink, lockStatus } from "../src/readers/gated.js"
import { plainText } from "../src/readers/longform.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})

// The real Fanfares article the iPhone's GatedArticleTests pin its naddr against.
const AUTHOR = "adc14fa3ad590856dd8b80815d367f7c1e6735ad00fd98a86d002fbe9fb535e1"
const D = "d6711eb7-0703-48bb-9fd5-61b96e57283c"
const tags = () => [
  ["d", D],
  ["encrypted", "aes-256-gcm", "AAAA", "https://api.fanfares.live/request-key"],
  ["price", "42", "SATS"],
  ["title", "Whose life is this?"],
  ["zap", AUTHOR, "wss://fanfares.nostr1.com", "42"],
]
const TEASER = "Christian manhood starts with one question: whose life is this?\n\n⚡ Zap 42 sats to unlock the full article on\nhttps://fanfares.io/naddr/naddr1xyz"
const ev = (t = tags(), content = TEASER) => ({ id: "f".repeat(64), kind: 30023, pubkey: AUTHOR, created_at: 100, content, tags: t })

test("a Fanfares article is gated, with its price and relay", () => {
  assert.deepEqual(gatedArticle(ev()), { priceSats: 42, keyUrl: "https://api.fanfares.live/request-key", isFanfares: true, relay: "wss://fanfares.nostr1.com" })
})

test("not gated: another kind, no key URL, http key URL, no price, zero, fiat, another cipher", () => {
  assert.equal(gatedArticle({ ...ev(), kind: 1 }), null)
  const swap = (i, tag) => { const t = tags(); t[i] = tag; return gatedArticle(ev(t)) }
  assert.equal(swap(1, ["encrypted", "aes-256-gcm", "AAAA"]), null, "no key URL")
  assert.equal(swap(1, ["encrypted", "aes-256-gcm", "AAAA", "http://api.fanfares.live/k"]), null, "http")
  assert.equal(swap(1, ["encrypted", "aes-256-gcm", "", "https://api.fanfares.live/k"]), null, "no ciphertext")
  assert.equal(swap(1, ["encrypted", "chacha20", "AAAA", "https://api.fanfares.live/k"]), null, "cipher")
  assert.equal(gatedArticle(ev(tags().filter(t => t[0] !== "price"))), null, "no price")
  assert.equal(swap(2, ["price", "0", "SATS"]), null, "zero")
  assert.equal(swap(2, ["price", "5", "USD"]), null, "fiat")
  assert.equal(swap(2, ["price", "abc"]), null, "not a number")
  assert.equal(swap(2, ["price", "21"]).priceSats, 21, "no currency means sats")
  assert.equal(gatedArticle(ev([["d", "x"], ["title", "Plain"]])), null, "an ordinary article")
})

test("Fanfares by host: subdomains count, look-alikes don't", () => {
  const host = url => { const t = tags(); t[1] = ["encrypted", "aes-256-gcm", "AAAA", url]; return gatedArticle(ev(t)).isFanfares }
  for (const u of ["https://fanfares.io/api/request-key", "https://FANFARES.LIVE/k", "https://api.fanfares.live/k"]) assert.equal(host(u), true, u)
  for (const u of ["https://keys.example.com/k", "https://notfanfares.live/k", "https://fanfares.live.evil.com/k"]) assert.equal(host(u), false, u)
})

test("the teaser drops the call to action and its link; without one it is unchanged", () => {
  assert.equal(stripTeaser(TEASER), "Christian manhood starts with one question: whose life is this?")
  assert.equal(stripTeaser("Just a teaser."), "Just a teaser.")
  const withImage = "![cover](https://img.example/a.png)\n\nTeaser.\n\n⚡ Zap 42 sats to unlock the full article on\nhttps://fanfares.io/naddr/naddr1xyz"
  assert.equal(teaserUnlockUrl(withImage), "https://fanfares.io/naddr/naddr1xyz")
  assert.equal(teaserUnlockUrl("https://img.example/a.png only"), null)
})

test("Open in Fanfares carries the same naddr bytes Fanfares links to (iPhone fixture)", () => {
  const url = fanfaresLink(ev())
  assert.match(url, /^https:\/\/fanfares\.io\/naddr\/naddr1/)
  const { words } = bech32.decode(url.split("/").pop(), 5000)
  const hex = Buffer.from(bech32.fromWords(words)).toString("hex")
  assert.equal(hex, "0304000075470220adc14fa3ad590856dd8b80815d367f7c1e6735ad00fd98a86d002fbe9fb535e101197773733a2f2f66616e66617265732e6e6f737472312e636f6d002464363731316562372d303730332d343862622d396664352d363162393665353732383363")
})

test("Open in Fanfares: the teaser's link without a d tag; nothing for a non-Fanfares lock", () => {
  assert.equal(fanfaresLink(ev(tags().filter(t => t[0] !== "d"))), "https://fanfares.io/naddr/naddr1xyz")
  const t = tags(); t[1] = ["encrypted", "aes-256-gcm", "AAAA", "https://keys.example.com/k"]
  assert.equal(fanfaresLink(ev(t)), null)
})

test("lock copy, as on the iPhone minus the in-app check", () => {
  assert.equal(lockStatus("Ann", false), "Locked by Ann. Only its unlocked readers can open it.")
  assert.match(lockStatus("Ann", true), /^Locked by Ann\. Unlock it on Fanfares/)
})

const walk = (node, out = []) => {
  if (node == null || typeof node === "boolean") return out
  if (Array.isArray(node)) { node.forEach(n => walk(n, out)); return out }
  if (typeof node !== "object") { out.push(String(node)); return out }
  out.push(node)
  if (typeof node.type === "function") walk(node.type(node.props), out)
  else walk(node.props?.children, out)
  return out
}
const text = nodes => nodes.filter(n => typeof n === "string").join(" ")
const { LockedTeaser } = await import("../src/readers/ArticlesScreen.jsx")

test("the reader shows the teaser and a lock card with Open in Fanfares, never the call to action", () => {
  const e = ev()
  const nodes = walk(LockedTeaser({ event: e, gated: gatedArticle(e), summary: null, author: "Ann" }))
  const t = text(nodes)
  assert.match(t, /whose life is this\?/)
  assert.match(t, /Locked article/)
  assert.match(t, /Locked by Ann/)
  assert.equal(/to unlock/i.test(t), false, "call to action gone")
  const a = nodes.find(n => n.type === "a" && n.props.class === "reader-lock-open")
  assert.equal(a.props.href, fanfaresLink(e))
  assert.equal(a.props.target, "_blank")
  assert.equal(nodes.some(n => typeof n === "object" && /zap|pay|unlock/i.test(String(n.props?.onClick ?? ""))), false)
})

test("a teaser equal to the summary isn't shown twice; a non-Fanfares lock has no link", () => {
  const t = tags(); t[1] = ["encrypted", "aes-256-gcm", "AAAA", "https://keys.example.com/k"]
  const e = ev(t, "Same.\n\nZap 42 sats to unlock https://x.example/a")
  const nodes = walk(LockedTeaser({ event: e, gated: gatedArticle(e), summary: "Same.", author: "Ann" }))
  assert.equal(text(nodes).includes("Same."), false)
  assert.equal(nodes.some(n => n.type === "a"), false)
  assert.match(text(nodes), /Only its unlocked readers/)
})

test("the card preview drops the call to action", () => {
  assert.equal(plainText(stripTeaser(TEASER)).includes("unlock"), false)
})
