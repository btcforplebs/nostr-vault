// buildThread() turns a bag of kind 1 events into a reply tree from NIP-10 `e` tags, marked and positional.
import test from "node:test"
import assert from "node:assert/strict"
import { buildThread, flattenThread, replyRefs, rootIdOf } from "../src/net/thread.js"

const id = c => c.repeat(64) // a readable fake event id: id("a") is "aaaa…"
let clock = 1_760_000_000
const note = (i, tags = [], extra = {}) => ({ id: id(i), kind: 1, pubkey: id("f"), created_at: clock++, content: i, tags, ...extra })
const shape = nodes => nodes.map(n => (n.children.length ? { [n.event.content]: shape(n.children) } : n.event.content))

test("marked tags: root and reply markers place each note under its parent", () => {
  const root = note("a")
  const r1 = note("b", [["e", id("a"), "", "root"]])
  const r2 = note("c", [["e", id("a"), "", "root"], ["e", id("b"), "", "reply"]])
  const r3 = note("d", [["e", id("a"), "wss://x", "root"], ["e", id("c"), "wss://x", "reply"], ["p", id("f")]])
  const t = buildThread(id("a"), [r3, r1, root, r2])
  assert.equal(t.root, root)
  assert.equal(t.count, 3)
  assert.deepEqual(shape(t.replies), [{ b: [{ c: ["d"] }] }])
})

test("marked tags: a mention marker is not the parent", () => {
  const t = buildThread(id("a"), [
    note("a"), note("b", [["e", id("a"), "", "root"]]),
    note("c", [["e", id("a"), "", "root"], ["e", id("b"), "", "mention"]]),
  ])
  assert.deepEqual(shape(t.replies), ["b", "c"])
})

test("marked tags: a note with only mention markers is not a reply", () => {
  assert.deepEqual(replyRefs(note("z", [["e", id("a"), "", "mention"]])), { root: null, parent: null })
  assert.equal(buildThread(id("a"), [note("a"), note("z", [["e", id("a"), "", "mention"]])]).count, 0)
})

test("marked tags: a reply marker with no root marker is root and parent both", () => {
  assert.deepEqual(replyRefs(note("b", [["e", id("a"), "", "reply"]])), { root: id("a"), parent: id("a") })
})

test("old positional tags: one e is the root, first/last is root/parent, the middle ones are mentions", () => {
  const t = buildThread(id("a"), [
    note("a"),
    note("b", [["e", id("a")]]),
    note("c", [["e", id("a")], ["e", id("b")]]),
    note("d", [["e", id("a")], ["e", id("9")], ["e", id("c")]]),
  ])
  assert.deepEqual(shape(t.replies), [{ b: [{ c: ["d"] }] }])
})

test("a reply to a reply that tags only its parent still joins the thread", () => {
  const t = buildThread(id("a"), [note("a"), note("b", [["e", id("a")]]), note("c", [["e", id("b"), "", "reply"]])])
  assert.deepEqual(shape(t.replies), [{ b: ["c"] }])
})

test("a missing root: root is null and its replies are still listed", () => {
  const t = buildThread(id("a"), [note("b", [["e", id("a"), "", "root"]]), note("c", [["e", id("a"), "", "root"], ["e", id("b"), "", "reply"]])])
  assert.equal(t.root, null)
  assert.deepEqual(shape(t.replies), [{ b: ["c"] }])
})

test("a reply whose parent wasn't fetched hangs off the root, not dropped", () => {
  const t = buildThread(id("a"), [note("a"), note("c", [["e", id("a"), "", "root"], ["e", id("b"), "", "reply"]])])
  assert.deepEqual(shape(t.replies), ["c"])
})

test("other threads, duplicates, non-kind-1 and self-tags are left out", () => {
  const b = note("b", [["e", id("a"), "", "root"]])
  const t = buildThread(id("a"), [
    note("a"), b, b,
    note("x", [["e", id("9"), "", "root"]]), // another thread
    note("y", [["e", id("a"), "", "root"]], { kind: 7 }), // a reaction
    note("s", [["e", id("s")]]), // tags itself only
  ])
  assert.deepEqual(shape(t.replies), ["b"])
})

test("a tag loop between two replies doesn't hang or lose them", () => {
  const t = buildThread(id("a"), [
    note("a"),
    note("b", [["e", id("a"), "", "root"], ["e", id("c"), "", "reply"]]),
    note("c", [["e", id("a"), "", "root"], ["e", id("b"), "", "reply"]]),
  ])
  assert.equal(t.count, 2)
  assert.equal(flattenThread(t.replies).length, 2)
})

test("replies are oldest first at every level; flattenThread gives depth", () => {
  const late = note("c", [["e", id("a"), "", "root"]], { created_at: 9e9 })
  const early = note("b", [["e", id("a"), "", "root"]], { created_at: 1 })
  const child = note("d", [["e", id("a"), "", "root"], ["e", id("c"), "", "reply"]])
  const t = buildThread(id("a"), [note("a"), late, child, early])
  assert.deepEqual(flattenThread(t.replies).map(r => [r.event.content, r.depth]), [["b", 1], ["c", 1], ["d", 2]])
})

test("rootIdOf: a reply points at its root, a top-level note at itself", () => {
  assert.equal(rootIdOf(note("c", [["e", id("a"), "", "root"], ["e", id("b"), "", "reply"]])), id("a"))
  assert.equal(rootIdOf(note("a")), id("a"))
})
