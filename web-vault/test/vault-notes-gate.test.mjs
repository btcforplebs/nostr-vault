// The Vault's Notes list draws notes that tag you from people inside your web of trust but not followed. Like the
// Activity list beside it (stranger-media.test.mjs), a stranger's avatar, pictures, link-card previews, quoted note
// and reply-preview photo wait, or drawing the list would tell their servers your IP and when you read it. Feeds
// pass no `trusted` and load as before (Logen: feeds stay ungated). Rows are rendered as plain vnodes; nothing is fetched.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { noteEncode } from "nostr-tools/nip19"

registerHooks({
  load(url, context, next) {
    if (url.endsWith(".css")) return { format: "module", source: "", shortCircuit: true }
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { List } = await import("../src/screens/VaultScreen.jsx")
const { NoteCard, NoteBody } = await import("../src/components/NoteCard.jsx")
const { NoteText } = await import("../src/components/NoteText.jsx")
const { QuotedNote, QuoteCard } = await import("../src/components/QuotedNote.jsx")
const { ParentPreview, ParentCard } = await import("../src/components/ParentPreview.jsx")
const { LinkCard, mayFetchPreview, previewShown } = await import("../src/components/LinkCard.jsx")
const { AvatarMenu } = await import("../src/components/AuthorQuickMenu.jsx")
const { Avatar } = await import("../src/components/Avatar.jsx")
const { MediaImage } = await import("../src/components/MediaImage.jsx")

const ME = "1".repeat(64), FRIEND = "f".repeat(64), STRANGER = "5".repeat(64)
const trusted = pk => pk === ME || pk === FRIEND
const PIX = "https://tracker.example/pixel.png", PAGE = "https://tracker.example/page"
const FIPS = "http://npub1qqxjlqqqlr465efdc65pdqjzlm0tew3f3ca34u6p4yh6yn0edu6s79wkc6.fips/" + "e4".repeat(32)
const QUOTED = "a".repeat(64)
const note = (who, extra = {}) => ({ id: who.slice(0, 2).padEnd(64, "0"), kind: 1, pubkey: who, created_at: 1000,
  content: `hi ${PIX} ${PAGE} nostr:${noteEncode(QUOTED)}`, tags: [["p", ME]], sig: "", ...extra })

/** Every vnode of `type` in the tree (component vnodes are not expanded). */
function find(node, type, out = []) {
  if (!node || typeof node !== "object") return out
  if (Array.isArray(node)) { for (const n of node) find(n, type, out); return out }
  if (node.type === type) out.push(node)
  find(node.props?.children, type, out)
  return out
}
const one = (tree, type) => { const all = find(tree, type); assert.equal(all.length, 1, `one ${type.name ?? type}`); return all[0] }

test("Vault Notes: the list hands its trust to each note card, as Activity does", () => {
  const ev = note(STRANGER)
  const tree = List({ mode: "notes", filter: "all", items: [ev], trusted, page: { shown: Infinity, onMore: () => {} } })
  const card = tree.props.render(ev)
  assert.equal(card.type, NoteCard)
  assert.equal(card.props.trusted, trusted)
})

test("NoteCard passes its trust to the note body", () => {
  assert.equal(one(NoteCard({ event: note(STRANGER), trusted }).props.children, NoteBody).props.trusted, trusted)
})

test("NoteBody: a stranger's avatar, pictures and link cards wait; a follow's and yours load", () => {
  for (const [who, ok] of [[STRANGER, false], [FRIEND, true], [ME, true]]) {
    const tree = NoteBody({ event: note(who), trusted })
    assert.equal(one(tree, AvatarMenu).props.load, ok, "avatar")
    const text = one(tree, NoteText)
    assert.equal(text.props.images, ok, "images")
    assert.equal(text.props.trusted, trusted, "quotes inside get the same gate")
  }
})

test("NoteBody: a reply's parent preview gets the gate", () => {
  const reply = note(STRANGER, { tags: [["e", QUOTED, "", "root"], ["p", ME]] })
  assert.equal(one(NoteBody({ event: reply, trusted, showParent: true }), ParentPreview).props.trusted, trusted)
})

test("NoteText: with images off, link cards are plain (no fetch), the picture waits, a quote carries the gate", () => {
  const tree = NoteText({ content: note(STRANGER).content, author: STRANGER, linkCards: true, images: false, trusted })
  assert.equal(one(tree, LinkCard).props.load, false)
  assert.equal(find(tree, "img").length, 0, "no <img> for a stranger's picture")
  assert.equal(find(tree, MediaImage).length, 0)
  assert.equal(one(tree, QuotedNote).props.trusted, trusted)
  const on = NoteText({ content: note(FRIEND).content, author: FRIEND, linkCards: true, images: true, trusted })
  assert.equal(one(on, LinkCard).props.load, true)
})

test("LinkCard: off, it neither asks the page nor shows a preview read earlier", () => {
  assert.equal(mayFetchPreview("https://example.com/a-page", false), false)
  assert.equal(mayFetchPreview("https://example.com/a-page", true), true)
  const meta = { title: "T", image: "https://tracker.example/og.png" }
  assert.equal(previewShown(meta, false), undefined)
  assert.equal(previewShown(meta, true), meta)
})

test("QuoteCard: a quoted stranger's avatar and pictures wait; a quoted follow's load", () => {
  for (const [who, ok] of [[STRANGER, false], [FRIEND, true]]) {
    const tree = QuoteCard({ ev: note(who, { content: `look ${PIX}` }), trusted })
    assert.equal(one(tree, Avatar).props.load, ok)
    assert.equal(one(tree, NoteText).props.images, ok)
  }
})

test("ParentCard: a stranger's avatar stays blank and their https photo is left out; .fips stays with the mesh gate", () => {
  const parent = (who, url) => note(who, { content: `the parent ${url}` })
  const s = ParentCard({ ev: parent(STRANGER, PIX), trusted })
  assert.equal(one(s, AvatarMenu).props.load, false)
  assert.equal(find(s, MediaImage).length, 0)
  const f = ParentCard({ ev: parent(FRIEND, PIX), trusted })
  assert.equal(one(f, AvatarMenu).props.load, true)
  assert.deepEqual(find(f, MediaImage).map(m => m.props.item.url), [PIX])
  assert.equal(find(ParentCard({ ev: parent(STRANGER, FIPS), trusted }), MediaImage).length, 1)
})

test("Feeds pass no trust: everything loads as before", () => {
  const tree = NoteBody({ event: note(STRANGER) })
  assert.equal(one(tree, AvatarMenu).props.load, true)
  assert.equal(one(tree, NoteText).props.images, true)
  assert.equal(one(QuoteCard({ ev: note(STRANGER) }), Avatar).props.load, true)
  assert.equal(find(ParentCard({ ev: note(STRANGER, { content: PIX }) }), MediaImage).length, 1)
  assert.equal(one(NoteText({ content: PAGE, linkCards: true }), LinkCard).props.load, true)
})
