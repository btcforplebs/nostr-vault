// The Articles reader: long-form metadata, the iPhone's Markdown subset, "Open in" links, and the Articles feed's
// fetch (Following through Haven /feed, Global in memory only).
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { decode } from "nostr-tools/nip19"
import { longFormMeta, displayTitle, readingMinutes, isRecipe, dedupeAddressable, longFormLink, parseMarkdown, parseInline, plainText, standaloneImage } from "../src/readers/longform.js"
import { articleFilter, keepArticles, fetchArticles, loadScope, saveScope } from "../src/readers/articles.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { Markdown } = await import("../src/readers/Markdown.jsx")
const { READERS } = await import("../src/readers/index.js")
const { feedList } = await import("../src/net/feeds.js")

const A = "a".repeat(64), B = "b".repeat(64), C = "c".repeat(64)
const art = (o = {}) => ({ id: o.id ?? Math.random().toString(16).slice(2).padEnd(64, "0"), kind: 30023, pubkey: o.pubkey ?? A, created_at: o.at ?? 100, content: o.content ?? "body", tags: o.tags ?? [["d", o.d ?? "x"]] })

test("Articles is a reader in the picker, after Media, in the iPhone's order", () => {
  assert.equal(READERS.find(r => r.id === "articles")?.label, "Articles")
  const ids = feedList(READERS).map(f => f.id)
  assert.ok(ids.indexOf("articles") > ids.indexOf("media"))
})

test("metadata: trimmed tags, fractional published_at, lowercased topics, only http(s) images", () => {
  const m = longFormMeta(art({ tags: [["d", "x"], ["title", "  Hi "], ["published_at", "1700000000.5"], ["t", "Bitcoin"], ["image", "javascript:alert(1)"]] }))
  assert.equal(m.title, "Hi")
  assert.equal(m.publishedAt, 1700000000.5)
  assert.deepEqual(m.topics, ["bitcoin"])
  assert.equal(m.image, null)
  assert.equal(longFormMeta(art({ tags: [["image", "https://x.com/a.jpg"]] })).image, "https://x.com/a.jpg")
})

test("an untitled article takes its first line, without # marks", () => {
  assert.equal(displayTitle(art({ content: "\n\n## My trip  \nmore" })), "My trip")
  assert.equal(displayTitle(art({ content: "" })), "Untitled")
})

test("reading time is 200 words a minute, at least 1, none for an empty body", () => {
  assert.equal(readingMinutes("one two"), 1)
  assert.equal(readingMinutes(Array(201).fill("w").join(" ")), 2)
  assert.equal(readingMinutes("   "), null)
})

test("one per address, the newest edit wins; a recipe is told apart by its t tag", () => {
  const old = art({ id: "1".repeat(64), at: 1, d: "post" }), edit = art({ id: "2".repeat(64), at: 2, d: "post" }), other = art({ id: "3".repeat(64), at: 3, d: "other" })
  assert.deepEqual(dedupeAddressable([old, other, edit]).map(e => e.id), [other.id, edit.id])
  assert.ok(isRecipe([["t", "ZapCooking"]]))
  assert.ok(!isRecipe([["t", "cooking"]]))
})

test("Open in: YakiHonne for an article, zap.cooking for a recipe, as an naddr that decodes back", () => {
  const a = longFormLink(art({ d: "hello" }))
  assert.equal(a.site, "YakiHonne")
  assert.match(a.url, /^https:\/\/yakihonne\.com\/article\/naddr1/)
  assert.deepEqual(decode(a.url.split("/").pop()).data, { kind: 30023, pubkey: A, identifier: "hello", relays: [] })
  const r = longFormLink(art({ tags: [["d", "soup"], ["t", "nostrcooking"]] }))
  assert.equal(r.site, "zap.cooking")
  assert.match(r.url, /^https:\/\/zap\.cooking\/recipe\/naddr1/)
  assert.equal(longFormLink(art({ tags: [] })), null, "no d tag, no naddr")
  assert.equal(longFormLink({ ...art(), kind: 1 }), null)
})

test("markdown blocks match the iPhone's parser", () => {
  const body = [
    "# Title", "#bitcoin is not a heading", "", "wrapped", "paragraph", "", "- item", "* ![pic](https://x.com/p.png)",
    "1. first", "12) twelfth", "1.", "> quoted", "---", "```", "  code  line", "```", "https://x.com/solo.webp",
  ].join("\n")
  assert.deepEqual(parseMarkdown(body), [
    { type: "heading", level: 1, text: "Title" },
    { type: "paragraph", text: "#bitcoin is not a heading" },
    { type: "paragraph", text: "wrapped paragraph" },
    { type: "bullet", text: "item" },
    { type: "image", url: "https://x.com/p.png" },
    { type: "ordered", index: 1, text: "first" },
    { type: "ordered", index: 12, text: "twelfth" },
    { type: "paragraph", text: "1." },
    { type: "quote", text: "quoted" },
    { type: "rule" },
    { type: "code", text: "  code  line" },
    { type: "image", url: "https://x.com/solo.webp" },
  ])
  assert.deepEqual(parseMarkdown("```\nunclosed"), [{ type: "code", text: "unclosed" }])
  assert.equal(standaloneImage("https://x.com/page"), null)
})

test("inline: bold, italic, code and http(s) links; any other link scheme stays text", () => {
  assert.deepEqual(parseInline("a **b** _c_ `d` [e](https://e.com) [f](javascript:void) https://g.com/x."), [
    { type: "text", text: "a " }, { type: "strong", text: "b" }, { type: "text", text: " " }, { type: "em", text: "c" },
    { type: "text", text: " " }, { type: "code", text: "d" }, { type: "text", text: " " }, { type: "link", text: "e", url: "https://e.com/" },
    { type: "text", text: " " }, { type: "text", text: "f" }, { type: "text", text: " " }, { type: "link", text: "https://g.com/x", url: "https://g.com/x" },
    { type: "text", text: "." },
  ])
  assert.deepEqual(parseInline("snake_case_name"), [{ type: "text", text: "snake_case_name" }])
  assert.equal(plainText("# Hi\n\nSome **bold** text"), "Hi Some bold text")
})

/** Every vnode in a tree. */
function walk(node, out = []) {
  if (Array.isArray(node)) { node.forEach(n => walk(n, out)); return out }
  if (!node || typeof node !== "object") return out
  out.push(node)
  if (node.type?.name === "MdImage") return out // hooks; its <img> is checked below
  if (typeof node.type === "function") walk(node.type(node.props), out)
  else walk(node.props?.children, out)
  return out
}

test("an article image is a button that opens it full screen on its own, as MarkdownBodyView's onImageTap", async () => {
  const nodes = walk(Markdown({ body: "Intro\n\n![](https://img.example/a.jpg)\n\n![](https://img.example/b.jpg)" }))
  assert.deepEqual(nodes.filter(n => n.type?.name === "MdImage").map(n => n.props.url), ["https://img.example/a.jpg", "https://img.example/b.jpg"])
  const src = readFileSync(new URL("../src/readers/Markdown.jsx", import.meta.url), "utf8")
  assert.match(src, /<button type="button" class="md-image-open"[^>]*onClick=\{e => \{ e\.stopPropagation\(\); setOpen\(true\) \}\}>/)
  assert.match(src, /<MediaLightbox items=\{\[imageItem\(url\)\]\} onClose=\{\(\) => setOpen\(false\)\} \/>/)
  assert.match(src, /<img class="md-image" src=\{url\} alt="" loading="lazy" referrerpolicy="no-referrer" \/>/)
})

test("the body is built as elements, never HTML: a <script> in an article stays text", () => {
  const nodes = walk(Markdown({ body: "<script>alert(1)</script>\n\n<img src=x onerror=alert(1)>" }))
  assert.ok(!nodes.some(n => n.props?.dangerouslySetInnerHTML), "no raw HTML")
  assert.ok(!nodes.some(n => n.type === "script"))
  assert.equal(nodes.filter(n => n.type === "img").length, 0)
})

test("the filter: Following asks for follows' 30023, Global for anyone's, nothing to ask with no follows", () => {
  assert.deepEqual(articleFilter("following", [A], { limit: 5 }), { kinds: [30023], limit: 5, authors: [A] })
  assert.deepEqual(articleFilter("global", [], { limit: 5, until: 9 }), { kinds: [30023], limit: 5, until: 9 })
  assert.equal(articleFilter("following", []), null)
})

test("only what was asked for: no recipes, no other kinds, no authors outside the filter", () => {
  const keep = art({ pubkey: A, d: "k" })
  const evs = [keep, art({ pubkey: C, d: "stranger" }), { ...art({ d: "note" }), kind: 1 }, art({ d: "r", tags: [["d", "r"], ["t", "zapcooking"]] })]
  assert.deepEqual(keepArticles(evs, { authors: [A] }).map(e => e.id), [keep.id])
})

const memStorage = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)) } }
test("the scope is remembered; nothing or junk means Following", () => {
  const s = memStorage()
  assert.equal(loadScope(s), "following")
  saveScope("global", s)
  assert.equal(loadScope(s), "global")
  s.setItem("nv-articles-scope", "everyone")
  assert.equal(loadScope(s), "following")
})

function fakeVault(stored = []) {
  const written = []
  return { written, feed: { query: async f => stored.filter(e => f.kinds.includes(e.kind) && (!f.authors || f.authors.includes(e.pubkey))), event: async ev => { written.push(ev); return { ok: true } } } }
}

test("Following reads /feed, then writes the network's articles into /feed; Global writes nothing", async () => {
  const saved = art({ id: "1".repeat(64), pubkey: A, d: "saved", at: 5 })
  const fresh = art({ id: "2".repeat(64), pubkey: B, d: "fresh", at: 9 })
  const vault = fakeVault([saved])
  const asked = []
  const query = async (r, f) => { asked.push(f); return [fresh] }
  const { articles } = await fetchArticles({ scope: "following", follows: [A, B], relays: ["wss://r"], vault, query, online: true })
  assert.deepEqual(articles.map(a => a.id), [fresh.id, saved.id])
  assert.deepEqual(vault.written.map(e => e.id), [fresh.id])
  assert.deepEqual(asked[0].authors, [A, B])

  const g = fakeVault()
  const out = await fetchArticles({ scope: "global", me: B, follows: [A], relays: ["wss://r"], vault: g, trustOf: async () => new Set([B, A, C]), query: async () => [art({ pubkey: C })], online: true })
  assert.equal(out.articles.length, 1)
  assert.equal(g.written.length, 0, "strangers' articles stay in memory")
})

test("Global: only people the web of trust vouches for, trusted authors asked first; no follows fails closed", async () => {
  const asked = []
  const out = await fetchArticles({ scope: "global", me: B, follows: [A], relays: ["wss://r"], online: true, trustOf: async () => new Set([B, A]),
    query: async (r, f) => { asked.push(f.authors ?? null); return [art({ pubkey: A, d: "ok" }), art({ pubkey: C, d: "spam" })] } })
  assert.deepEqual(out.articles.map(a => a.pubkey), [A])
  assert.deepEqual(asked, [[A, B].sort(), null])
  const none = await fetchArticles({ scope: "global", me: B, follows: [], relays: [], online: true, trustOf: async () => { throw new Error("asked") }, query: async () => { throw new Error("asked") } })
  assert.deepEqual(none, { articles: [], fromNetwork: false, noWeb: true })
})

test("offline, Following shows what /feed holds and asks no relay", async () => {
  const saved = art({ pubkey: A })
  let asked = 0
  const { articles, fromNetwork } = await fetchArticles({ scope: "following", follows: [A], relays: [], vault: fakeVault([saved]), online: false, query: async () => { asked++; return [] } })
  assert.equal(articles.length, 1)
  assert.equal(fromNetwork, false)
  assert.equal(asked, 0)
})

test("Following splits a long follow list into 250-author filters", async () => {
  const follows = Array.from({ length: 600 }, (_, i) => i.toString(16).padStart(64, "0"))
  const sizes = []
  await fetchArticles({ scope: "following", follows, relays: ["wss://r"], vault: fakeVault(), online: true, query: async (r, f) => { sizes.push(f.authors.length); return [] } })
  assert.deepEqual(sizes, [250, 250, 100])
})
