// The article reader's Like / Comment / Zap bar (ArticleReaderView actionBar): the NIP-22 comment it sends, the like
// count with your own like in it at once, and a sent comment showing before any relay echoes it. Throwaway keys,
// relays stubbed: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { finalizeEvent, generateSecretKey, getPublicKey, verifyEvent } from "nostr-tools/pure"
import { commentTemplate, likeCount, tally } from "../src/readers/engagement.js"
import { act, myReaction, publishAction } from "../src/net/actions.js"
import { pool } from "../src/net/pool.js"

registerHooks({ load(url, context, next) {
  if (!url.endsWith(".jsx")) return next(url, context)
  const { code } = transformSync(fileURLToPath(url), readFileSync(fileURLToPath(url), "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
  return { format: "module", source: code, shortCircuit: true }
} })

const me = generateSecretKey(), author = generateSecretKey()
const article = finalizeEvent({ kind: 30023, created_at: 1_700_000_000, tags: [["d", "my-post"], ["title", "T"]], content: "Body" }, author)
const COORD = `30023:${article.pubkey}:my-post`
const ctxFor = () => {
  const kept = []
  return {
    kept, session: { pubkey: getPublicKey(me) }, signer: { signEvent: async t => finalizeEvent(t, me) },
    account: { relays: { read: ["wss://relay.example.com"], write: ["wss://relay.example.com"] } },
    vault: { outbox: { event: async ev => { kept.push(ev); return { ok: true } }, query: async () => [] }, feed: { query: async () => [] } },
  }
}
const relaysSay = (t, answer) => {
  const sent = []
  t.mock.method(pool, "publish", (urls, ev) => { sent.push(ev); return urls.map(answer) })
  globalThis.location = { hostname: "vault.example.com", hash: "" }
  t.after(() => { delete globalThis.location })
  return sent
}

test("a comment on an addressable article is rooted by A, names this version by e, with K/k and P/p (NIP-22)", () => {
  const t = commentTemplate(article, "  Great piece  ", "wss://r.example", 5)
  assert.equal(t.kind, 1111)
  assert.equal(t.content, "Great piece")
  assert.deepEqual(t.tags, [
    ["A", COORD, "wss://r.example"], ["K", "30023"], ["P", article.pubkey], ["a", COORD, "wss://r.example"],
    ["e", article.id, "wss://r.example", article.pubkey], ["k", "30023"], ["p", article.pubkey],
  ])
})

test("with no d tag the article is rooted by E", () => {
  const plain = { ...article, tags: [] }
  assert.deepEqual(commentTemplate(plain, "x").tags.slice(0, 2), [["E", article.id, "", article.pubkey], ["K", "30023"]])
})

test("the comment goes out signed, with the client tag, and counts under the article as a top-level comment", async t => {
  const sent = relaysSay(t, () => Promise.resolve(""))
  const c = ctxFor()
  const { event } = await publishAction(c, commentTemplate(article, "Great piece"))
  assert.ok(verifyEvent(event))
  assert.equal(sent.length, 1)
  assert.ok(event.tags.some(tag => tag[0] === "client"))
  const counted = tally([event], article.id, COORD)
  assert.equal(counted.commentCount, 1)
  assert.deepEqual(counted.topLevel.map(e => e.id), [event.id])
})

test("the like count has your like in it at once and drops it when taken back; others' likes stand", () => {
  const mePk = getPublicKey(me)
  assert.equal(likeCount(new Set(["a", "b"]), mePk, null), 2)
  assert.equal(likeCount(new Set(["a", "b"]), mePk, { emoji: "❤️" }), 3)
  assert.equal(likeCount(new Set(["a", mePk]), mePk, { emoji: "❤️" }), 2) // already counted from the relays
  assert.equal(likeCount(new Set(["a", mePk]), mePk, { emoji: null }), 1)
  assert.equal(likeCount(new Set(["a"]), mePk, { emoji: null }), 1)
})

test("liking the article is the notes' instant like: counted before the relay answers", async t => {
  relaysSay(t, () => new Promise(() => {}))
  act(ctxFor(), "like", article)
  assert.deepEqual(myReaction(article.id), { emoji: "❤️" })
  assert.equal(likeCount(new Set(), getPublicKey(me), myReaction(article.id)), 1)
})

test("the bar: the notes' heart and bolt, a Comment button, and a comment box that waits out the send delay", async () => {
  const src = readFileSync(new URL("../src/readers/ArticleActions.jsx", import.meta.url), "utf8")
  assert.match(src, /<ReactionButton ctx=\{ctx\} note=\{article\}/)
  assert.match(src, /<ZapButton note=\{article\} \/>/)
  assert.match(src, /startCountdown\(\{ seconds: sendDelaySeconds\(\)/)
  const { CommentBox, ArticleActionBar } = await import("../src/readers/ArticleActions.jsx")
  assert.equal(typeof CommentBox, "function")
  assert.equal(typeof ArticleActionBar, "function")
  const eng = readFileSync(new URL("../src/readers/Engagement.jsx", import.meta.url), "utf8")
  assert.match(eng, /<ArticleActionBar ctx=\{ctx\} article=\{article\}/)
})
