// What other people send you is read through your web of trust (src/net/web-trust.js; Logen 2026-11-04: strangers'
// replies got past it). Thread replies fold, comments, highlights and Tagged drop, and while the web loads only you,
// your follows and whoever the view names count.
import test from "node:test"
import assert from "node:assert/strict"
import { insideWeb, splitOutside } from "../src/net/web-trust.js"
import { insideEvents } from "../src/readers/engagement.js"
import { taggedNotes } from "../src/net/profile-tabs.js"

const pk = n => n.toString(16).padStart(64, "0")
const ME = pk(1), FOLLOW = pk(2), WEB = pk(3), STRANGER = pk(4), HOST = pk(5)
const trust = new Set([ME, FOLLOW, WEB])
const ev = (id, pubkey, extra = {}) => ({ id, pubkey, kind: 1, created_at: Number(id.replace(/\D/g, "")) || 1, tags: [], content: id, ...extra })

test("inside: you, the web, and whoever the view names; a stranger is out", () => {
  const opts = { me: ME, follows: [FOLLOW] }
  assert.equal(insideWeb(WEB, trust, opts), true)
  assert.equal(insideWeb(STRANGER, trust, opts), false, "the control: a stranger")
  assert.equal(insideWeb(HOST, trust, { ...opts, also: [HOST] }), true, "the host")
  assert.equal(insideWeb(ME, new Set(), opts), true, "you, with an empty web")
  assert.equal(insideWeb(null, trust, opts), false)
})

test("while the web loads it fails closed: only you, your follows and the named", () => {
  const opts = { me: ME, follows: [FOLLOW], also: [HOST] }
  assert.deepEqual([ME, FOLLOW, WEB, STRANGER, HOST].filter(p => insideWeb(p, null, opts)), [ME, FOLLOW, HOST])
})

test("a thread splits: outside replies fold, oldest first, and an inside reply under one moves up to its place", () => {
  const node = (event, children = []) => ({ event, children })
  const tree = [node(ev("r1", FOLLOW)), node(ev("r3", STRANGER), [node(ev("r4", WEB)), node(ev("r6", STRANGER))]), node(ev("r2", STRANGER))]
  const inside = p => insideWeb(p, trust, { me: ME })
  const { replies, outside } = splitOutside(tree, inside)
  assert.deepEqual(replies.map(n => n.event.id), ["r1", "r4"])
  assert.deepEqual(outside.map(e => e.id), ["r2", "r3", "r6"])
  const kept = splitOutside(tree, inside, e => e.id === "r3")
  assert.deepEqual(kept.replies.map(n => n.event.id), ["r1", "r3"], "the opened reply stays where it is")
  assert.deepEqual(kept.replies[1].children.map(n => n.event.id), ["r4"])
})

test("article comments and highlights from outside the web drop; likes and zaps still count", () => {
  const evs = [ev("c1", WEB, { kind: 1111 }), ev("c2", STRANGER, { kind: 1111 }), ev("n3", STRANGER, { kind: 1 }),
    ev("h4", STRANGER, { kind: 9802 }), ev("l5", STRANGER, { kind: 7 }), ev("z6", STRANGER, { kind: 9735 })]
  assert.deepEqual(insideEvents(evs, p => trust.has(p)).map(e => e.id), ["c1", "l5", "z6"])
})

test("Tagged keeps only the web's notes, and none by the profile's owner or someone blocked", () => {
  const evs = [ev("t1", WEB), ev("t2", STRANGER), ev("t3", FOLLOW), ev("t4", HOST)]
  assert.deepEqual(taggedNotes(evs, HOST, new Set([FOLLOW]), p => trust.has(p)).map(e => e.id), ["t1"])
  assert.deepEqual(taggedNotes(evs, HOST, new Set()).map(e => e.id), ["t1", "t2", "t3"], "no web check given")
})
