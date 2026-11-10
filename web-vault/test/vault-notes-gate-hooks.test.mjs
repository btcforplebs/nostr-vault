// vault-notes-gate.test.mjs, for the hops that use hooks: a quoted note, a reply's parent and a repost fetched by id
// hand the Vault Notes trust on to what they draw. preact/hooks is stubbed (state is its first value, effects don't
// run), so each component is called once as a plain function; the quoted and parent notes come from the quote cache.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { finalizeEvent, generateSecretKey, getPublicKey } from "nostr-tools/pure"

const HOOKS = "data:text/javascript," + encodeURIComponent(`
  export const useState = i => [typeof i === "function" ? i() : i, () => {}]
  export const useEffect = () => {}, useLayoutEffect = () => {}, useContext = () => undefined
  export const useRef = v => ({ current: v ?? null }), useMemo = f => f(), useCallback = f => f
  export const useReducer = (r, i) => [i, () => {}]`)
registerHooks({
  resolve(spec, context, next) {
    if (spec === "preact/hooks" && context.parentURL?.includes("/src/")) return { url: HOOKS, shortCircuit: true }
    return next(spec, context)
  },
  load(url, context, next) {
    if (url.endsWith(".css")) return { format: "module", source: "", shortCircuit: true }
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { NoteCard, NoteBody } = await import("../src/components/NoteCard.jsx")
const { QuotedNote, QuoteCard } = await import("../src/components/QuotedNote.jsx")
const { ParentPreview, ParentCard } = await import("../src/components/ParentPreview.jsx")
const { LinkCard } = await import("../src/components/LinkCard.jsx")
const { fetchQuote } = await import("../src/net/quotes.js")

const sk = generateSecretKey(), STRANGER = getPublicKey(sk) // a throwaway key
const trusted = () => false
const signed = finalizeEvent({ kind: 1, created_at: 1000, content: "the quoted note https://tracker.example/p.png", tags: [] }, sk)
await fetchQuote({ type: "note", id: signed.id, relays: ["wss://relay.example"] }, { save: false, query: async () => [signed] })

function find(node, type, out = []) {
  if (!node || typeof node !== "object") return out
  if (Array.isArray(node)) { for (const n of node) find(n, type, out); return out }
  if (node.type === type) out.push(node)
  find(node.props?.children, type, out)
  return out
}

test("QuotedNote hands its trust to the quote card it draws", () => {
  const tree = QuotedNote({ q: { type: "note", id: signed.id, relays: [] }, short: "note1…", trusted })
  assert.equal(tree.type, QuoteCard)
  assert.equal(tree.props.trusted, trusted)
})

test("ParentPreview hands its trust to the parent card it draws", () => {
  const tree = ParentPreview({ id: signed.id, trusted })
  assert.equal(tree.type, ParentCard)
  assert.equal(tree.props.trusted, trusted)
})

test("A repost carrying only the e tag: the fetched note's body gets the trust", () => {
  const repost = { id: "6".repeat(64), kind: 6, pubkey: "1".repeat(64), created_at: 1001, content: "", tags: [["e", signed.id], ["p", STRANGER]], sig: "" }
  const article = NoteCard({ event: repost, trusted }).props.children
  const holder = find(article, NoteBody).length ? null : article.props.children.find(c => c?.props?.q) // FetchedRepost
  assert.ok(holder, "an e-tag-only repost is fetched by id")
  assert.equal(holder.props.trusted, trusted, "FetchedRepost gets the trust")
  const body = find(holder.type(holder.props), NoteBody)[0]
  assert.equal(body.props.trusted, trusted, "and hands it to the note's body")
})

test("LinkCard off draws the plain card, no preview image", () => {
  const tree = LinkCard({ url: "https://example.com/a-page", load: false })
  assert.ok(!String(tree.props.class).includes("rich"))
  assert.equal(find(tree, "img").length, 0)
})

test("AvatarMenu passes load on to the avatar it draws", async () => {
  const { AvatarMenu } = await import("../src/components/AuthorQuickMenu.jsx")
  const { Avatar } = await import("../src/components/Avatar.jsx")
  for (const load of [false, true]) assert.equal(find(AvatarMenu({ pubkey: STRANGER, load }), Avatar)[0].props.load, load)
})
