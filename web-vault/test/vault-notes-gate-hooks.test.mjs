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
const { LiveEmbed } = await import("../src/readers/LiveEmbed.jsx")
const { LiveTile } = await import("../src/readers/LiveScreen.jsx")
const { AvatarMenu } = await import("../src/components/AuthorQuickMenu.jsx")
const { NoteText } = await import("../src/components/NoteText.jsx")

const sk = generateSecretKey(), STRANGER = getPublicKey(sk) // throwaway keys
const fk = generateSecretKey(), FRIEND = getPublicKey(fk)
const trusted = () => false
const friendOnly = pk => pk === FRIEND
const signed = finalizeEvent({ kind: 1, created_at: 1000, content: "the quoted note https://tracker.example/p.png", tags: [] }, sk)
const friendNote = finalizeEvent({ kind: 1, created_at: 1000, content: "a follow's note https://media.example/p.png", tags: [] }, fk)
const stream = finalizeEvent({ kind: 30311, created_at: 1000, content: "", tags: [["d", "s1"], ["title", "On air"], ["status", "live"],
  ["image", "https://tracker.example/cover.jpg"], ["streaming", "https://tracker.example/live.m3u8"]] }, sk)
const cache = async (q, ev) => fetchQuote({ ...q, relays: ["wss://relay.example"] }, { save: false, query: async () => [ev] })
await cache({ type: "note", id: signed.id }, signed)
await cache({ type: "note", id: friendNote.id }, friendNote)
await cache({ type: "addr", kind: 30311, pubkey: STRANGER, d: "s1" }, stream)

function find(node, type, out = []) {
  if (!node || typeof node !== "object") return out
  if (Array.isArray(node)) { for (const n of node) find(n, type, out); return out }
  if (node.type === type) out.push(node)
  find(node.props?.children, type, out)
  return out
}

/** What a note body draws, expanded: whether its avatar and pictures load. */
const gate = body => { const t = NoteBody(body.props); return { avatar: find(t, AvatarMenu)[0].props.load, images: find(t, NoteText)[0].props.images } }
/** The NoteBody a card draws, through a fetched repost if it is one. */
function bodyOf(card) {
  const article = card.props.children
  const direct = find(article, NoteBody)
  if (direct.length) return direct[0]
  const holder = article.props.children.find(c => c?.props?.q) // FetchedRepost
  return find(holder.type(holder.props), NoteBody)[0]
}
const embed = (kind, inner, by = FRIEND) => ({ id: "6".repeat(64), kind, pubkey: by, created_at: 1001, content: JSON.stringify(inner),
  tags: [["e", inner.id], ["p", inner.pubkey], ...(kind === 16 ? [["k", "1"]] : [])], sig: "" })
const byId = (kind, inner, by = FRIEND) => ({ ...embed(kind, inner, by), content: "" })

test("Reposts in the Vault Notes list are gated on the reposted author, not the reposter", () => {
  for (const kind of [6, 16]) for (const shape of [embed, byId]) {
    const name = `kind ${kind} ${shape === embed ? "embedded" : "fetched by id"}`
    assert.deepEqual(gate(bodyOf(NoteCard({ event: shape(kind, signed), trusted: friendOnly }))), { avatar: false, images: false }, `${name}: a follow reposting a stranger`)
    assert.deepEqual(gate(bodyOf(NoteCard({ event: shape(kind, friendNote, STRANGER), trusted: friendOnly }))), { avatar: true, images: true }, `${name}: a stranger reposting a follow`)
  }
})

test("A stranger's live stream quoted in a Vault note draws its tile without the picture; a follow's or a feed's has it", () => {
  const q = { type: "addr", kind: 30311, pubkey: STRANGER, d: "s1", relays: [] }
  const imgs = t => { const e = QuotedNote({ q, short: "naddr1…", trusted: t }); assert.equal(e.type, LiveEmbed)
    const tile = find(LiveEmbed(e.props), LiveTile)[0]; return find(LiveTile(tile.props), "img").length }
  assert.equal(imgs(trusted), 0, "no <img> for a stranger's stream")
  assert.equal(imgs(pk => pk === STRANGER), 1)
  assert.equal(imgs(undefined), 1, "feeds pass no trust")
})

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
