import test from "node:test"
import assert from "node:assert/strict"
import { parseFileNote, parseFileNoteDeletion, liveFilter, filesURL, authRelayURL, tileState, FileNotesState, RESUBSCRIBE_OVERLAP } from "../src/net/file-notes.js"

// NIP-94 file notes on the home vault's /files, read side only (the web writes no 1063 or kind 5).
// Ported from iOS FileNoteTests (MediaLogicTests), minus the write-side tag builders.
const sha = "ab".repeat(32), other = "cd".repeat(32), owner = "11".repeat(32), phone = "22".repeat(32), pad = "33".repeat(32)
const note = (id, { signer = phone, x = sha, at = 100, tags = [], p = owner, kind = 1063 } = {}) =>
  ({ id, pubkey: signer, created_at: at, kind, tags: [["x", x], ["m", "image/jpeg"], ["size", "38091"], ["p", p], ...tags], content: "", sig: "s" })
const deletion = (id, ids, { x = sha, at = 200, signer = pad } = {}) =>
  ({ id, pubkey: signer, created_at: at, kind: 5, tags: [...ids.map(i => ["e", i]), ["k", "1063"], ["x", x], ["p", owner]], content: "", sig: "s" })

test("parse reads a note", () => {
  const n = parseFileNote(note("n1", { tags: [["url", `https://a.example/${sha}.jpg`], ["fallback", `https://b.example/${sha}`]] }))
  assert.deepEqual(n, { id: "n1", signer: phone, createdAt: 100, sha256: sha, mime: "image/jpeg", size: 38091, owner,
    urls: [`https://a.example/${sha}.jpg`, `https://b.example/${sha}`] })
})

test("parse refuses bad notes", () => {
  assert.equal(parseFileNote(note("n", { x: "ABAB" })), null, "x must be 64 lower-case hex")
  assert.equal(parseFileNote(note("n", { x: sha.toUpperCase() })), null)
  assert.equal(parseFileNote(note("n", { kind: 1 })), null)
  assert.equal(parseFileNote({ ...note("n"), tags: [["x", sha], ["m", "image/jpeg"], ["p", owner]] }), null, "size required")
  assert.equal(parseFileNote({ ...note("n"), tags: [["x", sha], ["m", "image/jpeg"], ["size", "12abc"], ["p", owner]] }), null, "size is a whole number")
  assert.equal(parseFileNote({ ...note("n"), tags: [["x", sha], ["m", "image/jpeg"], ["size", "-1"], ["p", owner]] }), null)
  assert.equal(parseFileNote(note("n", { tags: [["p", pad]] })), null, "one p tag only")
  assert.equal(parseFileNote(note("")), null)
  assert.equal(parseFileNote(null), null)
})

test("parse keeps only https links", () => {
  const n = parseFileNote(note("n", { tags: [["url", "javascript:alert(1)"], ["fallback", "http://x.example/a"], ["fallback", `https://ok.example/${sha}`]] }))
  assert.deepEqual(n.urls, [`https://ok.example/${sha}`])
})

test("a deletion needs k 1063 and the notes it names", () => {
  assert.deepEqual([...parseFileNoteDeletion(deletion("d1", ["n1", "n2"])).noteIDs].sort(), ["n1", "n2"])
  assert.equal(parseFileNoteDeletion({ ...deletion("d2", ["n1"]), tags: [["e", "n1"], ["x", sha]] }), null)
  assert.equal(parseFileNoteDeletion(deletion("d3", [])), null)
})

test("a note for a new hash adds a tile, the same note twice changes nothing", () => {
  const s = new FileNotesState()
  assert.deepEqual(s.apply(note("n1")), { added: sha })
  assert.deepEqual(s.tiles().map(t => t.sha256), [sha])
  assert.equal(s.apply(note("n1")), null)
})

test("a second device's note for the same hash merges links, newest first", () => {
  const s = new FileNotesState()
  s.apply(note("n1", { tags: [["url", `https://a.example/${sha}`]] }))
  assert.equal(s.apply(note("n2", { signer: pad, at: 150, tags: [["url", `https://b.example/${sha}`]] })), null)
  assert.equal(s.tiles().length, 1)
  assert.deepEqual(s.tiles()[0].urls, [`https://b.example/${sha}`, `https://a.example/${sha}`])
})

test("tiles are newest first", () => {
  const s = new FileNotesState()
  s.apply(note("n1", { at: 100 }))
  s.apply(note("n2", { x: other, at: 300 }))
  assert.deepEqual(s.tiles().map(t => t.sha256), [other, sha])
})

test("a deletion drops the tile only when no live note names the hash", () => {
  const s = new FileNotesState()
  s.apply(note("n1")); s.apply(note("n2", { signer: pad }))
  assert.equal(s.apply(deletion("d1", ["n1"])), null, "n2 still names it")
  assert.deepEqual(s.tiles().map(t => t.sha256), [sha])
  assert.deepEqual(s.apply(deletion("d2", ["n2"])), { removed: sha })
  assert.deepEqual(s.tiles(), [])
})

test("a deleted note never comes back; a re-upload is a new note and lands", () => {
  const s = new FileNotesState()
  s.apply(deletion("d1", ["n1"]))
  assert.equal(s.apply(note("n1")), null, "the deletion came first (replay order)")
  assert.deepEqual(s.tiles(), [])
  assert.deepEqual(s.apply(note("n3", { at: 400 })), { added: sha })
})

test("the owner filter keeps other accounts out", () => {
  const s = new FileNotesState(owner)
  assert.equal(s.apply(note("n1", { p: pad })), null)
  assert.deepEqual(s.tiles(), [])
})

test("resubscribe since the newest seen, less the overlap", () => {
  const s = new FileNotesState()
  assert.equal(s.since(), undefined)
  s.apply(note("n1", { at: 1000 }))
  s.apply(deletion("d1", ["x"], { at: 2000 }))
  assert.equal(s.since(), 2000 - RESUBSCRIBE_OVERLAP)
})

test("the live filter asks for the owner's notes and deletions", () => {
  assert.deepEqual(liveFilter(owner), { kinds: [1063, 5], "#p": [owner] })
  assert.deepEqual(liveFilter(owner, 50), { kinds: [1063, 5], "#p": [owner], since: 50 })
})

test("AUTH names the vault's mesh address over the mesh, else the address dialled", () => {
  assert.equal(authRelayURL("npub1vault", "ws://127.0.0.1:41234/tok/files"), "ws://npub1vault.fips/files")
  assert.equal(authRelayURL(null, "wss://vault.local/files"), "wss://vault.local/files")
})

test("filesURL keeps the ingress token path", () => {
  assert.equal(filesURL("http://127.0.0.1:41234/tok"), "ws://127.0.0.1:41234/tok/files")
  assert.equal(filesURL("https://127.0.0.1:3355/"), "wss://127.0.0.1:3355/files")
  assert.equal(filesURL("not a url"), null)
})

test("a tile hides only when every server says 404 and the vault lacks it", () => {
  assert.equal(tileState([404, 404], false), "hidden")
  assert.equal(tileState([404, 404], null), "dimmed", "vault not asked: not proof")
  assert.equal(tileState([404, null], false), "dimmed", "unreachable is not gone")
  assert.equal(tileState([404, 200], false), "visible")
  assert.equal(tileState([], true), "visible")
  assert.equal(tileState([], false), "hidden")
  assert.equal(tileState([500], false), "dimmed")
})
