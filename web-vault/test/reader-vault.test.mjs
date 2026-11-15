// One plan step 8a: the Vault's list pages in the Reader. Your notes cross as signed events, other lines as strings
// (a stranger's picture left out), only the rows drawn so far; pages and filters only by their real names; a row opens
// only if handed out; the Reader alone is answered.
import test from "node:test"
import assert from "node:assert/strict"
import { vaultAnswer, vaultIntents, emptyText } from "../src/napplet/reader-vault.js"
import { createBus } from "../src/napplet/bus.js"
import { READER_DTAG } from "../src/napplet/first-party-list.js"

const H = c => c.repeat(64)
const ME = H("e"), ANN = H("a"), BOB = H("b")
const profiles = { [ANN]: { name: "Ann", picture: "https://x/a.png" }, [BOB]: { name: "Bob", picture: "https://x/b.png" }, [ME]: { name: "Me" } }
const h = { profileOf: pk => profiles[pk], verbOf: r => `did ${r.kind}`, whoOf: (a, nameOf) => a.map(nameOf).join(" and "), hrefOf: r => (r.openId ? `#/thread/${r.openId}` : `#/profile/${r.actors[0]}`), formatSats: n => String(n), now: 10000 }
const base = { me: ME, filter: "", fresh: new Set(["likes"]), status: "", loaded: true, ready: true, paging: false, older: { own: false, inbound: false }, notes: new Map(), followers: [], unreadSince: 50, trusted: pk => pk === ANN || pk === ME }

test("Vault lines: strings, unread by the visit mark, thumbs only from someone you trust, routes kept", () => {
  const items = [{ id: "l1", kind: "reply", actors: [ANN], preview: "hello", created_at: 60, openId: H("1"), images: ["https://x/i.png"], imagesBy: ANN },
    { id: "l2", kind: "like", actors: [BOB], preview: "my note", created_at: 40, openId: H("2"), images: ["https://x/j.png"], imagesBy: BOB }]
  const a = vaultAnswer({ ...base, mode: "activity", items, shown: 30 }, h)
  assert.equal(a.data.kind, "lines")
  assert.deepEqual(a.data.rows.map(r => [r.text, r.about, r.unread, r.thumbs.length]), [["hello", "", true, 1], ["", "my note", false, 0]])
  assert.equal(a.data.rows[1].faces[0].picture, "", "Bob isn't trusted")
  assert.equal(a.routes.get("l1"), `#/thread/${H("1")}`)
  assert.deepEqual(a.data.modes.find(m => m.id === "likes"), { id: "likes", title: "Likes", fresh: true })
  assert.doesNotMatch(JSON.stringify(a.data), /#\//)
})

test("notes are the signed events, only the rows drawn so far; more when Haven may hold older", () => {
  const evs = [1, 2, 3].map(i => ({ id: H(String(i)), kind: 1, pubkey: ME, content: `n${i}`, created_at: i, sig: "s" }))
  const a = vaultAnswer({ ...base, mode: "notes", items: evs, shown: 2 }, h)
  assert.equal(a.data.kind, "events"); assert.equal(a.data.rows.length, 2); assert.equal(a.data.rows[0], evs[0]); assert.equal(a.data.more, true)
  assert.equal(vaultAnswer({ ...base, mode: "notes", items: evs, shown: 30 }, h).data.more, false)
  assert.equal(vaultAnswer({ ...base, mode: "notes", items: evs, shown: 30, older: { own: true } }, h).data.more, true)
})

test("likes and zaps: who, what, the note's line; yours says You and who you paid", () => {
  const note = { id: H("9"), pubkey: ME, kind: 1, content: "my words", tags: [] }
  const rows = [{ id: "z1", type: "zap", who: [ME], to: ANN, sats: 21, noteId: H("8"), created_at: 5 }, { id: "k1", type: "reaction", who: [ANN], emoji: "❤️", noteId: note.id, created_at: 4 }]
  const a = vaultAnswer({ ...base, mode: "zaps", items: rows, shown: 30, notes: new Map([[note.id, note]]) }, h)
  assert.equal(a.data.kind, "engage")
  assert.equal(a.data.rows[0].who, "You"); assert.match(a.data.rows[0].what, /zapped Ann 21 sats/); assert.deepEqual(a.data.rows[0].about, { name: "", text: "a note" })
  assert.equal(a.data.rows[1].what, "liked"); assert.deepEqual(a.data.rows[1].about, { name: "Me", text: "my words" })
})

test("followers: people with when; counted; empty texts in the screen's words", () => {
  const a = vaultAnswer({ ...base, mode: "followers", items: [{ pubkey: BOB, at: 10000 - 7200 }], shown: 30, followers: [1] }, h)
  assert.equal(a.data.kind, "people"); assert.equal(a.data.rows[0].sub, "followed you 2h ago"); assert.equal(a.data.count, 1); assert.equal(a.data.rows[0].picture, "")
  assert.equal(a.routes.get(BOB), `#/profile/${BOB}`)
  assert.match(emptyText("articles", "recipes"), /zapcooking/)
  assert.match(emptyText("followers", "", 3), /filter lists the ones outside/)
})

test("intents: the Reader only; real pages and filters only; a row only if handed out; dashboard", async () => {
  const opened = [], chose = [], more = []
  let dash = 0
  const bus = createBus()
  const reader = { dTag: READER_DTAG, send: () => {} }, other = { dTag: "nv-wot", send: () => {} }
  const items = [{ id: "l1", kind: "reply", actors: [ANN], preview: "x", created_at: 60, openId: H("1"), images: [] }]
  const ctl = { mode: () => "activity", choose: id => chose.push(id), more: () => more.push(1) }
  const off = vaultIntents({ bus, pipe: { ctl, answer: () => vaultAnswer({ ...base, mode: "activity", items, shown: 30 }, h) }, openHash: x => opened.push(x), openDashboard: () => dash++ })
  const ask = (from, action, payload = {}) => bus.invoke(from, { archetype: "vault", action, payload })
  assert.equal((await ask(other, "state")).ok, false)
  assert.equal((await ask(reader, "open", { id: "l1" })).ok, false, "nothing handed out yet")
  assert.equal((await ask(reader, "state")).ok, true)
  assert.equal((await ask(reader, "open", { id: "l1" })).ok, true)
  assert.equal((await ask(reader, "open", { id: "#/settings" })).ok, false)
  assert.equal((await ask(reader, "mode", { mode: "zaps" })).ok, true)
  assert.equal((await ask(reader, "mode", { mode: "settings" })).ok, false)
  assert.equal((await ask(reader, "filter", { id: "mentions" })).ok, true)
  assert.equal((await ask(reader, "filter", { id: "given" })).ok, false, "not a filter of the Vault list")
  await ask(reader, "more"); await ask(reader, "dashboard")
  assert.deepEqual(opened, [`#/thread/${H("1")}`, "#/vault/zaps"]); assert.deepEqual(chose, ["mentions"]); assert.equal(more.length, 1); assert.equal(dash, 1)
  off()
  assert.equal((await ask(reader, "state")).ok, false)
})
