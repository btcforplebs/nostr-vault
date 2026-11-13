import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { FileNotesState } from "../src/net/file-notes.js"
import { emojiPart, savedCopyFor, EMOJI_NOTE_TAG } from "../src/net/emoji-notes.js"
import { withoutEmoji } from "../src/net/blossom-gallery.js"

// The emoji-note contract every platform shares (RESEARCH/NV_CUSTOM_EMOJI_PLAN.md §4.1), against docs/fixtures/emoji-notes.
const dir = new URL("../../docs/fixtures/emoji-notes/", import.meta.url)
const expected = JSON.parse(readFileSync(new URL("expected.json", dir), "utf8"))
const owner = "a".repeat(64)
const stateOf = file => {
  const s = new FileNotesState(owner)
  for (const ev of JSON.parse(readFileSync(new URL(file, dir), "utf8"))) s.apply(ev)
  return s
}

for (const [file, want] of Object.entries(expected)) {
  test(`fixture ${file}`, () => {
    const s = stateOf(file)
    assert.equal([...s.notes.values()].filter(n => n.emoji).length, want.emojiNotes, "emoji notes")
    assert.deepEqual([...s.emojiOnly()].sort(), [...want.hiddenFromMedia].sort(), "hidden from Media")
    const copies = s.emojiCopies()
    assert.deepEqual(Object.fromEntries([...copies].map(([sha, c]) => [sha, c.codes])), want.codes, "codes")
    assert.deepEqual(Object.fromEntries([...copies].map(([sha, c]) => [sha, c.sets])), want.sets, "sets")
  })
}

test("a plain note is not an emoji note", () => {
  assert.equal(emojiPart({ tags: [["x", "1"], ["t", "photo"], ["emoji", "a", "https://x.example/a.png"]] }), null)
  assert.deepEqual(emojiPart({ tags: [["t", EMOJI_NOTE_TAG]] }), { codes: [], sets: [] })
})

test("bad emoji and a tags are skipped, the note stays an emoji note", () => {
  const p = emojiPart({ tags: [["t", EMOJI_NOTE_TAG], ["emoji", "bad code", "https://x.example/a.png"], ["emoji", "ok", "http://x.example/a.png"],
    ["emoji", "good", "https://x.example/g.png"], ["emoji", "good", "https://x.example/g.png"], ["a", "30023:" + "b".repeat(64) + ":post"], ["a", "30030:" + "b".repeat(64) + ":s"]] })
  assert.deepEqual(p, { codes: [["good", "https://x.example/g.png"]], sets: ["30030:" + "b".repeat(64) + ":s"] })
})

test("deleting the plain note hides the image from Media; deleting the emoji note shows it again", () => {
  const s = stateOf("photo-and-emoji.json")
  const sha = "1".repeat(64)
  assert.equal(s.emojiOnly().has(sha), false)
  const plain = [...s.notes.values()].find(n => n.sha256 === sha && !n.emoji)
  const emoji = [...s.notes.values()].find(n => n.sha256 === sha && n.emoji)
  const del = (id, ids) => ({ id, pubkey: "c".repeat(64), created_at: 1794579999, kind: 5, content: "", sig: "s", tags: [...ids.map(i => ["e", i]), ["k", "1063"], ["x", sha], ["p", owner]] })
  const before = s.changes
  s.apply(del("d1", [plain.id]))
  assert.ok(s.changes > before, "a deletion that keeps the tile still counts as a change")
  assert.equal(s.emojiOnly().has(sha), true)
  s.apply(del("d2", [emoji.id]))
  assert.equal(s.emojiOnly().has(sha), false)
  assert.equal(s.emojiCopies().size, 0)
})

test("Media drops only the emoji-only hashes", () => {
  const blobs = [{ sha256: "1" }, { sha256: "2" }]
  assert.deepEqual(withoutEmoji(blobs, new Set(["1"])), [{ sha256: "2" }])
  assert.equal(withoutEmoji(blobs, new Set()), blobs)
  assert.equal(withoutEmoji(blobs, undefined), blobs)
})

test("saved copy found by link, then by shortcode within the set", () => {
  const copies = stateOf("two-codes.json").emojiCopies()
  const cats = { address: "30030:" + "b".repeat(64) + ":cats" }
  const dogs = { address: "30030:" + "b".repeat(64) + ":dogs" }
  assert.equal(savedCopyFor(copies, dogs, { code: "x", url: "https://b.example.com/p.gif" })?.sha256, "2".repeat(64), "same link, any set")
  assert.equal(savedCopyFor(copies, cats, { code: "party", url: "https://moved.example/party.gif" })?.sha256, "2".repeat(64), "code in its set")
  assert.equal(savedCopyFor(copies, dogs, { code: "party", url: "https://moved.example/party.gif" }), null, "code in another set")
})
