// One plan step 6b: Notifications in the Reader. Rows cross as plain strings (a stranger's picture left out), clicks
// open only routes the shell kept, Mentions filters as the screen does, and only the Reader is answered.
import test from "node:test"
import assert from "node:assert/strict"
import { shapeRow, notifAnswer, notifIntents, MAX_FACES } from "../src/napplet/reader-notifications.js"
import { createBus } from "../src/napplet/bus.js"
import { READER_DTAG } from "../src/napplet/first-party-list.js"

const H = c => c.repeat(64)
const ME = H("e"), ANN = H("a"), BOB = H("b")
const profiles = { [ANN]: { name: "Ann", picture: "https://x/a.png" }, [BOB]: { display_name: "Bob", picture: "https://x/b.png" } }
const myNote = { id: H("1"), pubkey: ME, kind: 1, content: "my note" }
const h = {
  me: ME, notes: new Map([[myNote.id, myNote]]), unreadSince: 100, known: pk => pk === ANN, profileOf: pk => profiles[pk],
  verbOf: r => `did ${r.type}`, whoOf: (who, nameOf) => who.map(nameOf).join(" and "),
  aboutOf: note => ({ parts: [note.content, { pubkey: BOB }], images: ["http://x/i.png", "https://x/j.png"] }),
  aboutYourPost: r => r.type === "reaction",
}
const reply = { id: "r1", type: "reply", who: [ANN], created_at: 150, events: [{ id: H("2"), content: "hi there" }] }
const like = { id: "r2", type: "reaction", who: [ANN, BOB], created_at: 50, noteId: myNote.id, events: [{ id: H("3") }] }
const follow = { id: "r3", type: "follow", who: [BOB], created_at: 60, events: [{ id: H("4") }] }
const hrefOf = r => (r.type === "reply" ? `#/thread/${r.events[0].id}` : r.type === "reaction" ? `#/thread/${r.noteId}` : null)

test("a row: their words, or your note they reacted to; faces with pictures only for people you know; unread by the visit mark", () => {
  const a = shapeRow(reply, h)
  assert.equal(a.text, "hi there"); assert.equal(a.about, null); assert.equal(a.unread, true); assert.equal(a.who, "Ann")
  const b = shapeRow(like, h)
  assert.equal(b.text, ""); assert.equal(b.unread, false)
  assert.deepEqual(b.about, { text: "my note @Bob", thumbs: ["https://x/j.png"], more: 0 })
  assert.deepEqual(b.faces, [{ name: "Ann", picture: "https://x/a.png" }, { name: "Bob", picture: "" }], "Bob isn't a follow: no picture")
  const many = shapeRow({ ...follow, who: Array.from({ length: 9 }, (_, i) => H(String(i))) }, h)
  assert.equal(many.faces.length, MAX_FACES)
  assert.equal(shapeRow({ ...like, noteId: H("9") }, h).about, null, "a note that isn't yours is never quoted")
})

test("answer: Mentions filters, the fold only under All, routes kept for rows that open, null while loading", () => {
  const list = { shown: [reply, like, follow], outside: [like], status: "", loading: false, more: { until: 5, done: false, busy: false } }
  const all = notifAnswer(list, "all", h, hrefOf)
  assert.deepEqual(all.data.rows.map(r => [r.id, r.open]), [["r1", true], ["r2", true], ["r3", false]])
  assert.equal(all.data.outside.length, 1); assert.equal(all.data.outsideCount, 2); assert.equal(all.data.done, false)
  assert.equal(all.routes.get("r1"), `#/thread/${H("2")}`); assert.equal(all.routes.has("r3"), false)
  const men = notifAnswer(list, "mentions", h, hrefOf)
  assert.deepEqual(men.data.rows.map(r => r.id), ["r1"]); assert.equal(men.data.outside.length, 0)
  assert.equal(notifAnswer({ ...list, shown: null }, "all", h, hrefOf).data.rows, null)
  assert.doesNotMatch(JSON.stringify(all.data), /#\//, "no route crosses")
})

test("intents: the Reader only; open only a row handed out; more asks for older", async () => {
  const opened = [], asked = []
  const bus = createBus()
  const reader = { dTag: READER_DTAG, send: () => {} }, other = { dTag: "nv-wot", send: () => {} }
  const list = { shown: [reply, follow], outside: [], status: "", loading: false, more: { until: 5, done: false, busy: false } }
  const off = notifIntents({ bus, answer: f => notifAnswer(list, f, h, hrefOf), more: () => asked.push(1), open: to => opened.push(to) })
  const ask = (from, action, payload = {}) => bus.invoke(from, { archetype: "notifications", action, payload })
  assert.equal((await ask(other, "list")).ok, false)
  assert.equal((await ask(other, "open", { id: "r1" })).ok, false)
  assert.equal((await ask(reader, "open", { id: "r1" })).ok, false, "nothing handed out yet")
  const l = await ask(reader, "list", { filter: "all" })
  assert.equal(l.data.rows.length, 2)
  assert.equal((await ask(reader, "open", { id: "r1" })).ok, true)
  assert.equal((await ask(reader, "open", { id: "r3" })).ok, false, "a row with nowhere to go")
  assert.equal((await ask(reader, "open", { id: "#/settings" })).ok, false)
  assert.equal((await ask(reader, "more")).ok, true)
  assert.deepEqual(opened, [`#/thread/${H("2")}`]); assert.equal(asked.length, 1)
  off()
  assert.equal((await ask(reader, "list")).ok, false)
})
