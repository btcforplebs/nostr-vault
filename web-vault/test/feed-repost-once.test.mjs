// A repost can draw the same note twice in one feed view: two follows reposting it, or the note itself plus a repost of
// it (nv-parity 2026-11-10). applyFilters keeps each note once (oncePerNote).
import test from "node:test"
import assert from "node:assert/strict"
import { applyFilters, oncePerNote, FILTER_DEFAULTS } from "../src/net/feed-filters.js"

const id = c => c.repeat(64)
const A = "a".repeat(64), B = "b".repeat(64), C = "c".repeat(64)
const note = (nid, pubkey, at) => ({ id: nid, kind: 1, pubkey, created_at: at, content: "hello", tags: [] })
const repost = (rid, pubkey, at, target, author = A) => ({ id: rid, kind: 6, pubkey, created_at: at, content: "",
  tags: [["e", target], ["p", author]] })
const ids = list => list.map(n => n.id)

const X = id("1"), Y = id("2")

test("two reposts of one note show it once: the newest", () => {
  const feed = [repost(id("3"), B, 30, X), repost(id("4"), C, 20, X), note(Y, A, 10)]
  assert.deepEqual(ids(applyFilters(feed, FILTER_DEFAULTS)), [id("3"), Y])
})

test("a repost of a note already listed goes; the note stays where it is", () => {
  const feed = [repost(id("3"), B, 30, X), note(X, A, 10)]
  assert.deepEqual(ids(applyFilters(feed, FILTER_DEFAULTS)), [X])
})

test("an embedded repost (no e tag) is matched by the note it carries", () => {
  const inner = note(X, A, 10)
  const emb = { id: id("5"), kind: 6, pubkey: B, created_at: 30, content: JSON.stringify(inner), tags: [["p", A]] }
  assert.deepEqual(ids(oncePerNote([emb, { ...emb, id: id("6"), pubkey: C, created_at: 25 }, note(Y, A, 5)])), [id("5"), Y])
})

test("a kind 16 of an article is matched by its address", () => {
  const art = { id: id("7"), kind: 30023, pubkey: A, created_at: 10, content: "", tags: [["d", "post"]] }
  const g = { id: id("8"), kind: 16, pubkey: B, created_at: 30, content: "", tags: [["a", `30023:${A}:post`], ["k", "30023"]] }
  assert.deepEqual(ids(oncePerNote([g, art])), [art.id])
})

test("different notes' reposts, and a repost naming nothing, all stay", () => {
  const bare = { id: id("9"), kind: 6, pubkey: C, created_at: 5, content: "", tags: [] }
  const feed = [repost(id("3"), B, 30, X), repost(id("4"), C, 20, Y), bare]
  assert.deepEqual(ids(oncePerNote(feed)), ids(feed))
})

test("no two drawn rows show the same note in a mixed fixture", () => {
  const feed = [repost(id("3"), B, 50, X), note(Y, C, 40), repost(id("4"), C, 30, Y), repost(id("6"), A, 25, X), note(X, A, 10)]
  const shown = applyFilters(feed, FILTER_DEFAULTS)
  const what = shown.map(n => (n.kind === 6 ? n.tags.find(t => t[0] === "e")[1] : n.id))
  assert.equal(new Set(what).size, what.length, `duplicate in ${what}`)
  assert.deepEqual(ids(shown), [Y, X])
})

test("the same repost event listed twice draws once", () => {
  const r = repost(id("3"), B, 30, X)
  assert.deepEqual(ids(oncePerNote([r, { ...r }, note(Y, A, 10), note(Y, A, 10)])), [id("3"), Y])
})
