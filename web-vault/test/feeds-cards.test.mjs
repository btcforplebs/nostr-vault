// The Feed's cards: Global and Hashtag cards are strangers', so the quotes and @names inside them load into memory
// only (memoryOnly), and a page where every note is blocked still offers Older.
// Node can't load .jsx, so a load hook compiles it with Vite's Oxc transform via rolldown (as in note-text.test.mjs).
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { npubEncode, noteEncode } from "nostr-tools/nip19"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { NoteText, Mention } = await import("../src/components/NoteText.jsx")
const { QuotedNote } = await import("../src/components/QuotedNote.jsx")
const { NoteCard } = await import("../src/components/NoteCard.jsx")
const { Notes } = await import("../src/screens/FeedScreen.jsx")
const { OlderButton } = await import("../src/components/FeedExtras.jsx")

const A = "a".repeat(64)
const refs = `nostr:${npubEncode(A)} nostr:${noteEncode("b".repeat(64))}`
const elements = node => [node.props.children].flat(Infinity).filter(c => c && typeof c === "object")
const body = card => elements(card.props.children).find(e => e.type.name === "NoteBody") // inside NoteCard's Undeleted gate

test("a stranger's text passes memoryOnly to its @names and quotes", () => {
  const [mention, quote] = elements(NoteText({ content: refs, memoryOnly: true }))
  assert.equal(mention.type, Mention); assert.equal(mention.props.memoryOnly, true)
  assert.equal(quote.type, QuotedNote); assert.equal(quote.props.memoryOnly, true)
  const [m2, q2] = elements(NoteText({ content: refs }))
  assert.equal(m2.props.memoryOnly, false, "Following cards still save to Haven")
  assert.equal(q2.props.memoryOnly, false)
})

test("a stranger's card and a stranger's repost pass memoryOnly down to the note text", () => {
  const note = { id: "1", kind: 1, pubkey: A, created_at: 1, content: refs }
  assert.equal(body(NoteCard({ event: note, memoryOnly: true })).props.memoryOnly, true)
  assert.equal(body(NoteCard({ event: note })).props.memoryOnly, false)
  const repost = { id: "2", kind: 6, pubkey: A, created_at: 2, content: JSON.stringify(note), tags: [["e", "1"], ["p", A]] }
  assert.equal(body(NoteCard({ event: repost, memoryOnly: true })).props.memoryOnly, true)
})

test("Global and Hashtag cards are memoryOnly; Following cards aren't", () => {
  const notes = [{ id: "1", kind: 1, pubkey: A, created_at: 1, content: "" }]
  const [card] = elements(Notes({ shown: notes, onOlder() {}, memoryOnly: true })).flat()
  assert.equal(card.props.memoryOnly, true)
  assert.equal(elements(Notes({ shown: notes, onOlder() {} })).flat()[0].props.memoryOnly, false)
})

test("when every loaded note is blocked, the message shows and Older is still there", () => {
  const onOlder = () => {}
  const [msg, older] = elements(Notes({ shown: [], onOlder }))
  assert.equal(msg.type, "p"); assert.match(msg.props.children, /someone you blocked/)
  assert.equal(older.type, OlderButton); assert.equal(older.props.onOlder, onOlder)
})

test("Popular has no Older: it's one ranked page", () => {
  const notes = [{ id: "1", kind: 1, pubkey: A, created_at: 1, content: "" }]
  assert.ok(!elements(Notes({ shown: notes, onOlder: null, memoryOnly: true })).some(e => e.type === "button" || e.type === OlderButton))
})

test("Media shows the grid, or says why it's empty, and always offers Older", async () => {
  const { Media } = await import("../src/screens/FeedScreen.jsx")
  const { MediaGrid } = await import("../src/components/MediaGrid.jsx")
  const onOlder = () => {}
  const tiles = [{ id: "1", url: "https://x.example/a.png", type: "image", count: 1 }]
  const [grid, older] = elements(Media({ tiles, blockedAll: false, onOlder }))
  assert.equal(grid.type, MediaGrid); assert.equal(older.type, OlderButton); assert.equal(older.props.onOlder, onOlder)
  assert.match(elements(Media({ tiles: [], blockedAll: false, onOlder }))[0].props.children, /No photos or videos/)
  assert.match(elements(Media({ tiles: [], blockedAll: true, onOlder }))[0].props.children, /someone you blocked/)
  const [img, vid] = elements(MediaGrid({ tiles: [...tiles, { id: "2", url: "https://x.example/v.mp4", type: "video", count: 1 }] }))
  assert.equal(img.props.href, "#/thread/1", "a tap opens the note")
  assert.equal(elements(vid)[0].type, "video"); assert.equal(elements(vid)[0].props.preload, "metadata", "only enough to show a frame")
})
