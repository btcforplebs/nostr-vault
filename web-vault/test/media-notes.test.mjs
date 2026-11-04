import test from "node:test"
import assert from "node:assert/strict"
import { sha256Of, notesUsing, vaultNotesUsing, notePreview } from "../src/net/media-notes.js"

// The media viewer's swipe up, on the web the Blossom dialog's "Posted in N notes". iOS MediaNoteMatchTests.
const sha = "ab".repeat(32)
const url = `https://blossom.example/${sha}.jpg`
const note = (id, at, { kind = 1, content = "", tags = [] } = {}) => ({ id, kind, created_at: at, content, tags, pubkey: "p" })

test("the hash is read from a Blossom name, with or without its extension", () => {
  assert.equal(sha256Of(url), sha)
  assert.equal(sha256Of(`https://b.example/${sha.toUpperCase()}`), sha)
  assert.equal(sha256Of("https://img.example/photo.jpg"), null)
})

test("every note naming the file by URL, hash or imeta, newest first, once", () => {
  const mirror = `https://mirror.example/${sha}.png`
  const found = notesUsing([
    note("byURL", 10, { content: `look ${url}` }),
    note("byMirror", 30, { content: `same file elsewhere ${mirror}` }),
    note("byImeta", 20, { kind: 20, tags: [["imeta", `url ${mirror}`, `x ${sha}`]] }),
    note("byX", 25, { kind: 1063, tags: [["x", sha]] }),
    note("unrelated", 40, { content: "https://img.example/other.jpg" }),
    note("reaction", 50, { kind: 7, content: url }),
    note("byURL", 10, { content: `look ${url}` }),
  ], url)
  assert.deepEqual(found.map(n => n.id), ["byMirror", "byX", "byImeta", "byURL"])
})

test("a file with no hash in its name matches by its URL only", () => {
  const plain = "https://img.example/photo.jpg"
  const found = notesUsing([note("yes", 1, { content: "https://IMG.example/photo.jpg" }), note("no", 2, { content: "https://img.example/photo2.jpeg" })], plain)
  assert.deepEqual(found.map(n => n.id), ["yes"])
})

test("the vault's outbox and inbox are read locally, nothing else", async () => {
  const asked = []
  const store = evs => ({ query: async f => { asked.push(f); return evs } })
  const vault = { outbox: store([note("mine", 5, { content: url })]), inbox: store([note("theirs", 9, { tags: [["imeta", `x ${sha}`]] })]), feed: { query: async () => { throw new Error("feed must not be read") } } }
  const found = await vaultNotesUsing(vault, { url, sha256: sha })
  assert.deepEqual(found.map(n => n.id), ["theirs", "mine"])
  assert.equal(asked.length, 2)
})

test("the preview folds links away", () => {
  assert.equal(notePreview(`Morning light ${url} over the river`), "Morning light over the river")
  assert.equal(notePreview(url), "(media only)")
})
