// New Article (kind 30023): the iPhone's LongFormDraft tags, the d slug, Publish's hint, the Note / Article address,
// and that it signs, stores and sends as an article. Throwaway keys and a stubbed pool: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { generateSecretKey, getPublicKey, finalizeEvent, verifyEvent } from "nostr-tools/pure"
import { pool } from "../src/net/pool.js"
import { publishKind } from "../src/net/sync.js"
import { LONG_FORM_KIND, articleDraftOf, articleHint, articleIdentifier, buildArticle, canPublishArticle, hasArticle, slug } from "../src/screens/compose/article.js"
import { longFormMeta } from "../src/readers/longform.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { composeHref, composeType } = await import("../src/screens/compose/ComposeKinds.jsx")
await import("../src/screens/ComposeScreen.jsx") // the dispatcher still loads in node

const blank = { title: "", summary: "", body: "", cover: null }

test("slug: LongFormDraft.slug — letters and digits, one dash per run, no dash at the ends, 60 at most, else post", () => {
  assert.equal(slug("  Hello, World!  "), "hello-world")
  assert.equal(slug("Bitcoin & Nostr -- 2026"), "bitcoin-nostr-2026")
  assert.equal(slug("Café über Straße"), "café-über-straße")
  assert.equal(slug("!!!"), "post")
  assert.equal(slug(""), "post")
  assert.equal(slug("a".repeat(80)).length, 60)
  assert.match(articleIdentifier("My Post"), /^my-post-[0-9a-f]{6}$/)
  assert.notEqual(articleIdentifier("My Post"), articleIdentifier("My Post"))
})

test("buildArticle: d, title, summary only when written, image from the uploaded cover, published_at, a t per #hashtag", () => {
  const { content, tags } = buildArticle(
    { title: "  On #Nostr  ", summary: "  ", body: "\n# Heading\n\nWhy #bitcoin and #Nostr matter.\n", cover: { url: "https://cdn.example/c.jpg" } },
    { identifier: "on-nostr-abc123", publishedAt: 1761900000 })
  assert.equal(content, "# Heading\n\nWhy #bitcoin and #Nostr matter.")
  assert.deepEqual(tags, [["d", "on-nostr-abc123"], ["title", "On #Nostr"], ["image", "https://cdn.example/c.jpg"], ["published_at", "1761900000"], ["t", "nostr"], ["t", "bitcoin"]])
  const withSummary = buildArticle({ ...blank, title: "T", summary: " Short ", body: "b" }, { identifier: "t-1", publishedAt: 1 })
  assert.deepEqual(withSummary.tags.find(t => t[0] === "summary"), ["summary", "Short"])
  assert.equal(withSummary.tags.some(t => t[0] === "image"), false)
  // The reader reads back what was written.
  const meta = longFormMeta({ kind: LONG_FORM_KIND, tags: withSummary.tags })
  assert.equal(meta.title, "T"); assert.equal(meta.summary, "Short"); assert.equal(meta.identifier, "t-1"); assert.equal(meta.publishedAt, 1)
})

test("Publish needs a title and a body; the hint names what's missing and an empty form says nothing", () => {
  assert.equal(articleHint(blank), null)
  assert.equal(canPublishArticle(blank), false)
  assert.equal(articleHint({ ...blank, body: "words" }), "Add a title to publish.")
  assert.equal(articleHint({ ...blank, title: "T" }), "Write the article to publish.")
  assert.equal(articleHint({ ...blank, title: "   ", body: "  ", cover: { url: "https://x/y.jpg" } }), "Add a title to publish.")
  assert.equal(canPublishArticle({ ...blank, title: "T", body: "b" }), true)
  assert.equal(articleHint({ ...blank, title: "T", body: "b" }), null)
})

test("the draft keeps the fields and an uploaded cover, not a pending one", () => {
  assert.equal(hasArticle(blank), false)
  assert.deepEqual(articleDraftOf({ title: "T", summary: "", body: "b", cover: { preview: "blob:x", status: "uploading" } }), { title: "T", summary: "", body: "b" })
  assert.deepEqual(articleDraftOf({ title: "T", summary: "", body: "", cover: { preview: "blob:x", status: "done", url: "https://c/1.jpg", sha256: "ab", mime: "image/jpeg", size: 9 } }),
    { title: "T", summary: "", body: "", cover: { url: "https://c/1.jpg", sha256: "ab", mime: "image/jpeg" } })
})

test("the address picks the composer: ?type=article is an article; a bare compose, a reply, a quote or junk is a note", () => {
  assert.equal(composeType("#/compose?type=article"), "article")
  assert.equal(composeType("#compose?type=article"), "article")
  assert.equal(composeType("#/compose"), "note")
  assert.equal(composeType(`#/compose?reply=${"a".repeat(64)}`), "note")
  assert.equal(composeType("#/compose?type=nope"), "note")
  assert.equal(composeType("#/feed?type=article"), "note")
  assert.equal(composeHref("article"), "#/compose?type=article")
  assert.equal(composeHref("note"), "#/compose")
})

test("publishKind signs a kind 30023 (no client tag: notes and comments only), stores it, then sends it", async t => {
  const sk = generateSecretKey(), pk = getPublicKey(sk)
  const stored = [], sent = []
  const vault = { outbox: { event: async e => { stored.push(e); return { ok: true } } } }
  const signer = { signEvent: async tpl => finalizeEvent(tpl, sk) }
  t.mock.method(pool, "publish", (urls, ev) => { sent.push({ urls, ev }); return urls.map(() => Promise.resolve("")) })
  const { content, tags } = buildArticle({ ...blank, title: "Hello", body: "World" }, { identifier: "hello-000000", publishedAt: 5 })
  const res = await publishKind(vault, signer, pk, LONG_FORM_KIND, content, ["wss://w.example"], tags)
  assert.equal(res.event.kind, LONG_FORM_KIND)
  assert.ok(verifyEvent(res.event))
  assert.equal(res.event.tags.some(t => t[0] === "client"), false)
  assert.deepEqual(stored.map(e => e.id), [res.event.id])
  assert.ok(sent[0].urls.includes("wss://w.example"))
  assert.ok(res.relays.some(r => r.url === "wss://w.example" && r.ok))
})

test("Haven refusing the article stops it before any relay", async t => {
  const sk = generateSecretKey()
  let sent = 0
  t.mock.method(pool, "publish", urls => { sent++; return urls.map(() => Promise.resolve("")) })
  const vault = { outbox: { event: async () => ({ ok: false, message: "blocked" }) } }
  await assert.rejects(publishKind(vault, { signEvent: async tpl => finalizeEvent(tpl, sk) }, getPublicKey(sk), LONG_FORM_KIND, "b", ["wss://w.example"], [["d", "x"]]), /Haven refused the post: blocked/)
  assert.equal(sent, 0)
})
