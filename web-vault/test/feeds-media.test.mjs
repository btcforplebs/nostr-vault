// The Media feed: one tile per Following note with an image or video, as the iPhone's media grid.
import test from "node:test"
import assert from "node:assert/strict"
import { finalizeEvent, generateSecretKey } from "nostr-tools/pure"
import { mediaType, mediaUrls, mediaTiles, tileNote } from "../src/net/media.js"

const note = (id, content, extra = {}) => ({ id, kind: 1, pubkey: "a".repeat(64), created_at: 1, content, tags: [], ...extra })

test("images and videos by extension; other links aren't media", () => {
  assert.equal(mediaType("https://x.example/a.JPG?w=2"), "image")
  assert.equal(mediaType("https://x.example/clip.mp4"), "video")
  assert.equal(mediaType("https://x.example/page"), "")
})

test("a note's media: its text links (punctuation trimmed) and imeta urls, once each, in order", () => {
  const n = note("1", "look https://x.example/a.png, and https://x.example/v.webm. https://x.example/a.png https://x.example/page",
    { tags: [["imeta", "url https://x.example/b.gif", "m image/gif"], ["imeta", "url https://x.example/a.png"]] })
  assert.deepEqual(mediaUrls(n), ["https://x.example/a.png", "https://x.example/v.webm", "https://x.example/b.gif"])
})

test("one tile per note with media; a repost shows the note inside, once", () => {
  const inner = finalizeEvent({ kind: 1, created_at: 2, tags: [], content: "https://x.example/v.mp4 https://x.example/p.jpg" }, generateSecretKey())
  const tiles = mediaTiles([
    note("1", "just words"),
    { id: "r1", kind: 6, pubkey: "b".repeat(64), content: JSON.stringify(inner), tags: [] },
    inner,
    { id: "r2", kind: 6, pubkey: "b".repeat(64), content: "not json", tags: [] },
    note("3", "https://x.example/one.webp"),
  ])
  assert.deepEqual(tiles.map(t => [t.id, t.type, t.count]), [[inner.id, "video", 2], ["3", "image", 1]])
  assert.equal(tiles[0].url, "https://x.example/v.mp4")
  assert.equal(tileNote({ kind: 6, content: "{}" }), null)
})

test("tileNote: a kind 6's note counts only if its signature checks, so Compact and Threaded rows fetch a forged one by id", () => {
  const n = finalizeEvent({ kind: 1, created_at: 2, tags: [], content: "https://x.example/p.jpg" }, generateSecretKey())
  const repost = inner => ({ id: "r", kind: 6, pubkey: "b".repeat(64), content: JSON.stringify(inner), tags: [["e", n.id]] })
  assert.deepEqual(tileNote(repost(n)), n)
  assert.equal(tileNote(repost({ ...n, pubkey: "a".repeat(64), sig: "0".repeat(128) })), null, "Tron's probe: another pubkey, zero sig")
  assert.equal(tileNote(repost({ ...n, content: "https://x.example/other.jpg" })), null, "tampered content")
  assert.equal(tileNote(repost({ ...n, sig: undefined })), null, "no signature")
  assert.deepEqual(mediaTiles([repost({ ...n, pubkey: "a".repeat(64) })]), [], "no tile drawn as the forged author")
  const r = repost(n)
  assert.equal(tileNote(r), tileNote(r), "checked once per repost object")
})
