// One plan step 7: Search in the Reader. People cross as plain strings, notes as the screen's own results; a person,
// tag or stream opens only if handed out (a tag only if it is a tag); a filter must name a real Who and When; and
// only the Reader is answered.
import test from "node:test"
import assert from "node:assert/strict"
import { personRow, filterOf, searchAnswer, searchIntents } from "../src/napplet/reader-search.js"
import { createBus } from "../src/napplet/bus.js"
import { READER_DTAG } from "../src/napplet/first-party-list.js"

const H = c => c.repeat(64)
const ANN = H("a"), BOB = H("b"), CAT = H("c")
const profiles = { [ANN]: { name: "Ann", nip05: "_@ann.example", picture: "https://x/a.png" }, [BOB]: { display_name: "Bob", picture: "http://x/b.png" } }
const helpers = { profileOf: pk => profiles[pk], npubOf: pk => `npub1${pk.slice(0, 20)}`, liveRowsOf: list => ({ rows: list, more: 0 }) }
const note = { id: H("1"), pubkey: ANN, kind: 1, content: "hello #nostr", sig: "s" }
const search = {
  text: "hello", filter: { who: "everyone", when: "any" }, finished: true, found: { people: [ANN], notes: [note] },
  sources: [{ id: "haven", label: "This browser", state: "found", count: 2 }],
  shown: { people: [ANN], notes: [note], hashtags: ["nostr", "bad tag"], links: [{ url: "https://site.example/a", title: "A" }, { url: "javascript:x", title: "x" }], outsidePeople: [BOB], outsideNotes: [] },
}
const start = { liveStreams: [{ address: "30311:x:show", host: CAT, title: "On air" }], forYou: { people: [{ pubkey: CAT, vouches: 3 }], topics: ["art"], notes: [] }, trending: ["zap"], active: [ANN, CAT] }

test("a person row: name, nip05 (or npub), https picture only", () => {
  assert.deepEqual(personRow(ANN, helpers.profileOf, helpers.npubOf), { id: ANN, name: "Ann", sub: "ann.example", picture: "https://x/a.png" })
  const b = personRow(BOB, helpers.profileOf, helpers.npubOf)
  assert.equal(b.name, "Bob"); assert.equal(b.picture, ""); assert.match(b.sub, /^npub1/)
})

test("filter: only a real Who and When", () => {
  assert.deepEqual(filterOf({ who: "follows", when: "week" }), { who: "follows", when: "week" })
  for (const f of [null, {}, { who: "all", when: "any" }, { who: "you", when: "year" }]) assert.equal(filterOf(f), null)
})

test("answer: results shaped, bad tags and non-http links dropped, Active only named people, handed-out sets", () => {
  const a = searchAnswer({ search, start, recent: ["hello"] }, helpers)
  assert.deepEqual(a.data.results.hashtags, ["nostr"])
  assert.deepEqual(a.data.results.links, [{ url: "https://site.example/a", title: "A", host: "site.example" }])
  assert.equal(a.data.results.notes[0].id, note.id)
  assert.deepEqual(a.data.start.active.map(p => p.id), [ANN], "Cat has no name: not Active")
  assert.equal(a.data.start.forYou.people[0].vouches, 3)
  assert.deepEqual([...a.people].sort(), [ANN, BOB, CAT].sort())
  assert.ok(a.streams.has("30311:x:show"))
  assert.equal(a.data.caption, null)
})

test("intents: the Reader only; open a handed-out person or a real tag; live only a handed-out stream; query keeps a bad filter out", async () => {
  const opened = [], played = [], ctl = { text: [], filters: [], setText: t => ctl.text.push(t), setFilter: f => ctl.filters.push(f), submit: go => go(ANN), clear: () => {}, forget: () => {} }
  const bus = createBus()
  const reader = { dTag: READER_DTAG, send: () => {} }, other = { dTag: "nv-compose", send: () => {} }
  const off = searchIntents({ bus, pipe: { ctl, answer: () => searchAnswer({ search, start, recent: [] }, helpers) }, openHash: h => opened.push(h), play: s => played.push(s.address) })
  const ask = (from, action, payload = {}) => bus.invoke(from, { archetype: "search", action, payload })
  assert.equal((await ask(other, "state")).ok, false)
  assert.equal((await ask(other, "query", { text: "x" })).ok, false)
  assert.equal((await ask(reader, "open", { kind: "person", id: ANN })).ok, false, "nothing handed out yet")
  assert.equal((await ask(reader, "state")).ok, true)
  assert.equal((await ask(reader, "open", { kind: "person", id: ANN })).ok, true)
  assert.equal((await ask(reader, "open", { kind: "person", id: H("d") })).ok, false)
  assert.equal((await ask(reader, "open", { kind: "tag", tag: "nostr" })).ok, true)
  assert.equal((await ask(reader, "open", { kind: "tag", tag: "../settings" })).ok, false)
  assert.equal((await ask(reader, "open", { kind: "route", id: "#/settings" })).ok, false)
  assert.equal((await ask(reader, "live", { id: "30311:x:show" })).ok, true)
  assert.equal((await ask(reader, "live", { id: "30311:y:other" })).ok, false)
  await ask(reader, "query", { text: "abc", filter: { who: "everyone", when: "forever" } })
  await ask(reader, "query", { filter: { who: "you", when: "day" } })
  assert.deepEqual(ctl.text, ["abc"]); assert.deepEqual(ctl.filters, [{ who: "you", when: "day" }])
  await ask(reader, "submit")
  assert.deepEqual(opened, [`#/profile/${ANN}`, "#/feed?tag=nostr", `#/profile/${ANN}`])
  assert.deepEqual(played, ["30311:x:show"])
  off()
  assert.equal((await ask(reader, "state")).ok, false)
})
