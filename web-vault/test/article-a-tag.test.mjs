// An article's like and zap carry its address (a tag) as well as its id, as iOS ArticleEngagement.reactionTags and
// ZapService.zapNote(addressTag:) send them, and the article's zap opens the amounts first (ArticleReaderView).
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { addressOf, reactionTemplate } from "../src/net/actions.js"
import { zapRequestTemplate } from "../src/net/zaps.js"

registerHooks({ load(url, context, next) {
  if (!url.endsWith(".jsx")) return next(url, context)
  const { code } = transformSync(fileURLToPath(url), readFileSync(fileURLToPath(url), "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
  return { format: "module", source: code, shortCircuit: true }
} })
const { zapWithFeedback } = await import("../src/components/ZapButton.jsx")

const pk = "b".repeat(64), id = "a".repeat(64)
const article = { id, pubkey: pk, kind: 30023, tags: [["d", "my-post"]], content: "", created_at: 1 }
const note = { id, pubkey: pk, kind: 1, tags: [], content: "", created_at: 1 }

test("an address for addressable and replaceable events, none for a note or an addressable one without d", () => {
  assert.equal(addressOf(article), `30023:${pk}:my-post`)
  assert.equal(addressOf({ ...article, tags: [["d", ""]] }), `30023:${pk}:`)
  assert.equal(addressOf({ ...article, tags: [] }), null)
  assert.equal(addressOf({ ...note, kind: 10002 }), `10002:${pk}:`)
  assert.equal(addressOf({ ...note, kind: 0 }), `0:${pk}:`)
  assert.equal(addressOf(note), null)
  assert.equal(addressOf(null), null)
})

test("a like on an article carries e, a, p and k (ArticleEngagement.reactionTags); a note's stays e, p, k", () => {
  assert.deepEqual(reactionTemplate(article).tags, [["e", id, ""], ["a", `30023:${pk}:my-post`, ""], ["p", pk], ["k", "30023"]])
  assert.deepEqual(reactionTemplate(note).tags, [["e", id, ""], ["p", pk], ["k", "1"]])
})

test("a zap on an article asks with its address; a note zap and a profile zap don't", async () => {
  const calls = []
  const pay = async (ctx, args) => { calls.push(args) }
  const ctx = {}
  await zapWithFeedback(ctx, { recipient: pk, note: article, sats: 21 }, pay)
  await zapWithFeedback(ctx, { recipient: pk, note, sats: 21 }, pay)
  await zapWithFeedback(ctx, { recipient: pk, sats: 21 }, pay)
  assert.deepEqual(calls.map(c => c.address), [`30023:${pk}:my-post`, undefined, undefined])
  const req = zapRequestTemplate({ recipient: pk, noteId: id, address: calls[0].address, amountMsat: 21000, relays: ["wss://r"], lnurl: "lnurl1x" })
  assert.deepEqual(req.tags.filter(t => t[0] === "e" || t[0] === "a"), [["e", id], ["a", `30023:${pk}:my-post`]])
})

test("the article's zap opens the amounts on a tap (pickFirst); the notes' still zap the default", () => {
  assert.match(readFileSync(new URL("../src/readers/ArticleActions.jsx", import.meta.url), "utf8"), /<ZapButton note=\{article\} pickFirst \/>/)
  const zb = readFileSync(new URL("../src/components/ZapButton.jsx", import.meta.url), "utf8")
  assert.match(zb, /if \(!busy\) pickFirst \? setPicking\(true\) : send\(wallet\.defaultSats\)/)
  assert.match(zb, /<AmountPicker initial=\{wallet\.defaultSats\}/)
  assert.match(readFileSync(new URL("../src/components/NoteCard.jsx", import.meta.url), "utf8"), /<ZapButton note=\{note\} \/>/)
})
