// Articles and Recipes against the iPhone: topic chips, a tappable author, Share and Copy link to
// nostrvault.app/thread/<nevent>, the locked meta, comment times, and the iPhone's empty states.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { decode } from "nostr-tools/nip19"
import { threadLink, shareLink, copyLink } from "../src/readers/share.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})

const A = "a".repeat(64), ID = "f".repeat(64)
const art = { id: ID, kind: 30023, pubkey: A, created_at: 100, content: "body", tags: [["d", "x"], ["title", "T"], ["t", "bitcoin"], ["t", "nostr"], ["t", "art"], ["t", "fourth"]] }

test("the share link is nostrvault.app/thread/<nevent> with id, author and kind", () => {
  const url = threadLink(art)
  assert.match(url, /^https:\/\/nostrvault\.app\/thread\/nevent1/)
  const d = decode(url.split("/").pop())
  assert.deepEqual([d.data.id, d.data.author, d.data.kind], [ID, A, 30023])
  assert.equal(threadLink({ ...art, id: "bad" }), null)
})

test("Share uses the system sheet when there is one, else copies; a cancelled sheet copies nothing", async () => {
  const copied = []
  const clip = { writeText: async u => copied.push(u) }
  assert.equal(await shareLink("u", "t", { share: async () => {}, clipboard: clip }), "shared")
  assert.equal(await shareLink("u", "t", { share: async () => { throw Object.assign(new Error(), { name: "AbortError" }) }, clipboard: clip }), "cancelled")
  assert.deepEqual(copied, [])
  assert.equal(await shareLink("u", "t", { clipboard: clip }), "copied")
  assert.equal(await copyLink("u", { clipboard: { writeText: async () => { throw new Error("denied") } } }), "failed")
  assert.deepEqual(copied, ["u"])
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
const { ArticleRow } = await import("../src/readers/ArticlesScreen.jsx")
const { RecipesEmpty } = await import("../src/readers/RecipesScreen.jsx")

test("a card shows its first three topics, and its author opens the profile without opening the article", () => {
  const nodes = walk(ArticleRow({ event: art, onOpen: () => {} }))
  const chips = nodes.filter(n => n.props?.class === "reader-topic").map(n => n.props.children)
  assert.deepEqual(chips, ["bitcoin", "nostr", "art"])
  const author = nodes.find(n => n.props?.class === "reader-author")
  assert.equal(author.props.href, `#/profile/${A}`)
  let stopped = false
  author.props.onClick({ stopPropagation: () => { stopped = true } })
  assert.ok(stopped)
})

test("Recipes' empty states are the iPhone's, each with its button", () => {
  let went = ""
  const f = RecipesEmpty({ scope: "following", failed: false, onGlobal: () => { went = "global" }, onRetry: () => { went = "retry" } })
  assert.match(text(f), /No recipes from your follows/)
  walk(f).find(n => n.type === "button").props.onClick()
  assert.equal(went, "global")
  assert.match(text(RecipesEmpty({ scope: "global", failed: true, onGlobal() {}, onRetry() {} })), /Could not reach any relay.*needs a connection.*Try again/)
  assert.match(text(RecipesEmpty({ scope: "global", failed: false, onGlobal() {}, onRetry() {} })), /No recipes found.*zapcooking or nostrcooking/)
})

test("wiring: reader Share/Copy, locked meta, empty Articles, comment time and thread, Recipes reader shows engagement, load failure ends", () => {
  const a = readFileSync(new URL("../src/readers/ArticlesScreen.jsx", import.meta.url), "utf8")
  assert.match(a, /shareLink\(web, displayTitle\(event\)\)/)
  assert.match(a, /copyLink\(web\)/)
  assert.match(a, /gated \? <><span>·<\/span><span class="reader-locked">🔒 Locked<\/span><\/> : minutes/)
  assert.match(a, /title="No articles yet"/)
  const e = readFileSync(new URL("../src/readers/Engagement.jsx", import.meta.url), "utf8")
  assert.match(e, /\{ago\(c\.created_at\)\}/)
  assert.match(e, /location\.hash = `#\/thread\/\$\{c\.id\}`/)
  const r = readFileSync(new URL("../src/readers/RecipesScreen.jsx", import.meta.url), "utf8")
  assert.match(r, /<ArticleReader event=\{open\} onBack=\{\(\) => setOpen\(null\)\} ctx=\{ctx\} \/>/)
  assert.match(r, /setFailed\(true\); setRecipes\(r => r \?\? \[\]\)/)
})
